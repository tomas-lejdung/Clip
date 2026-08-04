package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/config"
	"github.com/tomas-lejdung/Clip/server/internal/protocol"
	"github.com/tomas-lejdung/Clip/server/internal/signaling"
)

const maximumOwnerRequestBytes = 1_024

// Service exposes the opaque native-v4 room coordinator. It owns only bounded
// routing handles, roster presence, and encrypted signaling delivery; media,
// identity, admission secrets, and collaboration contents remain client-owned.
type Service struct {
	config         config.Config
	roomHub        *signaling.RoomHub
	friendPresence *friendPresenceStore
	webReconnect   *browserReconnectTicketStore
	handler        http.Handler
	upgrader       websocket.Upgrader
	connections    chan struct{}
	admission      *sourceAdmission
	queueBudget    *signaling.QueuedByteBudget
	socketsMu      sync.Mutex
	sockets        map[*signaling.Socket]struct{}
	socketsWG      sync.WaitGroup
	closing        bool
	cancel         context.CancelFunc
	cleanupDone    chan struct{}
	shutdownDone   chan struct{}
	closeOnce      sync.Once
}

func New(configuration config.Config) (*Service, error) {
	roomHub := signaling.NewRoomHub(signaling.RoomConfiguration{
		LeaseDuration:        configuration.LeaseDuration,
		ReconnectGrace:       configuration.ReconnectGrace,
		CandidateIdleTimeout: configuration.RouteIdleTimeout,
		MaximumRooms:         configuration.MaximumRendezvous,
		MaximumPending:       protocol.MaximumPendingCandidates,
		MaximumIssuedHandles: configuration.MaximumIssuedHandlesPerRoom,
	})
	return NewWithRoomHub(configuration, roomHub)
}

func NewWithRoomHub(
	configuration config.Config,
	roomHub *signaling.RoomHub,
) (*Service, error) {
	if err := configuration.Validate(); err != nil {
		return nil, err
	}
	if roomHub == nil {
		return nil, errors.New("native room hub is required")
	}
	ctx, cancel := context.WithCancel(context.Background())
	service := &Service{
		config:  configuration,
		roomHub: roomHub,
		friendPresence: newFriendPresenceStore(
			configuration.MaximumFriendPresenceRecords,
			configuration.MaximumFriendPresenceBytes,
		),
		webReconnect: newBrowserReconnectTicketStore(configuration.MaximumTrackedSources),
		connections:  make(chan struct{}, configuration.MaximumConnections),
		queueBudget: signaling.NewQueuedByteBudget(
			configuration.MaximumQueuedBytesTotal,
		),
		sockets:      make(map[*signaling.Socket]struct{}),
		cancel:       cancel,
		cleanupDone:  make(chan struct{}),
		shutdownDone: make(chan struct{}),
	}
	service.admission = newSourceAdmission(configuration)
	service.upgrader = websocket.Upgrader{
		ReadBufferSize:    4_096,
		WriteBufferSize:   4_096,
		EnableCompression: false,
		CheckOrigin:       service.originAllowed,
	}
	service.handler = service.routes()
	go service.cleanupLoop(ctx)
	return service, nil
}

func (s *Service) Handler() http.Handler {
	return s.handler
}

func (s *Service) Close() {
	ctx, cancel := context.WithTimeout(
		context.Background(),
		s.config.ShutdownTimeout,
	)
	defer cancel()
	_ = s.Shutdown(ctx)
}

func (s *Service) Shutdown(ctx context.Context) error {
	s.closeOnce.Do(func() {
		go s.shutdown()
	})
	select {
	case <-s.shutdownDone:
		return nil
	case <-ctx.Done():
		s.abortActiveSockets()
		return ctx.Err()
	}
}

func (s *Service) shutdown() {
	s.socketsMu.Lock()
	s.closing = true
	activeSockets := s.activeSocketsLocked()
	s.socketsMu.Unlock()

	s.cancel()
	s.roomHub.Shutdown("server shutting down")
	for _, socket := range activeSockets {
		socket.Close(signaling.CloseGoingAway, "server shutting down")
	}
	<-s.cleanupDone
	s.socketsWG.Wait()
	close(s.shutdownDone)
}

func (s *Service) abortActiveSockets() {
	s.socketsMu.Lock()
	activeSockets := s.activeSocketsLocked()
	s.socketsMu.Unlock()
	for _, socket := range activeSockets {
		socket.Abort()
	}
}

func (s *Service) activeSocketsLocked() []*signaling.Socket {
	activeSockets := make([]*signaling.Socket, 0, len(s.sockets))
	for socket := range s.sockets {
		activeSockets = append(activeSockets, socket)
	}
	return activeSockets
}

func (s *Service) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(
		"GET /.well-known/clip-native-rendezvous",
		s.nativeCapabilities,
	)
	mux.HandleFunc(
		"PUT /api/native/v4/rooms/{room}",
		s.createNativeRoom,
	)
	mux.HandleFunc(
		"GET /api/native/v4/rooms/{room}",
		s.nativeRoomStatus,
	)
	mux.HandleFunc(
		"DELETE /api/native/v4/rooms/{room}",
		s.removeNativeRoom,
	)
	mux.HandleFunc(
		"GET /api/native/v4/rooms/{room}/socket",
		s.nativeRoomWebSocket,
	)
	mux.HandleFunc(
		"POST /api/native/v4/rooms/{room}/browser-reconnect",
		s.createBrowserReconnectTicket,
	)
	mux.HandleFunc(
		"PUT /api/native/v4/friends/{routing}/presence",
		s.putNativeFriendPresence,
	)
	mux.HandleFunc(
		"GET /api/native/v4/friends/{routing}/presence",
		s.getNativeFriendPresence,
	)
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /version", s.version)
	mux.HandleFunc("GET /assets/{asset...}", s.viewerAsset)
	mux.HandleFunc("GET /{room}", s.viewerPage)
	return s.securityHeaders(rejectViewerPathAliases(mux))
}

func (s *Service) health(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Service) version(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, protocol.VersionResponse{
		Protocol:        protocol.Identifier,
		ProtocolVersion: protocol.NativeRoomAPIVersion,
		ServerVersion:   s.config.ServerVersion,
	})
}

func (s *Service) socketConfiguration(
	onKeepAlive func(),
) signaling.SocketConfiguration {
	return signaling.SocketConfiguration{
		ReadTimeout:                   s.config.ReadTimeout,
		WriteTimeout:                  s.config.WriteTimeout,
		PingInterval:                  s.config.PingInterval,
		QueueDepth:                    32,
		MaximumQueuedBytes:            s.config.MaximumQueuedBytesPerSocket,
		SharedQueuedBytes:             s.queueBudget,
		MaximumQueuedMessagesPerRoute: 8,
		MaximumQueuedBytesPerRoute:    1 << 20,
		OnKeepAlive:                   onKeepAlive,
	}
}

func (s *Service) cleanupLoop(ctx context.Context) {
	defer close(s.cleanupDone)
	ticker := time.NewTicker(s.config.CleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.roomHub.Cleanup()
			s.friendPresence.cleanup()
			s.webReconnect.cleanup()
			s.admission.cleanup()
		}
	}
}

func (s *Service) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		writer.Header().Set(
			"Content-Security-Policy",
			"default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
		)
		writer.Header().Set("Referrer-Policy", "no-referrer")
		writer.Header().Set("X-Content-Type-Options", "nosniff")
		writer.Header().Set("X-Frame-Options", "DENY")
		writer.Header().Set(
			"Permissions-Policy",
			"camera=(), microphone=(), display-capture=(), geolocation=(), payment=(), usb=()",
		)
		next.ServeHTTP(writer, request)
	})
}

func (s *Service) originAllowed(request *http.Request) bool {
	origin := strings.TrimSpace(request.Header.Get("Origin"))
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Host == "" {
		return false
	}
	if strings.EqualFold(parsed.Host, request.Host) {
		return true
	}
	for _, allowed := range s.config.AllowedOrigins {
		if strings.EqualFold(
			strings.TrimSuffix(allowed, "/"),
			strings.TrimSuffix(origin, "/"),
		) {
			return true
		}
	}
	return false
}

func (s *Service) trackSocket(socket *signaling.Socket) bool {
	s.socketsMu.Lock()
	defer s.socketsMu.Unlock()
	if s.closing {
		return false
	}
	s.sockets[socket] = struct{}{}
	s.socketsWG.Add(1)
	return true
}

func (s *Service) untrackSocket(socket *signaling.Socket) {
	s.socketsMu.Lock()
	_, tracked := s.sockets[socket]
	if tracked {
		delete(s.sockets, socket)
	}
	s.socketsMu.Unlock()
	if tracked {
		s.socketsWG.Done()
	}
}

func ownerHashFromAuthorization(
	request *http.Request,
) ([32]byte, error) {
	fields := strings.Fields(request.Header.Get("Authorization"))
	if len(fields) != 2 || !strings.EqualFold(fields[0], "Bearer") {
		return [32]byte{}, protocol.ErrInvalidOwnerToken
	}
	return protocol.HashOwnerToken(fields[1])
}

func randomIdentifier(byteCount int) (string, error) {
	bytes := make([]byte, byteCount)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

func writeError(writer http.ResponseWriter, status int, code string) {
	writeJSON(writer, status, protocol.ErrorResponse{Error: code})
}

// HTTPServer wraps the service handler in production-safe timeout defaults.
func HTTPServer(
	configuration config.Config,
	handler http.Handler,
) *http.Server {
	return &http.Server{
		Addr:              configuration.Address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       75 * time.Second,
		MaxHeaderBytes:    16 * 1_024,
	}
}

func IsExpectedServerClose(err error) bool {
	return err == nil || errors.Is(err, http.ErrServerClosed)
}

func Shutdown(ctx context.Context, server *http.Server) error {
	if err := server.Shutdown(ctx); err != nil {
		_ = server.Close()
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	return nil
}
