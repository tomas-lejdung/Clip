package signaling

import (
	"bytes"
	"encoding/base64"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

type fakePeer struct {
	mu       sync.Mutex
	messages []protocol.Message
	closed   bool
	code     int
	sendErr  error
}

func (p *fakePeer) Send(message protocol.Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.sendErr != nil {
		return p.sendErr
	}
	if p.closed {
		return ErrSocketClosed
	}
	p.messages = append(p.messages, message)
	return nil
}

func (p *fakePeer) Close(code int, _ string) {
	p.mu.Lock()
	p.closed = true
	p.code = code
	p.mu.Unlock()
}

func (p *fakePeer) snapshot() ([]protocol.Message, bool, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]protocol.Message(nil), p.messages...), p.closed, p.code
}

type hubClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *hubClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *hubClock) Advance(duration time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(duration)
	c.mu.Unlock()
}

func deterministicRandom() func([]byte) error {
	var mu sync.Mutex
	value := byte(1)
	return func(destination []byte) error {
		mu.Lock()
		defer mu.Unlock()
		for index := range destination {
			destination[index] = value
		}
		value++
		return nil
	}
}

func newNativeTestHub(clock *hubClock, maximumRendezvous, maximumRoutes int) *NativeRendezvousHub {
	return NewNativeRendezvousHub(NativeRendezvousConfiguration{
		LeaseDuration:        time.Minute,
		ReconnectGrace:       10 * time.Second,
		MaximumRendezvous:    maximumRendezvous,
		MaximumPendingRoutes: maximumRoutes,
		RouteIdleTimeout:     20 * time.Second,
		Now:                  clock.Now,
		Random:               deterministicRandom(),
	})
}

func nativeOwnerHash(value byte) [32]byte {
	var hash [32]byte
	for index := range hash {
		hash[index] = value
	}
	return hash
}

func nativeDescriptor(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 256))
}

func nativeRelay(sequence uint64, value byte) protocol.Message {
	return protocol.Message{
		Type:     protocol.MessageNativeRelay,
		Version:  protocol.NativeMessageVersion,
		Sequence: sequence,
		Payload:  base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 96)),
	}
}

func TestNativeAdvertiseRenewsOnlyForOwnerAndPurgesExpiredCapacity(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(10_000, 0)}
	hub := newNativeTestHub(clock, 1, 2)
	owner := nativeOwnerHash(1)
	created, err := hub.Advertise("native-one", owner)
	if err != nil || !created.Created || created.Lease != time.Minute {
		t.Fatalf("first Advertise() = %#v, %v", created, err)
	}
	clock.Advance(20 * time.Second)
	renewed, err := hub.Advertise("native-one", owner)
	if err != nil || renewed.Created {
		t.Fatalf("renewed Advertise() = %#v, %v", renewed, err)
	}
	if _, err := hub.Advertise("native-one", nativeOwnerHash(2)); !errors.Is(err, ErrNativeRendezvousConflict) {
		t.Fatalf("conflicting Advertise() = %v", err)
	}
	clock.Advance(time.Minute)
	reused, err := hub.Advertise("native-two", nativeOwnerHash(2))
	if err != nil || !reused.Created {
		t.Fatalf("Advertise() after expiry = %#v, %v", reused, err)
	}
	if _, found := hub.Snapshot("native-one"); found {
		t.Fatal("expired rendezvous remained in the hub")
	}
}

func TestNativeCandidateCannotRequestAdmissionUntilOwnerActivates(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(20_000, 0)}
	hub := newNativeTestHub(clock, 4, 2)
	owner := nativeOwnerHash(3)
	_, _ = hub.Advertise("native-gated", owner)

	snapshot, found := hub.Snapshot("native-gated")
	if !found || snapshot.State != NativeRendezvousOffline {
		t.Fatalf("offline snapshot = %#v, %v", snapshot, found)
	}
	if _, err := hub.OpenRoute("native-gated", &fakePeer{}); !errors.Is(err, ErrNativeOwnerUnavailable) {
		t.Fatalf("offline OpenRoute() = %v", err)
	}

	ownerPeer := &fakePeer{}
	if err := hub.AttachOwner("native-gated", owner, "owner-1", ownerPeer); err != nil {
		t.Fatal(err)
	}
	snapshot, _ = hub.Snapshot("native-gated")
	if snapshot.State != NativeRendezvousPreparing {
		t.Fatalf("preparing snapshot = %#v", snapshot)
	}
	if _, err := hub.OpenRoute("native-gated", &fakePeer{}); !errors.Is(err, ErrNativeNotLive) {
		t.Fatalf("preparing OpenRoute() = %v", err)
	}

	descriptor := nativeDescriptor(4)
	if err := hub.Activate("native-gated", owner, descriptor); err != nil {
		t.Fatal(err)
	}
	snapshot, _ = hub.Snapshot("native-gated")
	if snapshot.State != NativeRendezvousActive {
		t.Fatalf("active snapshot = %#v", snapshot)
	}
	candidate := &fakePeer{}
	routeID, err := hub.OpenRoute("native-gated", candidate)
	if err != nil {
		t.Fatal(err)
	}
	ownerMessages, _, _ := ownerPeer.snapshot()
	candidateMessages, _, _ := candidate.snapshot()
	if len(ownerMessages) != 1 || ownerMessages[0].RouteID != routeID || ownerMessages[0].Payload != "" {
		t.Fatalf("owner route-opened = %#v", ownerMessages)
	}
	if len(candidateMessages) != 1 || candidateMessages[0].RouteID != routeID || candidateMessages[0].Payload != descriptor {
		t.Fatalf("candidate route-opened = %#v", candidateMessages)
	}

	if err := hub.Deactivate("native-gated", owner); err != nil {
		t.Fatal(err)
	}
	if hub.PendingRouteCount("native-gated") != 0 {
		t.Fatal("deactivate left a pending route")
	}
	_, candidateClosed, _ := candidate.snapshot()
	if !candidateClosed {
		t.Fatal("deactivate did not close the pending candidate")
	}
	if _, err := hub.OpenRoute("native-gated", &fakePeer{}); !errors.Is(err, ErrNativeNotLive) {
		t.Fatalf("deactivated OpenRoute() = %v", err)
	}
}

func TestNativeRoutesAreBoundedAndRelayPayloadsStayOpaque(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(30_000, 0)}
	hub := newNativeTestHub(clock, 4, 2)
	owner := nativeOwnerHash(5)
	_, _ = hub.Advertise("native-routes", owner)
	ownerPeer := &fakePeer{}
	_ = hub.AttachOwner("native-routes", owner, "owner", ownerPeer)
	_ = hub.Activate("native-routes", owner, nativeDescriptor(6))
	candidateOne := &fakePeer{}
	candidateTwo := &fakePeer{}
	routeOne, err := hub.OpenRoute("native-routes", candidateOne)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := hub.OpenRoute("native-routes", candidateTwo); err != nil {
		t.Fatal(err)
	}
	if _, err := hub.OpenRoute("native-routes", &fakePeer{}); !errors.Is(err, ErrRouteLimit) {
		t.Fatalf("third OpenRoute() = %v", err)
	}

	candidatePayload := nativeRelay(1, 7)
	if err := hub.RelayFromCandidate("native-routes", routeOne, candidateOne, candidatePayload); err != nil {
		t.Fatal(err)
	}
	ownerPayload := nativeRelay(1, 8)
	ownerPayload.RouteID = routeOne
	if err := hub.RelayFromOwner("native-routes", "owner", ownerPayload); err != nil {
		t.Fatal(err)
	}
	ownerMessages, _, _ := ownerPeer.snapshot()
	candidateMessages, _, _ := candidateOne.snapshot()
	forwardedToOwner := ownerMessages[len(ownerMessages)-1]
	forwardedToCandidate := candidateMessages[len(candidateMessages)-1]
	if forwardedToOwner.Payload != candidatePayload.Payload || forwardedToOwner.RouteID != routeOne {
		t.Fatalf("candidate payload was changed: %#v", forwardedToOwner)
	}
	if forwardedToCandidate != ownerPayload {
		t.Fatalf("owner payload was changed: %#v", forwardedToCandidate)
	}
	if err := hub.RelayFromCandidate("native-routes", routeOne, candidateOne, nativeRelay(1, 9)); !errors.Is(err, ErrSequence) {
		t.Fatalf("duplicate sequence = %v", err)
	}
}

func TestNativeReconnectGraceAndProcessRestart(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(40_000, 0)}
	hub := newNativeTestHub(clock, 4, 2)
	owner := nativeOwnerHash(10)
	_, _ = hub.Advertise("native-reconnect", owner)
	firstOwner := &fakePeer{}
	_ = hub.AttachOwner("native-reconnect", owner, "owner-1", firstOwner)
	_ = hub.Activate("native-reconnect", owner, nativeDescriptor(11))
	candidate := &fakePeer{}
	_, _ = hub.OpenRoute("native-reconnect", candidate)
	if !hub.DetachOwner("native-reconnect", "owner-1") {
		t.Fatal("current owner did not detach")
	}
	if snapshot, found := hub.Snapshot("native-reconnect"); !found || snapshot.State != NativeRendezvousOffline {
		t.Fatalf("grace snapshot = %#v, %v", snapshot, found)
	}
	secondOwner := &fakePeer{}
	clock.Advance(9 * time.Second)
	if err := hub.AttachOwner("native-reconnect", owner, "owner-2", secondOwner); err != nil {
		t.Fatalf("reconnect during grace = %v", err)
	}
	if hub.DetachOwner("native-reconnect", "owner-1") {
		t.Fatal("stale owner detached the replacement")
	}
	if !hub.DetachOwner("native-reconnect", "owner-2") {
		t.Fatal("replacement owner did not detach")
	}
	clock.Advance(10 * time.Second)
	if cleanup := hub.Cleanup(); cleanup.ExpiredRendezvous != 1 {
		t.Fatalf("cleanup after grace = %#v", cleanup)
	}

	// Process state is deliberately memory-only. After restart the app can
	// reclaim its persisted opaque ID, while identity signatures let
	// participants reject an impostor descriptor independently of this
	// service.
	restarted := newNativeTestHub(clock, 4, 2)
	created, err := restarted.Advertise("native-reconnect", owner)
	if err != nil || !created.Created {
		t.Fatalf("re-advertise after restart = %#v, %v", created, err)
	}
}

func TestNativeRemoveAtomicallyStopsRoutesAndOwner(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(50_000, 0)}
	hub := newNativeTestHub(clock, 4, 2)
	owner := nativeOwnerHash(12)
	_, _ = hub.Advertise("native-remove", owner)
	ownerPeer := &fakePeer{}
	_ = hub.AttachOwner("native-remove", owner, "owner", ownerPeer)
	_ = hub.Activate("native-remove", owner, nativeDescriptor(13))
	candidate := &fakePeer{}
	_, _ = hub.OpenRoute("native-remove", candidate)
	if err := hub.Remove("native-remove", owner); err != nil {
		t.Fatal(err)
	}
	if _, found := hub.Snapshot("native-remove"); found || hub.PendingRouteCount("native-remove") != 0 {
		t.Fatal("removed rendezvous remained visible")
	}
	_, ownerClosed, _ := ownerPeer.snapshot()
	_, candidateClosed, _ := candidate.snapshot()
	if !ownerClosed || !candidateClosed {
		t.Fatalf("remove closed owner/candidate = %v/%v", ownerClosed, candidateClosed)
	}
	if _, err := hub.OpenRoute("native-remove", &fakePeer{}); !errors.Is(err, ErrNativeRendezvousNotFound) {
		t.Fatalf("OpenRoute after remove = %v", err)
	}
}

func TestNativeCleanupRetiresIdleRoutes(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(60_000, 0)}
	hub := newNativeTestHub(clock, 4, 2)
	owner := nativeOwnerHash(14)
	_, _ = hub.Advertise("native-idle", owner)
	ownerPeer := &fakePeer{}
	_ = hub.AttachOwner("native-idle", owner, "owner", ownerPeer)
	_ = hub.Activate("native-idle", owner, nativeDescriptor(15))
	candidate := &fakePeer{}
	_, _ = hub.OpenRoute("native-idle", candidate)
	clock.Advance(20 * time.Second)
	if result := hub.Cleanup(); result.IdleRoutes != 1 {
		t.Fatalf("Cleanup() = %#v", result)
	}
	_, closed, _ := candidate.snapshot()
	if !closed || hub.PendingRouteCount("native-idle") != 0 {
		t.Fatal("idle route was not retired")
	}
}
