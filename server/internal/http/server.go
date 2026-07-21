package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/config"
	"github.com/tomas-lejdung/Clip/server/internal/protocol"
	"github.com/tomas-lejdung/Clip/server/internal/registry"
	"github.com/tomas-lejdung/Clip/server/internal/signaling"
	"github.com/tomas-lejdung/Clip/server/web"
)

const maximumOwnerRequestBytes = 1_024

type Service struct {
	config            config.Config
	registry          *registry.Registry
	hub               *signaling.Hub
	nativeRendezvous  *signaling.NativeRendezvousHub
	handler           http.Handler
	upgrader          websocket.Upgrader
	connections       chan struct{}
	viewerConnections chan struct{}
	admission         *sourceAdmission
	viewerRoomsMu     sync.Mutex
	viewerRooms       map[string]int
	queueBudget       *signaling.QueuedByteBudget
	socketsMu         sync.Mutex
	sockets           map[*signaling.Socket]struct{}
	socketsWG         sync.WaitGroup
	closing           bool
	cancel            context.CancelFunc
	cleanupDone       chan struct{}
	shutdownDone      chan struct{}
	closeOnce         sync.Once
	logger            *slog.Logger
}

func New(configuration config.Config, logger *slog.Logger) (*Service, error) {
	if err := configuration.Validate(); err != nil {
		return nil, err
	}
	if logger == nil {
		logger = slog.Default()
	}
	roomRegistry := registry.New(registry.Configuration{
		LeaseDuration:  configuration.LeaseDuration,
		ReconnectGrace: configuration.ReconnectGrace,
		MaximumRooms:   configuration.MaximumRooms,
	})
	hub := signaling.NewHub(signaling.Configuration{
		MaximumPendingRoutes: protocol.MaximumPendingViewersPerRoom,
		RouteIdleTimeout:     configuration.RouteIdleTimeout,
	})
	return NewWithDependencies(configuration, roomRegistry, hub, logger)
}

func NewWithDependencies(configuration config.Config, roomRegistry *registry.Registry, hub *signaling.Hub, logger *slog.Logger) (*Service, error) {
	if err := configuration.Validate(); err != nil {
		return nil, err
	}
	if roomRegistry == nil || hub == nil {
		return nil, errors.New("registry and signaling hub are required")
	}
	if logger == nil {
		logger = slog.Default()
	}
	ctx, cancel := context.WithCancel(context.Background())
	service := &Service{
		config:   configuration,
		registry: roomRegistry,
		hub:      hub,
		nativeRendezvous: signaling.NewNativeRendezvousHub(signaling.NativeRendezvousConfiguration{
			LeaseDuration:        configuration.LeaseDuration,
			ReconnectGrace:       configuration.ReconnectGrace,
			MaximumRendezvous:    configuration.MaximumRooms,
			MaximumPendingRoutes: protocol.MaximumPendingViewersPerRoom,
			RouteIdleTimeout:     configuration.RouteIdleTimeout,
		}),
		connections:       make(chan struct{}, configuration.MaximumConnections),
		viewerConnections: make(chan struct{}, configuration.MaximumConnections-configuration.ReservedHostConnections),
		viewerRooms:       make(map[string]int),
		queueBudget:       signaling.NewQueuedByteBudget(configuration.MaximumQueuedBytesTotal),
		sockets:           make(map[*signaling.Socket]struct{}),
		cancel:            cancel,
		cleanupDone:       make(chan struct{}),
		shutdownDone:      make(chan struct{}),
		logger:            logger,
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
	ctx, cancel := context.WithTimeout(context.Background(), s.config.ShutdownTimeout)
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
	for _, name := range s.registry.Names() {
		s.hub.CloseRoom(name, "server shutting down")
	}
	s.nativeRendezvous.Shutdown("server shutting down")
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
	mux.HandleFunc("GET /.well-known/clip-live-share", s.capabilities)
	mux.HandleFunc("GET /.well-known/clip-native-rendezvous", s.nativeCapabilities)
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /version", s.version)
	mux.HandleFunc("PUT /api/v1/rooms/{room}", s.advertiseRoom)
	mux.HandleFunc("DELETE /api/v1/rooms/{room}", s.removeRoom)
	mux.HandleFunc("GET /api/v1/rooms/{room}/host", s.hostWebSocket)
	mux.HandleFunc("GET /api/v1/rooms/{room}/viewer", s.viewerWebSocket)
	mux.HandleFunc("PUT /api/native/v1/rendezvous/{rendezvous}", s.advertiseNativeRendezvous)
	mux.HandleFunc("GET /api/native/v1/rendezvous/{rendezvous}", s.nativeRendezvousStatus)
	mux.HandleFunc("DELETE /api/native/v1/rendezvous/{rendezvous}", s.removeNativeRendezvous)
	mux.HandleFunc("PUT /api/native/v1/rendezvous/{rendezvous}/session", s.activateNativeSession)
	mux.HandleFunc("DELETE /api/native/v1/rendezvous/{rendezvous}/session", s.deactivateNativeSession)
	mux.HandleFunc("GET /api/native/v1/rendezvous/{rendezvous}/host", s.nativeHostWebSocket)
	mux.HandleFunc("GET /api/native/v1/rendezvous/{rendezvous}/viewer", s.nativeViewerWebSocket)
	mux.HandleFunc("GET /assets/{asset}", s.viewerAsset)
	mux.HandleFunc("GET /{room}", s.viewerPage)
	return s.securityHeaders(mux)
}

func (s *Service) capabilities(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, protocol.Capabilities{
		Protocol:                    protocol.Identifier,
		Versions:                    []int{protocol.Version},
		ServerVersion:               s.config.ServerVersion,
		ViewerPathTemplate:          "/{room}",
		HostWebSocketPathTemplate:   "/api/v1/rooms/{room}/host",
		ViewerWebSocketPathTemplate: "/api/v1/rooms/{room}/viewer",
		ICEServers:                  s.config.ICEServers,
		Limits: protocol.Limits{
			MaximumMessageBytes:          protocol.MaximumMessageBytes,
			MaximumPendingViewersPerRoom: protocol.MaximumPendingViewersPerRoom,
		},
	})
}

func (s *Service) health(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Service) version(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, protocol.VersionResponse{
		Protocol:        protocol.Identifier,
		ProtocolVersion: protocol.Version,
		ServerVersion:   s.config.ServerVersion,
	})
}

func (s *Service) advertiseRoom(writer http.ResponseWriter, request *http.Request) {
	roomName, err := protocol.NormalizeRoomName(request.PathValue("room"))
	if err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_room")
		return
	}
	if !s.admission.allowAdvertisement(s.admission.source(request)) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	var body protocol.OwnerRequest
	if err := protocol.DecodeStrictJSON(request.Body, maximumOwnerRequestBytes, &body); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	ownerHash, err := protocol.HashOwnerToken(body.OwnerToken)
	if err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_owner_token")
		return
	}
	advertisement, err := s.registry.AdvertiseGeneration(roomName, ownerHash)
	for _, expired := range advertisement.ExpiredGenerations {
		s.hub.CloseRoomGeneration(expired.Name, expired.Generation, "room lease expired")
	}
	if err != nil {
		switch {
		case errors.Is(err, registry.ErrRoomConflict):
			writeError(writer, http.StatusConflict, "room_name_unavailable")
		case errors.Is(err, registry.ErrRoomLimit):
			writeError(writer, http.StatusServiceUnavailable, "room_capacity_reached")
		default:
			writeError(writer, http.StatusInternalServerError, "server_error")
		}
		return
	}
	status := http.StatusOK
	if advertisement.Created {
		status = http.StatusCreated
	}
	writeJSON(writer, status, protocol.RoomResponse{
		Room:                 roomName,
		LeaseDurationSeconds: int64(advertisement.Lease / time.Second),
	})
}

func (s *Service) removeRoom(writer http.ResponseWriter, request *http.Request) {
	roomName, err := protocol.NormalizeRoomName(request.PathValue("room"))
	if err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_room")
		return
	}
	ownerHash, err := ownerHashFromAuthorization(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
		return
	}
	generation, err := s.registry.DeleteGeneration(roomName, ownerHash)
	if err != nil {
		switch {
		case errors.Is(err, registry.ErrRoomNotFound):
			writeError(writer, http.StatusNotFound, "room_not_found")
		case errors.Is(err, registry.ErrUnauthorized):
			writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
		default:
			writeError(writer, http.StatusInternalServerError, "server_error")
		}
		return
	}
	s.hub.CloseRoomGeneration(roomName, generation, "room removed")
	writer.WriteHeader(http.StatusNoContent)
}

func (s *Service) viewerPage(writer http.ResponseWriter, request *http.Request) {
	if _, err := protocol.NormalizeRoomName(request.PathValue("room")); err != nil {
		http.NotFound(writer, request)
		return
	}
	data, err := fs.ReadFile(web.Assets, "viewer.html")
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "viewer_unavailable")
		return
	}
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(data)
}

func (s *Service) viewerAsset(writer http.ResponseWriter, request *http.Request) {
	asset := request.PathValue("asset")
	if asset != "clip-viewer.js" &&
		asset != "clip-protocol.js" &&
		asset != "clip-media.js" {
		http.NotFound(writer, request)
		return
	}
	data, err := fs.ReadFile(web.Assets, asset)
	if err != nil {
		http.NotFound(writer, request)
		return
	}
	writer.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-cache")
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(data)
}

func (s *Service) hostWebSocket(writer http.ResponseWriter, request *http.Request) {
	roomName, err := protocol.NormalizeRoomName(request.PathValue("room"))
	if err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_room")
		return
	}
	source := s.admission.source(request)
	if !s.admission.allowWebSocket(source) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	ownerHash, err := ownerHashFromAuthorization(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
		return
	}
	if err := s.registry.Authenticate(roomName, ownerHash); err != nil {
		if errors.Is(err, registry.ErrRoomNotFound) {
			writeError(writer, http.StatusNotFound, "room_not_found")
		} else {
			writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
		}
		return
	}
	if !s.acquireHostConnection(source) {
		writeError(writer, http.StatusServiceUnavailable, "connection_capacity_reached")
		return
	}
	defer s.releaseHostConnection(source)

	connection, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	hostID, err := randomIdentifier(16)
	if err != nil {
		_ = connection.Close()
		return
	}
	socket := signaling.NewSocket(connection, s.socketConfiguration(func() {
		if !s.registry.RenewHost(roomName, hostID) {
			connection.Close()
		}
	}))
	if !s.trackSocket(socket) {
		socket.Start()
		socket.Close(signaling.CloseGoingAway, "server shutting down")
		socket.Wait()
		return
	}
	defer s.untrackSocket(socket)
	socket.Start()
	defer socket.Wait()
	defer socket.Close(signaling.CloseNormal, "host disconnected")

	attachment, err := s.registry.AttachHostGeneration(roomName, ownerHash, hostID)
	if err != nil {
		_ = socket.Send(protocol.ErrorMessage("owner_unauthorized", "The room owner capability was rejected."))
		socket.Close(signaling.ClosePolicyViolation, "owner unauthorized")
		return
	}
	if !s.hub.RegisterHostGeneration(roomName, attachment.RoomGeneration, attachment.HostGeneration, hostID, socket) || !s.registry.RenewHost(roomName, hostID) {
		s.hub.UnregisterHost(roomName, hostID)
		socket.Close(signaling.CloseGoingAway, "stale host generation")
		return
	}
	defer s.registry.DetachHost(roomName, hostID)
	defer s.hub.UnregisterHost(roomName, hostID)
	_ = socket.ResetReadDeadline()

	for {
		message, err := socket.Read()
		if err != nil {
			s.rejectReadError(socket, err)
			return
		}
		switch message.Type {
		case protocol.MessageRelay:
			err = s.hub.RelayFromHost(roomName, hostID, message)
		case protocol.MessageCloseRoute:
			if validateErr := protocol.ValidateCloseRoute(message); validateErr != nil {
				err = validateErr
			} else {
				err = s.hub.CloseRouteFromHost(roomName, hostID, message.RouteID, message.Reason)
			}
		default:
			err = protocol.ErrInvalidMessage
		}
		if err != nil {
			if errors.Is(err, signaling.ErrRouteNotFound) || errors.Is(err, signaling.ErrStaleViewer) {
				_ = socket.Send(protocol.ErrorMessage("route_unavailable", "The signaling route is no longer available."))
				continue
			}
			if errors.Is(err, signaling.ErrRouteBackpressure) {
				_ = socket.Send(protocol.ErrorMessage("route_backpressure", "The signaling route exceeded its capacity."))
				continue
			}
			if errors.Is(err, signaling.ErrSequence) {
				_ = s.hub.CloseRouteFromHost(roomName, hostID, message.RouteID, "relay sequence rejected")
				_ = socket.Send(protocol.ErrorMessage("route_sequence_rejected", "The signaling route sequence was rejected."))
				continue
			}
			_ = socket.Send(protocol.ErrorMessage("protocol_error", "The signaling message was rejected."))
			socket.Close(signaling.CloseProtocolError, "protocol error")
			return
		}
	}
}

func (s *Service) viewerWebSocket(writer http.ResponseWriter, request *http.Request) {
	roomName, err := protocol.NormalizeRoomName(request.PathValue("room"))
	if err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_room")
		return
	}
	source := s.admission.source(request)
	if !s.admission.allowWebSocket(source) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	roomGeneration, found := s.registry.Generation(roomName)
	if !found {
		writeError(writer, http.StatusNotFound, "room_not_found")
		return
	}
	if !s.acquireViewerConnection(source, roomName) {
		writeError(writer, http.StatusServiceUnavailable, "connection_capacity_reached")
		return
	}
	defer s.releaseViewerConnection(source, roomName)

	connection, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	socket := signaling.NewSocket(connection, s.socketConfiguration(nil))
	if !s.trackSocket(socket) {
		socket.Start()
		socket.Close(signaling.CloseGoingAway, "server shutting down")
		socket.Wait()
		return
	}
	defer s.untrackSocket(socket)
	socket.Start()
	defer socket.Wait()
	defer socket.Close(signaling.CloseNormal, "viewer disconnected")

	if !s.hub.HasHostGeneration(roomName, roomGeneration) {
		_ = socket.Send(protocol.Message{Type: protocol.MessageHostUnavailable})
		socket.Close(signaling.CloseTryAgainLater, "host unavailable")
		return
	}
	_ = socket.SetReadDeadline(time.Now().Add(s.config.HelloTimeout))
	hello, err := socket.Read()
	if err != nil || protocol.ValidateViewerHello(hello) != nil {
		_ = socket.Send(protocol.ErrorMessage("invalid_viewer_hello", "A valid viewer hello is required."))
		socket.Close(signaling.CloseProtocolError, "invalid viewer hello")
		return
	}
	routeID, err := s.hub.OpenRouteGeneration(roomName, roomGeneration, hello.ViewerKey, socket)
	if err != nil {
		if errors.Is(err, signaling.ErrRouteLimit) {
			_ = socket.Send(protocol.ErrorMessage("route_capacity_reached", "The room has too many pending viewers."))
		} else {
			_ = socket.Send(protocol.Message{Type: protocol.MessageHostUnavailable})
		}
		socket.Close(signaling.CloseTryAgainLater, "route unavailable")
		return
	}
	defer s.hub.CloseViewerRoute(roomName, routeID, socket, "viewer disconnected")
	_ = socket.ResetReadDeadline()

	for {
		message, err := socket.Read()
		if err != nil {
			s.rejectReadError(socket, err)
			return
		}
		switch message.Type {
		case protocol.MessageRelay:
			err = s.hub.RelayFromViewer(roomName, routeID, socket, message)
		case protocol.MessageCloseRoute:
			if validateErr := protocol.ValidateCloseRoute(message); validateErr != nil || message.RouteID != routeID {
				err = protocol.ErrInvalidMessage
			} else {
				s.hub.CloseViewerRoute(roomName, routeID, socket, "viewer completed signaling")
				return
			}
		default:
			err = protocol.ErrInvalidMessage
		}
		if err != nil {
			if errors.Is(err, signaling.ErrRouteBackpressure) || errors.Is(err, signaling.ErrHostUnavailable) || errors.Is(err, signaling.ErrStaleViewer) {
				return
			}
			_ = socket.Send(protocol.ErrorMessage("protocol_error", "The signaling message was rejected."))
			socket.Close(signaling.CloseProtocolError, "protocol error")
			return
		}
	}
}

func (s *Service) socketConfiguration(onKeepAlive func()) signaling.SocketConfiguration {
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

func (s *Service) rejectReadError(socket *signaling.Socket, err error) {
	switch {
	case errors.Is(err, websocket.ErrReadLimit):
		socket.Close(signaling.CloseMessageTooBig, "message too large")
	case errors.Is(err, protocol.ErrInvalidMessage), errors.Is(err, signaling.ErrNonTextMessage):
		_ = socket.Send(protocol.ErrorMessage("protocol_error", "The signaling message was rejected."))
		socket.Close(signaling.CloseProtocolError, "protocol error")
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
			for _, room := range s.registry.CleanupExpiredGenerations() {
				s.hub.CloseRoomGeneration(room.Name, room.Generation, "room lease expired")
			}
			s.hub.CleanupIdleRoutes()
			s.nativeRendezvous.Cleanup()
			s.admission.cleanup()
		}
	}
}

func (s *Service) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self' ws: wss: stun: stuns: turn: turns:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		writer.Header().Set("Referrer-Policy", "no-referrer")
		writer.Header().Set("X-Content-Type-Options", "nosniff")
		writer.Header().Set("X-Frame-Options", "DENY")
		writer.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
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
		if strings.EqualFold(strings.TrimSuffix(allowed, "/"), strings.TrimSuffix(origin, "/")) {
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

func ownerHashFromAuthorization(request *http.Request) ([32]byte, error) {
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
func HTTPServer(configuration config.Config, handler http.Handler) *http.Server {
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
