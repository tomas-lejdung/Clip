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
	ErrNativeOwnerUnavailable   = errors.New("native rendezvous owner is unavailable")
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
	owner      *nativeOwner
	active     bool
	descriptor string
	routes     map[string]*nativeRoute
}

type nativeOwner struct {
	id   string
	peer Peer
}

type nativeRoute struct {
	id                string
	candidate         Peer
	candidateSequence uint64
	ownerSequence     uint64
	lastActivity      time.Time
	candidateBudget   relayBurstBudget
	ownerBudget       relayBurstBudget
}

// NativeRendezvousHub owns the complete native-v3 bootstrap rendezvous
// lifecycle under one lock. That makes active-state transitions and candidate
// route opening linearizable: after a stop returns, no route created from the
// old signed descriptor can remain or be admitted.
//
// The service stores only an owner-token hash, an opaque high-entropy ID, an
// opaque signed descriptor, connection handles, and temporary routing state.
// Access Words, identities, membership, leadership, media state, and
// established mesh truth remain client-side.
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
		configuration.MaximumPendingRoutes = protocol.MaximumPendingRoutes
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
			if existing.owner == nil {
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

func (h *NativeRendezvousHub) AttachOwner(rendezvousID string, ownerHash [32]byte, ownerID string, peer Peer) error {
	if ownerID == "" || peer == nil {
		return ErrNativeOwnerUnavailable
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
	oldOwner := entry.owner
	oldRoutes := nativeRoutes(entry.routes)
	entry.owner = &nativeOwner{id: ownerID, peer: peer}
	entry.active = false
	entry.descriptor = ""
	entry.expiresAt = time.Time{}
	entry.routes = make(map[string]*nativeRoute)
	h.mu.Unlock()

	if oldOwner != nil && oldOwner.peer != peer {
		oldOwner.peer.Close(CloseGoingAway, "native owner replaced")
	}
	closeNativeCandidates(oldRoutes, "native owner replaced")
	return nil
}

func (h *NativeRendezvousHub) RenewOwner(rendezvousID, ownerID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	entry, found := h.entries[rendezvousID]
	return found && entry.owner != nil && entry.owner.id == ownerID
}

func (h *NativeRendezvousHub) DetachOwner(rendezvousID, ownerID string) bool {
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found || entry.owner == nil || entry.owner.id != ownerID {
		h.mu.Unlock()
		return false
	}
	routes := nativeRoutes(entry.routes)
	entry.owner = nil
	entry.active = false
	entry.descriptor = ""
	entry.routes = make(map[string]*nativeRoute)
	entry.expiresAt = h.config.Now().Add(h.config.ReconnectGrace)
	h.mu.Unlock()

	closeNativeCandidates(routes, "native owner unavailable")
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
	if entry.owner == nil {
		h.mu.Unlock()
		return ErrNativeOwnerUnavailable
	}
	routes := nativeRoutes(entry.routes)
	owner := entry.owner.peer
	entry.active = true
	entry.descriptor = descriptor
	entry.routes = make(map[string]*nativeRoute)
	h.mu.Unlock()

	retireNativeRoutes(owner, routes, "native session replaced")
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
	var owner Peer
	if entry.owner != nil {
		owner = entry.owner.peer
	}
	entry.active = false
	entry.descriptor = ""
	entry.routes = make(map[string]*nativeRoute)
	h.mu.Unlock()

	retireNativeRoutes(owner, routes, "native sharing stopped")
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
	owner := entry.owner
	routes := nativeRoutes(entry.routes)
	h.mu.Unlock()

	if owner != nil {
		owner.peer.Close(CloseGoingAway, "native rendezvous removed")
	}
	closeNativeCandidates(routes, "native rendezvous removed")
	return nil
}

func (h *NativeRendezvousHub) OpenRoute(rendezvousID string, candidate Peer) (string, error) {
	if candidate == nil {
		return "", ErrNativeOwnerUnavailable
	}
	h.mu.Lock()
	entry, found := h.liveEntryLocked(rendezvousID, h.config.Now())
	if !found {
		h.mu.Unlock()
		return "", ErrNativeRendezvousNotFound
	}
	if entry.owner == nil {
		h.mu.Unlock()
		return "", ErrNativeOwnerUnavailable
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
		candidate:    candidate,
		lastActivity: h.config.Now(),
	}
	entry.routes[routeID] = route
	candidateOpened := protocol.Message{
		Type:    protocol.MessageNativeRouteOpened,
		Version: protocol.NativeMessageVersion,
		RouteID: routeID,
		Payload: entry.descriptor,
	}
	ownerOpened := protocol.Message{
		Type:    protocol.MessageNativeRouteOpened,
		Version: protocol.NativeMessageVersion,
		RouteID: routeID,
	}
	if err := candidate.Send(candidateOpened); err != nil {
		delete(entry.routes, routeID)
		h.mu.Unlock()
		candidate.Close(CloseGoingAway, "native candidate unavailable")
		return "", err
	}
	if err := entry.owner.peer.Send(ownerOpened); err != nil {
		delete(entry.routes, routeID)
		h.mu.Unlock()
		notifyAndClose(candidate, protocol.Message{
			Type:    protocol.MessageNativeOwnerUnavailable,
			Version: protocol.NativeMessageVersion,
		}, CloseGoingAway, "native owner unavailable")
		return "", ErrNativeOwnerUnavailable
	}
	h.mu.Unlock()
	return routeID, nil
}

func (h *NativeRendezvousHub) RelayFromOwner(rendezvousID, ownerID string, message protocol.Message) error {
	if err := protocol.ValidateNativeRelay(message, true); err != nil {
		return err
	}
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found || entry.owner == nil || entry.owner.id != ownerID {
		h.mu.Unlock()
		return ErrStaleOwner
	}
	route, found := entry.routes[message.RouteID]
	if !found {
		h.mu.Unlock()
		return ErrRouteNotFound
	}
	if message.Sequence != route.ownerSequence+1 {
		h.mu.Unlock()
		return ErrSequence
	}
	if !route.ownerBudget.allow(h.config.Now(), nativeRelayConfiguration(h.config), relayMessageBytes(message)) {
		delete(entry.routes, message.RouteID)
		h.mu.Unlock()
		notifyAndClose(route.candidate, nativeRouteClosed(message.RouteID, "signaling rate limit"), CloseGoingAway, "signaling rate limit")
		return ErrRouteBackpressure
	}
	route.ownerSequence = message.Sequence
	route.lastActivity = h.config.Now()
	if err := route.candidate.Send(message); err != nil {
		delete(entry.routes, message.RouteID)
		h.mu.Unlock()
		route.candidate.Close(CloseGoingAway, "native candidate unavailable")
		return ErrStaleCandidate
	}
	h.mu.Unlock()
	return nil
}

func (h *NativeRendezvousHub) RelayFromCandidate(rendezvousID, routeID string, candidate Peer, message protocol.Message) error {
	if err := protocol.ValidateNativeRelay(message, false); err != nil {
		return err
	}
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found || entry.owner == nil || !entry.active {
		h.mu.Unlock()
		return ErrNativeOwnerUnavailable
	}
	route, found := entry.routes[routeID]
	if !found || route.candidate != candidate {
		h.mu.Unlock()
		return ErrStaleCandidate
	}
	if message.Sequence != route.candidateSequence+1 {
		h.mu.Unlock()
		return ErrSequence
	}
	message.RouteID = routeID
	if !route.candidateBudget.allow(h.config.Now(), nativeRelayConfiguration(h.config), relayMessageBytes(message)) {
		delete(entry.routes, routeID)
		h.mu.Unlock()
		candidate.Close(CloseGoingAway, "signaling rate limit")
		return ErrRouteBackpressure
	}
	route.candidateSequence = message.Sequence
	route.lastActivity = h.config.Now()
	if err := entry.owner.peer.Send(message); err != nil {
		delete(entry.routes, routeID)
		h.mu.Unlock()
		candidate.Close(CloseGoingAway, "native owner unavailable")
		return ErrNativeOwnerUnavailable
	}
	h.mu.Unlock()
	return nil
}

func (h *NativeRendezvousHub) CloseRouteFromOwner(rendezvousID, ownerID, routeID, reason string) error {
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found || entry.owner == nil || entry.owner.id != ownerID {
		h.mu.Unlock()
		return ErrStaleOwner
	}
	route, found := entry.routes[routeID]
	if !found {
		h.mu.Unlock()
		return ErrRouteNotFound
	}
	delete(entry.routes, routeID)
	h.mu.Unlock()
	notifyAndClose(route.candidate, nativeRouteClosed(routeID, reason), CloseNormal, "native route closed")
	return nil
}

func (h *NativeRendezvousHub) CloseCandidateRoute(rendezvousID, routeID string, candidate Peer, reason string) bool {
	h.mu.Lock()
	entry, found := h.entries[rendezvousID]
	if !found {
		h.mu.Unlock()
		return false
	}
	route, found := entry.routes[routeID]
	if !found || route.candidate != candidate {
		h.mu.Unlock()
		return false
	}
	delete(entry.routes, routeID)
	var owner Peer
	if entry.owner != nil {
		owner = entry.owner.peer
	}
	h.mu.Unlock()
	if owner != nil {
		_ = owner.Send(nativeRouteClosed(routeID, reason))
	}
	candidate.Close(CloseNormal, "native route closed")
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
		owner Peer
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
			var owner Peer
			if entry.owner != nil {
				owner = entry.owner.peer
			}
			idle = append(idle, idleRoute{owner: owner, route: route})
			delete(entry.routes, routeID)
			result.IdleRoutes++
		}
	}
	h.mu.Unlock()

	for _, expired := range idle {
		if expired.owner != nil {
			_ = expired.owner.Send(nativeRouteClosed(expired.route.id, "route idle timeout"))
		}
		notifyAndClose(expired.route.candidate, nativeRouteClosed(expired.route.id, "route idle timeout"), CloseGoingAway, "route idle timeout")
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
		if entry.owner != nil {
			entry.owner.peer.Close(CloseGoingAway, boundedReason(reason))
		}
		closeNativeCandidates(nativeRoutes(entry.routes), reason)
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
	return entry.owner == nil && !entry.expiresAt.IsZero() && !now.Before(entry.expiresAt)
}

func (h *NativeRendezvousHub) purgeExpiredLocked(now time.Time) {
	for rendezvousID, entry := range h.entries {
		if h.expiredLocked(entry, now) {
			delete(h.entries, rendezvousID)
		}
	}
}

func nativeState(entry *nativeRendezvous) NativeRendezvousState {
	if entry.owner == nil {
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

func nativeRelayConfiguration(configuration NativeRendezvousConfiguration) relayConfiguration {
	return relayConfiguration{
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

func closeNativeCandidates(routes []*nativeRoute, reason string) {
	for _, route := range routes {
		notifyAndClose(route.candidate, protocol.Message{
			Type:    protocol.MessageNativeOwnerUnavailable,
			Version: protocol.NativeMessageVersion,
		}, CloseGoingAway, boundedReason(reason))
	}
}

func retireNativeRoutes(owner Peer, routes []*nativeRoute, reason string) {
	for _, route := range routes {
		if owner != nil {
			_ = owner.Send(nativeRouteClosed(route.id, reason))
		}
		notifyAndClose(route.candidate, nativeRouteClosed(route.id, reason), CloseGoingAway, boundedReason(reason))
	}
}

func sameNativeOwner(left, right [32]byte) bool {
	return subtle.ConstantTimeCompare(left[:], right[:]) == 1
}
