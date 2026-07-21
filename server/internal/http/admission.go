package httpapi

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/config"
	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

const (
	sourceRateWindow = time.Minute
	sourceIdleExpiry = 5 * time.Minute
)

type fixedWindow struct {
	started time.Time
	count   int
}

type sourceState struct {
	advertisements fixedWindow
	webSockets     fixedWindow
	connections    int
	lastSeen       time.Time
}

// sourceAdmission keys on the directly connected peer by default. Forwarded
// addresses are considered only when the immediate peer belongs to an
// explicitly configured trusted proxy network.
type sourceAdmission struct {
	mu                   sync.Mutex
	entries              map[string]*sourceState
	maximumEntries       int
	maximumConnections   int
	advertisementsPerMin int
	webSocketsPerMin     int
	trustedProxies       []*net.IPNet
	now                  func() time.Time
}

func newSourceAdmission(configuration config.Config) *sourceAdmission {
	admission := &sourceAdmission{
		entries:              make(map[string]*sourceState),
		maximumEntries:       configuration.MaximumTrackedSources,
		maximumConnections:   configuration.MaximumConnectionsPerSource,
		advertisementsPerMin: configuration.RoomAdvertisementsPerMinute,
		webSocketsPerMin:     configuration.WebSocketUpgradesPerMinute,
		now:                  time.Now,
	}
	for _, value := range configuration.TrustedProxyCIDRs {
		_, network, err := net.ParseCIDR(value)
		if err == nil {
			admission.trustedProxies = append(admission.trustedProxies, network)
		}
	}
	return admission
}

func (a *sourceAdmission) allowAdvertisement(source string) bool {
	return a.allow(source, func(state *sourceState) *fixedWindow { return &state.advertisements }, a.advertisementsPerMin)
}

func (a *sourceAdmission) allowWebSocket(source string) bool {
	return a.allow(source, func(state *sourceState) *fixedWindow { return &state.webSockets }, a.webSocketsPerMin)
}

func (a *sourceAdmission) allow(source string, selectWindow func(*sourceState) *fixedWindow, maximum int) bool {
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	state, ok := a.stateLocked(source, now)
	if !ok {
		return false
	}
	window := selectWindow(state)
	if window.started.IsZero() || now.Before(window.started) || now.Sub(window.started) >= sourceRateWindow {
		window.started = now
		window.count = 0
	}
	if window.count >= maximum {
		return false
	}
	window.count++
	state.lastSeen = now
	return true
}

func (a *sourceAdmission) acquireConnection(source string) bool {
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	state, ok := a.stateLocked(source, now)
	if !ok || state.connections >= a.maximumConnections {
		return false
	}
	state.connections++
	state.lastSeen = now
	return true
}

func (a *sourceAdmission) releaseConnection(source string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	state := a.entries[source]
	if state == nil {
		return
	}
	if state.connections > 0 {
		state.connections--
	}
	state.lastSeen = a.now()
}

func (a *sourceAdmission) cleanup() {
	now := a.now()
	a.mu.Lock()
	a.cleanupLocked(now)
	a.mu.Unlock()
}

func (a *sourceAdmission) stateLocked(source string, now time.Time) (*sourceState, bool) {
	if state := a.entries[source]; state != nil {
		return state, true
	}
	if len(a.entries) >= a.maximumEntries {
		a.cleanupLocked(now)
	}
	if len(a.entries) >= a.maximumEntries {
		return nil, false
	}
	state := &sourceState{lastSeen: now}
	a.entries[source] = state
	return state, true
}

func (a *sourceAdmission) cleanupLocked(now time.Time) {
	for source, state := range a.entries {
		if state.connections == 0 && (now.Before(state.lastSeen) || now.Sub(state.lastSeen) >= sourceIdleExpiry) {
			delete(a.entries, source)
		}
	}
}

func (a *sourceAdmission) source(request *http.Request) string {
	address := strings.TrimSpace(request.RemoteAddr)
	host, _, err := net.SplitHostPort(address)
	if err == nil {
		if direct := net.ParseIP(host); direct != nil {
			if !a.isTrustedProxy(direct) {
				return direct.String()
			}
			forwarded := strings.Split(request.Header.Get("X-Forwarded-For"), ",")
			for index := len(forwarded) - 1; index >= 0; index-- {
				candidate := net.ParseIP(strings.TrimSpace(forwarded[index]))
				if candidate == nil {
					return direct.String()
				}
				if !a.isTrustedProxy(candidate) {
					return candidate.String()
				}
			}
			return direct.String()
		}
		return strings.ToLower(host)
	}
	if parsed := net.ParseIP(address); parsed != nil {
		return parsed.String()
	}
	if address == "" {
		return "unknown"
	}
	return strings.ToLower(address)
}

func (a *sourceAdmission) isTrustedProxy(address net.IP) bool {
	for _, network := range a.trustedProxies {
		if network.Contains(address) {
			return true
		}
	}
	return false
}

func (s *Service) acquireHostConnection(source string) bool {
	if !s.admission.acquireConnection(source) {
		return false
	}
	select {
	case s.connections <- struct{}{}:
		return true
	default:
		s.admission.releaseConnection(source)
		return false
	}
}

func (s *Service) releaseHostConnection(source string) {
	<-s.connections
	s.admission.releaseConnection(source)
}

func (s *Service) acquireViewerConnection(source, room string) bool {
	if !s.admission.acquireConnection(source) {
		return false
	}
	if !s.acquireViewerRoomSlot(room) {
		s.admission.releaseConnection(source)
		return false
	}
	select {
	case s.viewerConnections <- struct{}{}:
	default:
		s.releaseViewerRoomSlot(room)
		s.admission.releaseConnection(source)
		return false
	}
	select {
	case s.connections <- struct{}{}:
		return true
	default:
		<-s.viewerConnections
		s.releaseViewerRoomSlot(room)
		s.admission.releaseConnection(source)
		return false
	}
}

func (s *Service) releaseViewerConnection(source, room string) {
	<-s.connections
	<-s.viewerConnections
	s.releaseViewerRoomSlot(room)
	s.admission.releaseConnection(source)
}

func (s *Service) acquireViewerRoomSlot(room string) bool {
	s.viewerRoomsMu.Lock()
	defer s.viewerRoomsMu.Unlock()
	if s.viewerRooms[room] >= protocol.MaximumPendingViewersPerRoom {
		return false
	}
	s.viewerRooms[room]++
	return true
}

func (s *Service) releaseViewerRoomSlot(room string) {
	s.viewerRoomsMu.Lock()
	defer s.viewerRoomsMu.Unlock()
	if s.viewerRooms[room] <= 1 {
		delete(s.viewerRooms, room)
		return
	}
	s.viewerRooms[room]--
}
