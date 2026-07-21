package signaling

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

const (
	CloseNormal          = 1000
	CloseGoingAway       = 1001
	CloseProtocolError   = 1002
	ClosePolicyViolation = 1008
	CloseMessageTooBig   = 1009
	CloseTryAgainLater   = 1013
)

var (
	ErrHostUnavailable   = errors.New("host is unavailable")
	ErrRouteLimit        = errors.New("pending route limit reached")
	ErrRouteNotFound     = errors.New("route not found")
	ErrHostReplaced      = errors.New("host connection was replaced")
	ErrStaleHost         = errors.New("host connection is stale")
	ErrStaleViewer       = errors.New("viewer connection is stale")
	ErrSequence          = errors.New("relay sequence is not monotonic")
	ErrRouteBackpressure = errors.New("route signaling capacity exceeded")
)

// Peer is the narrow transport boundary used by the routing hub. Implementing
// it over a single-writer WebSocket keeps the state machine independently
// testable and race-detector friendly.
type Peer interface {
	Send(protocol.Message) error
	Close(code int, reason string)
}

type Configuration struct {
	MaximumPendingRoutes         int
	RouteIdleTimeout             time.Duration
	RelayBurstWindow             time.Duration
	MaximumRelayMessagesPerBurst int
	MaximumRelayBytesPerBurst    int
	Now                          func() time.Time
	Random                       func([]byte) error
}

type Hub struct {
	mu     sync.Mutex
	rooms  map[string]*roomState
	config Configuration
}

type roomState struct {
	generation     uint64
	hostGeneration uint64
	host           *hostState
	routes         map[string]*routeState
}

type hostState struct {
	id         string
	generation uint64
	peer       Peer
}

type routeState struct {
	id             string
	viewer         Peer
	viewerSequence uint64
	hostSequence   uint64
	lastActivity   time.Time
	viewerBudget   relayBurstBudget
	hostBudget     relayBurstBudget
}

type relayBurstBudget struct {
	initialized   bool
	lastRefill    time.Time
	messageTokens float64
	byteTokens    float64
}

func NewHub(configuration Configuration) *Hub {
	if configuration.MaximumPendingRoutes <= 0 {
		configuration.MaximumPendingRoutes = protocol.MaximumPendingViewersPerRoom
	}
	if configuration.RelayBurstWindow <= 0 {
		configuration.RelayBurstWindow = time.Second
	}
	if configuration.MaximumRelayMessagesPerBurst <= 0 {
		configuration.MaximumRelayMessagesPerBurst = 64
	}
	if configuration.MaximumRelayBytesPerBurst <= 0 {
		configuration.MaximumRelayBytesPerBurst = 2 << 20
	}
	if configuration.Now == nil {
		configuration.Now = time.Now
	}
	if configuration.Random == nil {
		configuration.Random = func(destination []byte) error {
			_, err := rand.Read(destination)
			return err
		}
	}
	return &Hub{rooms: make(map[string]*roomState), config: configuration}
}

// RegisterHost replaces an earlier host generation and closes every route
// associated with that earlier generation.
func (h *Hub) RegisterHost(room, hostID string, peer Peer) {
	h.registerHost(room, 0, 0, hostID, peer, false)
}

// RegisterHostGeneration installs a host only when its registry-issued room and
// host generations are not stale. This keeps independently locked registry and
// routing state linearizable during overlapping reconnects.
func (h *Hub) RegisterHostGeneration(room string, roomGeneration, hostGeneration uint64, hostID string, peer Peer) bool {
	if roomGeneration == 0 || hostGeneration == 0 {
		return false
	}
	return h.registerHost(room, roomGeneration, hostGeneration, hostID, peer, true)
}

func (h *Hub) registerHost(room string, roomGeneration, hostGeneration uint64, hostID string, peer Peer, enforceGeneration bool) bool {
	h.mu.Lock()
	state := h.roomLocked(room)
	if enforceGeneration {
		if state.generation > roomGeneration ||
			(state.generation == roomGeneration && state.hostGeneration >= hostGeneration) {
			h.mu.Unlock()
			return false
		}
	} else {
		roomGeneration = state.generation
		hostGeneration = 1
		if state.hostGeneration != 0 {
			hostGeneration = state.hostGeneration + 1
			if hostGeneration == 0 {
				hostGeneration = 1
			}
		}
	}
	oldHost := state.host
	oldRoutes := collectRoutes(state.routes)
	state.generation = roomGeneration
	state.hostGeneration = hostGeneration
	state.host = &hostState{id: hostID, generation: hostGeneration, peer: peer}
	state.routes = make(map[string]*routeState)
	h.mu.Unlock()

	if oldHost != nil && oldHost.peer != peer {
		oldHost.peer.Close(CloseGoingAway, "host replaced")
	}
	for _, route := range oldRoutes {
		notifyAndClose(route.viewer, protocol.Message{Type: protocol.MessageHostUnavailable}, CloseGoingAway, "host replaced")
	}
	return true
}

func (h *Hub) UnregisterHost(room, hostID string) bool {
	h.mu.Lock()
	state, found := h.rooms[room]
	if !found || state.host == nil || state.host.id != hostID {
		h.mu.Unlock()
		return false
	}
	routes := collectRoutes(state.routes)
	state.host = nil
	state.routes = make(map[string]*routeState)
	h.deleteEmptyRoomLocked(room, state)
	h.mu.Unlock()

	for _, route := range routes {
		notifyAndClose(route.viewer, protocol.Message{Type: protocol.MessageHostUnavailable}, CloseGoingAway, "host unavailable")
	}
	return true
}

func (h *Hub) HasHost(room string) bool {
	return h.hasHost(room, 0, false)
}

func (h *Hub) HasHostGeneration(room string, generation uint64) bool {
	return h.hasHost(room, generation, true)
}

func (h *Hub) hasHost(room string, generation uint64, enforceGeneration bool) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	state, found := h.rooms[room]
	return found && state.host != nil && (!enforceGeneration || state.generation == generation)
}

// OpenRoute allocates an opaque route and sends the same identifier to both
// endpoints. Only the host receives the viewer's public key.
func (h *Hub) OpenRoute(room, viewerKey string, viewer Peer) (string, error) {
	return h.openRoute(room, 0, false, viewerKey, viewer)
}

func (h *Hub) OpenRouteGeneration(room string, generation uint64, viewerKey string, viewer Peer) (string, error) {
	return h.openRoute(room, generation, true, viewerKey, viewer)
}

func (h *Hub) openRoute(room string, generation uint64, enforceGeneration bool, viewerKey string, viewer Peer) (string, error) {
	h.mu.Lock()
	state, found := h.rooms[room]
	if !found || state.host == nil || (enforceGeneration && state.generation != generation) {
		h.mu.Unlock()
		return "", ErrHostUnavailable
	}
	if len(state.routes) >= h.config.MaximumPendingRoutes {
		h.mu.Unlock()
		return "", ErrRouteLimit
	}
	routeID, err := h.uniqueRouteIDLocked(state)
	if err != nil {
		h.mu.Unlock()
		return "", err
	}
	host := state.host
	route := &routeState{
		id:           routeID,
		viewer:       viewer,
		lastActivity: h.config.Now(),
	}
	state.routes[routeID] = route
	h.mu.Unlock()

	viewerOpened := protocol.Message{Type: protocol.MessageRouteOpened, RouteID: routeID}
	hostOpened := protocol.Message{Type: protocol.MessageRouteOpened, RouteID: routeID, ViewerKey: viewerKey}
	if err := viewer.Send(viewerOpened); err != nil {
		h.CloseViewerRoute(room, routeID, viewer, "viewer unavailable")
		return "", err
	}
	if err := host.peer.Send(hostOpened); err != nil {
		h.CloseViewerRoute(room, routeID, viewer, "host unavailable")
		return "", ErrHostUnavailable
	}
	return routeID, nil
}

func (h *Hub) RelayFromHost(room, hostID string, message protocol.Message) error {
	if err := protocol.ValidateRelay(message, true); err != nil {
		return err
	}
	h.mu.Lock()
	state, found := h.rooms[room]
	if !found || state.host == nil || state.host.id != hostID {
		h.mu.Unlock()
		return ErrStaleHost
	}
	route, found := state.routes[message.RouteID]
	if !found {
		h.mu.Unlock()
		return ErrRouteNotFound
	}
	if message.Sequence != route.hostSequence+1 {
		h.mu.Unlock()
		return ErrSequence
	}
	if !route.hostBudget.allow(h.config.Now(), h.config, relayMessageBytes(message)) {
		viewer := route.viewer
		h.mu.Unlock()
		h.CloseViewerRoute(room, message.RouteID, viewer, "signaling rate limit")
		return ErrRouteBackpressure
	}
	route.hostSequence = message.Sequence
	route.lastActivity = h.config.Now()
	viewer := route.viewer
	h.mu.Unlock()

	if err := viewer.Send(message); err != nil {
		reason := "viewer unavailable"
		if errors.Is(err, ErrOutboundQueueFull) || errors.Is(err, ErrRouteQueueFull) {
			reason = "signaling backpressure"
		}
		h.CloseViewerRoute(room, message.RouteID, viewer, reason)
		return ErrStaleViewer
	}
	return nil
}

func (h *Hub) RelayFromViewer(room, routeID string, viewer Peer, message protocol.Message) error {
	if err := protocol.ValidateRelay(message, false); err != nil {
		return err
	}
	h.mu.Lock()
	state, found := h.rooms[room]
	if !found || state.host == nil {
		h.mu.Unlock()
		return ErrHostUnavailable
	}
	route, found := state.routes[routeID]
	if !found || route.viewer != viewer {
		h.mu.Unlock()
		return ErrStaleViewer
	}
	if message.Sequence != route.viewerSequence+1 {
		h.mu.Unlock()
		return ErrSequence
	}
	message.RouteID = routeID
	if !route.viewerBudget.allow(h.config.Now(), h.config, relayMessageBytes(message)) {
		h.mu.Unlock()
		h.CloseViewerRoute(room, routeID, viewer, "signaling rate limit")
		return ErrRouteBackpressure
	}
	route.viewerSequence = message.Sequence
	route.lastActivity = h.config.Now()
	host := state.host
	h.mu.Unlock()

	if err := host.peer.Send(message); err != nil {
		if errors.Is(err, ErrOutboundQueueFull) || errors.Is(err, ErrRouteQueueFull) {
			h.CloseViewerRoute(room, routeID, viewer, "signaling backpressure")
			return ErrRouteBackpressure
		}
		h.CloseViewerRoute(room, routeID, viewer, "host unavailable")
		return ErrHostUnavailable
	}
	return nil
}

func (b *relayBurstBudget) allow(now time.Time, configuration Configuration, messageBytes int) bool {
	messageCapacity := float64(configuration.MaximumRelayMessagesPerBurst)
	byteCapacity := float64(configuration.MaximumRelayBytesPerBurst)
	if !b.initialized {
		b.initialized = true
		b.lastRefill = now
		b.messageTokens = messageCapacity
		b.byteTokens = byteCapacity
	} else {
		elapsed := now.Sub(b.lastRefill)
		if elapsed < 0 {
			elapsed = 0
		}
		refill := float64(elapsed) / float64(configuration.RelayBurstWindow)
		b.messageTokens = min(messageCapacity, b.messageTokens+refill*messageCapacity)
		b.byteTokens = min(byteCapacity, b.byteTokens+refill*byteCapacity)
		b.lastRefill = now
	}
	if b.messageTokens < 1 || b.byteTokens < float64(messageBytes) {
		return false
	}
	b.messageTokens--
	b.byteTokens -= float64(messageBytes)
	return true
}

func relayMessageBytes(message protocol.Message) int {
	encoded, err := json.Marshal(message)
	if err != nil {
		return protocol.MaximumMessageBytes + 1
	}
	return len(encoded)
}

func (h *Hub) CloseRouteFromHost(room, hostID, routeID, reason string) error {
	h.mu.Lock()
	state, found := h.rooms[room]
	if !found || state.host == nil || state.host.id != hostID {
		h.mu.Unlock()
		return ErrStaleHost
	}
	route, found := state.routes[routeID]
	if !found {
		h.mu.Unlock()
		return ErrRouteNotFound
	}
	delete(state.routes, routeID)
	h.mu.Unlock()

	notifyAndClose(route.viewer, protocol.Message{Type: protocol.MessageRouteClosed, RouteID: routeID, Reason: boundedReason(reason)}, CloseNormal, "route closed")
	return nil
}

func (h *Hub) CloseViewerRoute(room, routeID string, viewer Peer, reason string) bool {
	h.mu.Lock()
	state, found := h.rooms[room]
	if !found {
		h.mu.Unlock()
		return false
	}
	route, found := state.routes[routeID]
	if !found || route.viewer != viewer {
		h.mu.Unlock()
		return false
	}
	delete(state.routes, routeID)
	host := state.host
	h.deleteEmptyRoomLocked(room, state)
	h.mu.Unlock()

	if host != nil {
		_ = host.peer.Send(protocol.Message{
			Type:    protocol.MessageRouteClosed,
			RouteID: routeID,
			Reason:  boundedReason(reason),
		})
	}
	viewer.Close(CloseNormal, "route closed")
	return true
}

func (h *Hub) CloseRoom(room, reason string) {
	h.closeRoom(room, 0, false, reason)
}

func (h *Hub) CloseRoomGeneration(room string, generation uint64, reason string) bool {
	return h.closeRoom(room, generation, true, reason)
}

func (h *Hub) closeRoom(room string, generation uint64, enforceGeneration bool, reason string) bool {
	h.mu.Lock()
	state, found := h.rooms[room]
	if !found || (enforceGeneration && state.generation != generation) {
		h.mu.Unlock()
		return false
	}
	delete(h.rooms, room)
	host := state.host
	routes := collectRoutes(state.routes)
	h.mu.Unlock()

	if host != nil {
		host.peer.Close(CloseGoingAway, boundedReason(reason))
	}
	for _, route := range routes {
		notifyAndClose(route.viewer, protocol.Message{Type: protocol.MessageHostUnavailable}, CloseGoingAway, boundedReason(reason))
	}
	return true
}

// CleanupIdleRoutes prevents silent browser connections from occupying every
// pending route indefinitely. It returns the number removed.
func (h *Hub) CleanupIdleRoutes() int {
	cutoff := h.config.Now().Add(-h.config.RouteIdleTimeout)
	type removedRoute struct {
		host    Peer
		viewer  Peer
		routeID string
	}
	removed := make([]removedRoute, 0)

	h.mu.Lock()
	for room, state := range h.rooms {
		for routeID, route := range state.routes {
			if route.lastActivity.After(cutoff) {
				continue
			}
			var host Peer
			if state.host != nil {
				host = state.host.peer
			}
			removed = append(removed, removedRoute{host: host, viewer: route.viewer, routeID: routeID})
			delete(state.routes, routeID)
		}
		h.deleteEmptyRoomLocked(room, state)
	}
	h.mu.Unlock()

	for _, route := range removed {
		if route.host != nil {
			_ = route.host.Send(protocol.Message{Type: protocol.MessageRouteClosed, RouteID: route.routeID, Reason: "route idle timeout"})
		}
		notifyAndClose(route.viewer, protocol.Message{Type: protocol.MessageRouteClosed, RouteID: route.routeID, Reason: "route idle timeout"}, CloseGoingAway, "route idle timeout")
	}
	return len(removed)
}

func (h *Hub) PendingRouteCount(room string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	state, found := h.rooms[room]
	if !found {
		return 0
	}
	return len(state.routes)
}

func (h *Hub) roomLocked(room string) *roomState {
	state, found := h.rooms[room]
	if !found {
		state = &roomState{routes: make(map[string]*routeState)}
		h.rooms[room] = state
	}
	return state
}

func (h *Hub) uniqueRouteIDLocked(state *roomState) (string, error) {
	for attempt := 0; attempt < 16; attempt++ {
		bytes := make([]byte, protocol.RouteIDBytes)
		if err := h.config.Random(bytes); err != nil {
			return "", fmt.Errorf("generate route identifier: %w", err)
		}
		identifier := base64.RawURLEncoding.EncodeToString(bytes)
		if _, exists := state.routes[identifier]; !exists {
			return identifier, nil
		}
	}
	return "", errors.New("could not allocate a unique route identifier")
}

func (h *Hub) deleteEmptyRoomLocked(room string, state *roomState) {
	if state.generation == 0 && state.host == nil && len(state.routes) == 0 {
		delete(h.rooms, room)
	}
}

func collectRoutes(routes map[string]*routeState) []*routeState {
	result := make([]*routeState, 0, len(routes))
	for _, route := range routes {
		result = append(result, route)
	}
	return result
}

func notifyAndClose(peer Peer, message protocol.Message, code int, reason string) {
	_ = peer.Send(message)
	peer.Close(code, boundedReason(reason))
}

func boundedReason(reason string) string {
	if len(reason) > 120 {
		return reason[:120]
	}
	return reason
}
