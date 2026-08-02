package httpapi

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
	"github.com/tomas-lejdung/Clip/server/internal/signaling"
)

const (
	browserRoomWebSocketProtocol       = "clip-native-room-v4"
	browserReconnectProtocolPrefix     = "reconnect."
	browserReconnectTicketBytes        = 32
	browserReconnectTicketLifetime     = 30 * time.Second
	maximumBrowserReconnectRequestSize = 1_024
)

type browserReconnectRequest struct {
	MemberHandle string `json:"memberHandle"`
}

type browserReconnectResponse struct {
	Ticket           string `json:"ticket"`
	ExpiresInSeconds int64  `json:"expiresInSeconds"`
}

type browserReconnectCredential struct {
	roomID        string
	memberHandle  string
	reconnectHash [sha256.Size]byte
	source        string
	expiresAt     time.Time
}

// browserReconnectTicketStore bridges the browser WebSocket API's inability
// to set Authorization headers without ever placing a reconnect capability in
// a URL, cookie, or WebSocket protocol header. The browser exchanges the
// capability for a random, one-use, short-lived ticket. The store retains the
// random ticket as its lookup key and only a hash of the reconnect capability;
// ReconnectMember still performs the authoritative room check at consumption.
type browserReconnectTicketStore struct {
	mu      sync.Mutex
	entries map[string]browserReconnectCredential
	maximum int
	now     func() time.Time
	random  func([]byte) error
}

func newBrowserReconnectTicketStore(maximum int) *browserReconnectTicketStore {
	if maximum <= 0 {
		maximum = 1
	}
	return &browserReconnectTicketStore{
		entries: make(map[string]browserReconnectCredential),
		maximum: maximum,
		now:     time.Now,
		random: func(destination []byte) error {
			_, err := rand.Read(destination)
			return err
		},
	}
}

func (s *browserReconnectTicketStore) issue(
	roomID string,
	memberHandle string,
	reconnectHash [sha256.Size]byte,
	source string,
) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.cleanupLocked(now)
	if len(s.entries) >= s.maximum {
		return "", false
	}
	bytes := make([]byte, browserReconnectTicketBytes)
	for attempt := 0; attempt < 4; attempt++ {
		if s.random(bytes) != nil {
			return "", false
		}
		ticket := base64.RawURLEncoding.EncodeToString(bytes)
		if _, exists := s.entries[ticket]; exists {
			continue
		}
		s.entries[ticket] = browserReconnectCredential{
			roomID: roomID, memberHandle: memberHandle,
			reconnectHash: reconnectHash, source: source,
			expiresAt: now.Add(browserReconnectTicketLifetime),
		}
		return ticket, true
	}
	return "", false
}

func (s *browserReconnectTicketStore) consume(
	ticket string,
	roomID string,
	source string,
) (browserReconnectCredential, bool) {
	decoded, err := base64.RawURLEncoding.DecodeString(ticket)
	if err != nil || len(decoded) != browserReconnectTicketBytes ||
		base64.RawURLEncoding.EncodeToString(decoded) != ticket {
		return browserReconnectCredential{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	credential, found := s.entries[ticket]
	if found {
		delete(s.entries, ticket)
	}
	if !found || !now.Before(credential.expiresAt) ||
		credential.roomID != roomID || credential.source != source {
		return browserReconnectCredential{}, false
	}
	return credential, true
}

func (s *browserReconnectTicketStore) cleanup() {
	s.mu.Lock()
	s.cleanupLocked(s.now())
	s.mu.Unlock()
}

func (s *browserReconnectTicketStore) cleanupLocked(now time.Time) {
	for ticket, credential := range s.entries {
		if !now.Before(credential.expiresAt) {
			delete(s.entries, ticket)
		}
	}
}

func (s *Service) createBrowserReconnectTicket(
	writer http.ResponseWriter,
	request *http.Request,
) {
	roomID, ok := nativeRoomID(writer, request)
	if !ok {
		return
	}
	if request.URL.RawQuery != "" {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if !sameRequestOrigin(request) {
		writeError(writer, http.StatusForbidden, "request_forbidden")
		return
	}
	source := s.admission.source(request)
	if !s.admission.allowRendezvousLeaseOperation(source) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	if _, found := s.roomHub.Snapshot(roomID); !found {
		writeError(writer, http.StatusNotFound, "room_not_found")
		return
	}
	var body browserReconnectRequest
	if err := protocol.DecodeStrictJSON(
		request.Body,
		maximumBrowserReconnectRequestSize,
		&body,
	); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	fields := strings.Fields(request.Header.Get("Authorization"))
	if len(fields) != 2 || !strings.EqualFold(fields[0], "Bearer") {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	hash, err := protocol.HashNativeReconnectCapability(fields[1])
	if err != nil ||
		protocol.ValidateNativeMemberHandle(body.MemberHandle) != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if err := s.roomHub.AuthenticateMemberReconnect(
		roomID,
		body.MemberHandle,
		hash,
	); err != nil {
		if errors.Is(err, signaling.ErrRoomNotFound) {
			writeError(writer, http.StatusNotFound, "room_not_found")
			return
		}
		writeError(writer, http.StatusUnauthorized, "reconnect_unauthorized")
		return
	}
	ticket, issued := s.webReconnect.issue(
		roomID,
		body.MemberHandle,
		hash,
		source,
	)
	if !issued {
		writeError(writer, http.StatusServiceUnavailable, "ticket_unavailable")
		return
	}
	writer.Header().Set("Vary", "Origin")
	writeJSON(writer, http.StatusCreated, browserReconnectResponse{
		Ticket:           ticket,
		ExpiresInSeconds: int64(browserReconnectTicketLifetime / time.Second),
	})
}

func sameRequestOrigin(request *http.Request) bool {
	origin := strings.TrimSpace(request.Header.Get("Origin"))
	if origin == "" {
		return false
	}
	parsed, err := requestOrigin(origin)
	return err == nil && strings.EqualFold(parsed, request.Host)
}

func requestOrigin(origin string) (string, error) {
	request, err := http.NewRequest(http.MethodGet, origin, nil)
	if err != nil || request.URL.Host == "" || request.URL.User != nil ||
		(request.URL.Scheme != "http" && request.URL.Scheme != "https") ||
		request.URL.RawQuery != "" || request.URL.Fragment != "" ||
		(request.URL.Path != "" && request.URL.Path != "/") {
		return "", errors.New("invalid origin")
	}
	return request.URL.Host, nil
}

func browserRoomWebSocketResponseHeader(request *http.Request) http.Header {
	for _, value := range websocket.Subprotocols(request) {
		if value == browserRoomWebSocketProtocol {
			return http.Header{
				"Sec-Websocket-Protocol": []string{browserRoomWebSocketProtocol},
			}
		}
	}
	return nil
}

func (s *Service) browserReconnectCredential(
	request *http.Request,
	roomID string,
	source string,
) (browserReconnectCredential, bool, error) {
	protocols := websocket.Subprotocols(request)
	if len(protocols) == 0 {
		return browserReconnectCredential{}, false, nil
	}
	if protocols[0] != browserRoomWebSocketProtocol || len(protocols) > 2 {
		return browserReconnectCredential{}, false, signaling.ErrRoomUnauthorized
	}
	if len(protocols) == 1 {
		return browserReconnectCredential{}, false, nil
	}
	if !strings.HasPrefix(protocols[1], browserReconnectProtocolPrefix) {
		return browserReconnectCredential{}, false, signaling.ErrRoomUnauthorized
	}
	ticket := strings.TrimPrefix(protocols[1], browserReconnectProtocolPrefix)
	credential, ok := s.webReconnect.consume(ticket, roomID, source)
	if !ok {
		return browserReconnectCredential{}, false, signaling.ErrRoomUnauthorized
	}
	return credential, true, nil
}
