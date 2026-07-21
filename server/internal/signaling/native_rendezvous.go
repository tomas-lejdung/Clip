package signaling

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

var (
	ErrNativeRendezvousNotFound = errors.New("native rendezvous not found")
	ErrNativeRendezvousConflict = errors.New("native rendezvous is already owned")
	ErrNativeUnauthorized       = errors.New("native rendezvous owner capability was rejected")
	ErrNativeCapacity           = errors.New("native rendezvous capacity reached")
	ErrNativeHostUnavailable    = errors.New("native rendezvous host is unavailable")
	ErrNativeNotLive            = errors.New("native rendezvous is not live")
)

type NativeRendezvousState string

const (
	NativeRendezvousOffline   NativeRendezvousState = "offline"
	NativeRendezvousPreparing NativeRendezvousState = "preparing"
	NativeRendezvousActive    NativeRendezvousState = "active"
)

type NativeRendezvousConfiguration struct {
	LeaseDuration                time.Duration
	ReconnectGrace               time.Duration
	MaximumRendezvous            int
	MaximumPendingRoutes         int
	RouteIdleTimeout             time.Duration
	RelayBurstWindow             time.Duration
	MaximumRelayMessagesPerBurst int
	MaximumRelayBytesPerBurst    int
	Now                          func() time.Time
	Random                       func([]byte) error
}

type NativeAdvertisement struct {
	Created bool
	Lease   time.Duration
}

type NativeRendezvousSnapshot struct {
	RendezvousID string
	State        NativeRendezvousState
}

type NativeCleanupResult struct {
	ExpiredRendezvous int
	IdleRoutes        int
}

type nativeRendezvous struct {
	ownerHash  [32]byte
	expiresAt  time.Time
	host       *nativeHost
	active     bool
	descriptor string
	routes     map[string]*nativeRoute
}

type nativeHost struct {
	id   string
	peer Peer
}

type nativeRoute struct {
	id             string
	viewer         Peer
	viewerSequence uint64
	hostSequence   uint64
	lastActivity   time.Time
	viewerBudget   relayBurstBudget
	hostBudget     relayBurstBudget
}

// NativeRendezvousHub owns the complete native-friend rendezvous lifecycle
// under one lock. That makes active-state transitions and viewer-route opening
// linearizable: after a stop returns, no route created from the old signed
// descriptor can remain or be admitted.
//
// The service stores only an owner-token hash, an opaque high-entropy ID, an
// opaque signed descriptor, connection handles, and temporary routing state.
// Friend names, passwords, identity keys, media state, and established viewer
// truth remain client-side.
type NativeRendezvousHub struct {
	mu      sync.Mutex
	entries map[string]*nativeRendezvous
	config  NativeRendezvousConfiguration
}

func NewNativeRendezvousHub(configuration NativeRendezvousConfiguration) *NativeRendezvousHub {
	if configuration.LeaseDuration <= 0 {
		configuration.LeaseDuration = 5 * time.Minute
	}
	if configuration.ReconnectGrace <= 0 {
		configuration.ReconnectGrace = 30 * time.Second
	}
	if configuration.MaximumRendezvous <= 0 {
		configuration.MaximumRendezvous = 1_024
	}
	if configuration.MaximumPendingRoutes <= 0 {
		configuration.MaximumPendingRoutes = protocol.MaximumPendingViewersPerRoom
	}
	if configuration.RouteIdleTimeout <= 0 {
		configuration.RouteIdleTimeout = 2 * time.Minute
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
	return &NativeRendezvousHub{
		entries: make(map[string]*nativeRendezvous),
		config:  configuration,
	}
}

func (h *NativeRendezvousHub) Advertise(rendezvousID string, ownerHash [32]byte) (NativeAdvertisement, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	now := h.config.Now()
	if existing, found := h.entries[rendezvousID]; found {
		if h.expiredLocked(existing, now) {
			delete(h.entries, rendezvousID)
		} else {
			if !sameNativeOwner(existing.ownerHash, ownerHash) {
				return NativeAdvertisement{Lease: h.config.LeaseDuration}, ErrNativeRendezvousConflict
			}
			if existing.host == nil {
				existing.expiresAt = now.Add(h.config.LeaseDuration)
			}
			return NativeAdvertisement{Lease: h.config.LeaseDuration}, nil
		}
	}

	if len(h.entries) >= h.config.MaximumRendezvous {
		h.purgeExpiredLocked(now)
	}
	if len(h.entries) >= h.config.MaximumRendezvous {
		return NativeAdvertisement{Lease: h.config.LeaseDuration}, ErrNativeCapacity
	}
	h.entries[rendezvousID] = &nativeRendezvous{
		ownerHash: ownerHash,
		expiresAt: now.Add(h.config.LeaseDuration),
		routes:    make(map[string]*nativeRoute),
	}
	return NativeAdvertisement{Created: true, Lease: h.config.LeaseDuration}, nil
}

func (h *NativeRendezvousHub) Snapshot(rendezvousID string) (NativeRendezvousSnapshot, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	entry, found := h.liveEntryLocked(rendezvousID, h.config.Now())
	if !found {
		return NativeRendezvousSnapshot{}, false
	}
	return NativeRendezvousSnapshot{
		RendezvousID: rendezvousID,
		State:        nativeState(entry),
	}, true
}

func (h *NativeRendezvousHub) Authenticate(rendezvousID string, ownerHash [32]byte) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	entry, found := h.liveEntryLocked(rendezvousID, h.config.Now())
	if !found {
		return ErrNativeRendezvousNotFound
	}
	if !sameNativeOwner(entry.ownerHash, ownerHash) {
		return ErrNativeUnauthorized
	}
	return nil
}

func (h *NativeRendezvousHub) AttachHost(rendezvousID string, ownerHash [32]byte, hostID string, peer Peer) error {
	if hostID == "" || peer == nil {
		return ErrNativeHostUnavailable
	}
	h.mu.Lock()
	entry, found := h.liveEntryLocked(rendezvousID, h.config.Now())
	if !found {
		h.mu.Unlock()
		return ErrNativeRendezvousNotFound
	}
	if !sameNativeOwner(entry.ownerHash, ownerHash) {
		h.mu.Unlock()
		return ErrNativeUnauthorized
	}
	oldHost := entry.host
	oldRoutes := nativeRoutes(entry.routes)
	entry.host = &nativeHost{id: hostID, peer: peer}
	entry.active = false
	entry.descriptor = ""
	entry.expiresAt = time.Time{}
	entry.routes = make(map[string]*nativeRoute)
	h.mu.Unlock()

	if oldHost != nil && oldHost.peer != peer {
		oldHost.peer.Close(CloseGoingAway, "native host replaced")
	}
	closeNativeViewers(oldRoutes, "native host replaced")
	return nil
}

func (h *NativeRendezvousHub) RenewHost(rendezvousID, hostID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	entry, found := h.entries[rendezvousID]
	return found && entry.host != nil && entry.host.id == hostID
}

func (h *NativeRendezvousHub) DetachHost(rendezvousID, hostID string) bool {
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found || entry.host == nil || entry.host.id != hostID {
		h.mu.Unlock()
		return false
	}
	routes := nativeRoutes(entry.routes)
	entry.host = nil
	entry.active = false
	entry.descriptor = ""
	entry.routes = make(map[string]*nativeRoute)
	entry.expiresAt = h.config.Now().Add(h.config.ReconnectGrace)
	h.mu.Unlock()

	closeNativeViewers(routes, "native host unavailable")
	return true
}

func (h *NativeRendezvousHub) Activate(rendezvousID string, ownerHash [32]byte, descriptor string) error {
	if err := protocol.ValidateNativeDescriptor(descriptor); err != nil {
		return err
	}
	h.mu.Lock()
	entry, found := h.liveEntryLocked(rendezvousID, h.config.Now())
	if !found {
		h.mu.Unlock()
		return ErrNativeRendezvousNotFound
	}
	if !sameNativeOwner(entry.ownerHash, ownerHash) {
		h.mu.Unlock()
		return ErrNativeUnauthorized
	}
	if entry.host == nil {
		h.mu.Unlock()
		return ErrNativeHostUnavailable
	}
	routes := nativeRoutes(entry.routes)
	host := entry.host.peer
	entry.active = true
	entry.descriptor = descriptor
	entry.routes = make(map[string]*nativeRoute)
	h.mu.Unlock()

	retireNativeRoutes(host, routes, "native session replaced")
	return nil
}

func (h *NativeRendezvousHub) Deactivate(rendezvousID string, ownerHash [32]byte) error {
	h.mu.Lock()
	entry, found := h.liveEntryLocked(rendezvousID, h.config.Now())
	if !found {
		h.mu.Unlock()
		return ErrNativeRendezvousNotFound
	}
	if !sameNativeOwner(entry.ownerHash, ownerHash) {
		h.mu.Unlock()
		return ErrNativeUnauthorized
	}
	routes := nativeRoutes(entry.routes)
	var host Peer
	if entry.host != nil {
		host = entry.host.peer
	}
	entry.active = false
	entry.descriptor = ""
	entry.routes = make(map[string]*nativeRoute)
	h.mu.Unlock()

	retireNativeRoutes(host, routes, "native sharing stopped")
	return nil
}

func (h *NativeRendezvousHub) Remove(rendezvousID string, ownerHash [32]byte) error {
	h.mu.Lock()
	entry, found := h.liveEntryLocked(rendezvousID, h.config.Now())
	if !found {
		h.mu.Unlock()
		return ErrNativeRendezvousNotFound
	}
	if !sameNativeOwner(entry.ownerHash, ownerHash) {
		h.mu.Unlock()
		return ErrNativeUnauthorized
	}
	delete(h.entries, rendezvousID)
	host := entry.host
	routes := nativeRoutes(entry.routes)
	h.mu.Unlock()

	if host != nil {
		host.peer.Close(CloseGoingAway, "native rendezvous removed")
	}
	closeNativeViewers(routes, "native rendezvous removed")
	return nil
}

func (h *NativeRendezvousHub) OpenRoute(rendezvousID string, viewer Peer) (string, error) {
	if viewer == nil {
		return "", ErrNativeHostUnavailable
	}
	h.mu.Lock()
	entry, found := h.liveEntryLocked(rendezvousID, h.config.Now())
	if !found {
		h.mu.Unlock()
		return "", ErrNativeRendezvousNotFound
	}
	if entry.host == nil {
		h.mu.Unlock()
		return "", ErrNativeHostUnavailable
	}
	if !entry.active || entry.descriptor == "" {
		h.mu.Unlock()
		return "", ErrNativeNotLive
	}
	if len(entry.routes) >= h.config.MaximumPendingRoutes {
		h.mu.Unlock()
		return "", ErrRouteLimit
	}
	routeID, err := h.uniqueRouteIDLocked(entry)
	if err != nil {
		h.mu.Unlock()
		return "", err
	}
	route := &nativeRoute{
		id:           routeID,
		viewer:       viewer,
		lastActivity: h.config.Now(),
	}
	entry.routes[routeID] = route
	viewerOpened := protocol.Message{
		Type:    protocol.MessageNativeRouteOpened,
		Version: protocol.NativeMessageVersion,
		RouteID: routeID,
		Payload: entry.descriptor,
	}
	hostOpened := protocol.Message{
		Type:    protocol.MessageNativeRouteOpened,
		Version: protocol.NativeMessageVersion,
		RouteID: routeID,
	}
	if err := viewer.Send(viewerOpened); err != nil {
		delete(entry.routes, routeID)
		h.mu.Unlock()
		viewer.Close(CloseGoingAway, "native viewer unavailable")
		return "", err
	}
	if err := entry.host.peer.Send(hostOpened); err != nil {
		delete(entry.routes, routeID)
		h.mu.Unlock()
		notifyAndClose(viewer, protocol.Message{
			Type:    protocol.MessageNativeHostUnavailable,
			Version: protocol.NativeMessageVersion,
		}, CloseGoingAway, "native host unavailable")
		return "", ErrNativeHostUnavailable
	}
	h.mu.Unlock()
	return routeID, nil
}

func (h *NativeRendezvousHub) RelayFromHost(rendezvousID, hostID string, message protocol.Message) error {
	if err := protocol.ValidateNativeRelay(message, true); err != nil {
		return err
	}
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found || entry.host == nil || entry.host.id != hostID {
		h.mu.Unlock()
		return ErrStaleHost
	}
	route, found := entry.routes[message.RouteID]
	if !found {
		h.mu.Unlock()
		return ErrRouteNotFound
	}
	if message.Sequence != route.hostSequence+1 {
		h.mu.Unlock()
		return ErrSequence
	}
	if !route.hostBudget.allow(h.config.Now(), nativeRelayConfiguration(h.config), relayMessageBytes(message)) {
		delete(entry.routes, message.RouteID)
		h.mu.Unlock()
		notifyAndClose(route.viewer, nativeRouteClosed(message.RouteID, "signaling rate limit"), CloseGoingAway, "signaling rate limit")
		return ErrRouteBackpressure
	}
	route.hostSequence = message.Sequence
	route.lastActivity = h.config.Now()
	if err := route.viewer.Send(message); err != nil {
		delete(entry.routes, message.RouteID)
		h.mu.Unlock()
		route.viewer.Close(CloseGoingAway, "native viewer unavailable")
		return ErrStaleViewer
	}
	h.mu.Unlock()
	return nil
}

func (h *NativeRendezvousHub) RelayFromViewer(rendezvousID, routeID string, viewer Peer, message protocol.Message) error {
	if err := protocol.ValidateNativeRelay(message, false); err != nil {
		return err
	}
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found || entry.host == nil || !entry.active {
		h.mu.Unlock()
		return ErrNativeHostUnavailable
	}
	route, found := entry.routes[routeID]
	if !found || route.viewer != viewer {
		h.mu.Unlock()
		return ErrStaleViewer
	}
	if message.Sequence != route.viewerSequence+1 {
		h.mu.Unlock()
		return ErrSequence
	}
	message.RouteID = routeID
	if !route.viewerBudget.allow(h.config.Now(), nativeRelayConfiguration(h.config), relayMessageBytes(message)) {
		delete(entry.routes, routeID)
		h.mu.Unlock()
		viewer.Close(CloseGoingAway, "signaling rate limit")
		return ErrRouteBackpressure
	}
	route.viewerSequence = message.Sequence
	route.lastActivity = h.config.Now()
	if err := entry.host.peer.Send(message); err != nil {
		delete(entry.routes, routeID)
		h.mu.Unlock()
		viewer.Close(CloseGoingAway, "native host unavailable")
		return ErrNativeHostUnavailable
	}
	h.mu.Unlock()
	return nil
}

func (h *NativeRendezvousHub) CloseRouteFromHost(rendezvousID, hostID, routeID, reason string) error {
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found || entry.host == nil || entry.host.id != hostID {
		h.mu.Unlock()
		return ErrStaleHost
	}
	route, found := entry.routes[routeID]
	if !found {
		h.mu.Unlock()
		return ErrRouteNotFound
	}
	delete(entry.routes, routeID)
	h.mu.Unlock()
	notifyAndClose(route.viewer, nativeRouteClosed(routeID, reason), CloseNormal, "native route closed")
	return nil
}

func (h *NativeRendezvousHub) CloseViewerRoute(rendezvousID, routeID string, viewer Peer, reason string) bool {
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found {
		h.mu.Unlock()
		return false
	}
	route, found := entry.routes[routeID]
	if !found || route.viewer != viewer {
		h.mu.Unlock()
		return false
	}
	delete(entry.routes, routeID)
	var host Peer
	if entry.host != nil {
		host = entry.host.peer
	}
	h.mu.Unlock()
	if host != nil {
		_ = host.Send(nativeRouteClosed(routeID, reason))
	}
	viewer.Close(CloseNormal, "native route closed")
	return true
}

func (h *NativeRendezvousHub) PendingRouteCount(rendezvousID string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	entry := h.entries[rendezvousID]
	if entry == nil {
		return 0
	}
	return len(entry.routes)
}

func (h *NativeRendezvousHub) Cleanup() NativeCleanupResult {
	now := h.config.Now()
	cutoff := now.Add(-h.config.RouteIdleTimeout)
	type idleRoute struct {
		host  Peer
		route *nativeRoute
	}
	idle := make([]idleRoute, 0)
	result := NativeCleanupResult{}

	h.mu.Lock()
	for rendezvousID, entry := range h.entries {
		if h.expiredLocked(entry, now) {
			delete(h.entries, rendezvousID)
			result.ExpiredRendezvous++
			continue
		}
		for routeID, route := range entry.routes {
			if route.lastActivity.After(cutoff) {
				continue
			}
			var host Peer
			if entry.host != nil {
				host = entry.host.peer
			}
			idle = append(idle, idleRoute{host: host, route: route})
			delete(entry.routes, routeID)
			result.IdleRoutes++
		}
	}
	h.mu.Unlock()

	for _, expired := range idle {
		if expired.host != nil {
			_ = expired.host.Send(nativeRouteClosed(expired.route.id, "route idle timeout"))
		}
		notifyAndClose(expired.route.viewer, nativeRouteClosed(expired.route.id, "route idle timeout"), CloseGoingAway, "route idle timeout")
	}
	return result
}

func (h *NativeRendezvousHub) Shutdown(reason string) {
	h.mu.Lock()
	entries := make([]*nativeRendezvous, 0, len(h.entries))
	for _, entry := range h.entries {
		entries = append(entries, entry)
	}
	h.entries = make(map[string]*nativeRendezvous)
	h.mu.Unlock()

	for _, entry := range entries {
		if entry.host != nil {
			entry.host.peer.Close(CloseGoingAway, boundedReason(reason))
		}
		closeNativeViewers(nativeRoutes(entry.routes), reason)
	}
}

func (h *NativeRendezvousHub) uniqueRouteIDLocked(entry *nativeRendezvous) (string, error) {
	for attempt := 0; attempt < 16; attempt++ {
		bytes := make([]byte, protocol.RouteIDBytes)
		if err := h.config.Random(bytes); err != nil {
			return "", fmt.Errorf("generate native route identifier: %w", err)
		}
		identifier := base64.RawURLEncoding.EncodeToString(bytes)
		if _, found := entry.routes[identifier]; !found {
			return identifier, nil
		}
	}
	return "", errors.New("could not allocate a unique native route identifier")
}

func (h *NativeRendezvousHub) liveEntryLocked(rendezvousID string, now time.Time) (*nativeRendezvous, bool) {
	entry, found := h.entries[rendezvousID]
	if !found {
		return nil, false
	}
	if h.expiredLocked(entry, now) {
		delete(h.entries, rendezvousID)
		return nil, false
	}
	return entry, true
}

func (h *NativeRendezvousHub) expiredLocked(entry *nativeRendezvous, now time.Time) bool {
	return entry.host == nil && !entry.expiresAt.IsZero() && !now.Before(entry.expiresAt)
}

func (h *NativeRendezvousHub) purgeExpiredLocked(now time.Time) {
	for rendezvousID, entry := range h.entries {
		if h.expiredLocked(entry, now) {
			delete(h.entries, rendezvousID)
		}
	}
}

func nativeState(entry *nativeRendezvous) NativeRendezvousState {
	if entry.host == nil {
		return NativeRendezvousOffline
	}
	if entry.active {
		return NativeRendezvousActive
	}
	return NativeRendezvousPreparing
}

func nativeRoutes(routes map[string]*nativeRoute) []*nativeRoute {
	result := make([]*nativeRoute, 0, len(routes))
	for _, route := range routes {
		result = append(result, route)
	}
	return result
}

func nativeRelayConfiguration(configuration NativeRendezvousConfiguration) Configuration {
	return Configuration{
		RelayBurstWindow:             configuration.RelayBurstWindow,
		MaximumRelayMessagesPerBurst: configuration.MaximumRelayMessagesPerBurst,
		MaximumRelayBytesPerBurst:    configuration.MaximumRelayBytesPerBurst,
	}
}

func nativeRouteClosed(routeID, reason string) protocol.Message {
	return protocol.Message{
		Type:    protocol.MessageNativeRouteClosed,
		Version: protocol.NativeMessageVersion,
		RouteID: routeID,
		Reason:  boundedReason(reason),
	}
}

func closeNativeViewers(routes []*nativeRoute, reason string) {
	for _, route := range routes {
		notifyAndClose(route.viewer, protocol.Message{
			Type:    protocol.MessageNativeHostUnavailable,
			Version: protocol.NativeMessageVersion,
		}, CloseGoingAway, boundedReason(reason))
	}
}

func retireNativeRoutes(host Peer, routes []*nativeRoute, reason string) {
	for _, route := range routes {
		if host != nil {
			_ = host.Send(nativeRouteClosed(route.id, reason))
		}
		notifyAndClose(route.viewer, nativeRouteClosed(route.id, reason), CloseGoingAway, boundedReason(reason))
	}
}

func sameNativeOwner(left, right [32]byte) bool {
	return subtle.ConstantTimeCompare(left[:], right[:]) == 1
}
