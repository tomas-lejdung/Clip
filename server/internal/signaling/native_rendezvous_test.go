package signaling

import (
	"bytes"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

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
		t.Fatal("expired rendezvous remained in the registry")
	}
}

func TestNativeViewerCannotRequestAdmissionUntilHostActivates(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(20_000, 0)}
	hub := newNativeTestHub(clock, 4, 2)
	owner := nativeOwnerHash(3)
	_, _ = hub.Advertise("native-gated", owner)

	snapshot, found := hub.Snapshot("native-gated")
	if !found || snapshot.State != NativeRendezvousOffline {
		t.Fatalf("offline snapshot = %#v, %v", snapshot, found)
	}
	if _, err := hub.OpenRoute("native-gated", &fakePeer{}); !errors.Is(err, ErrNativeHostUnavailable) {
		t.Fatalf("offline OpenRoute() = %v", err)
	}

	host := &fakePeer{}
	if err := hub.AttachHost("native-gated", owner, "host-1", host); err != nil {
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
	viewer := &fakePeer{}
	routeID, err := hub.OpenRoute("native-gated", viewer)
	if err != nil {
		t.Fatal(err)
	}
	hostMessages, _, _ := host.snapshot()
	viewerMessages, _, _ := viewer.snapshot()
	if len(hostMessages) != 1 || hostMessages[0].RouteID != routeID || hostMessages[0].Payload != "" {
		t.Fatalf("host route-opened = %#v", hostMessages)
	}
	if len(viewerMessages) != 1 || viewerMessages[0].RouteID != routeID || viewerMessages[0].Payload != descriptor {
		t.Fatalf("viewer route-opened = %#v", viewerMessages)
	}

	if err := hub.Deactivate("native-gated", owner); err != nil {
		t.Fatal(err)
	}
	if hub.PendingRouteCount("native-gated") != 0 {
		t.Fatal("deactivate left a pending route")
	}
	_, viewerClosed, _ := viewer.snapshot()
	if !viewerClosed {
		t.Fatal("deactivate did not close the pending viewer")
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
	host := &fakePeer{}
	_ = hub.AttachHost("native-routes", owner, "host", host)
	_ = hub.Activate("native-routes", owner, nativeDescriptor(6))
	viewerOne := &fakePeer{}
	viewerTwo := &fakePeer{}
	routeOne, err := hub.OpenRoute("native-routes", viewerOne)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := hub.OpenRoute("native-routes", viewerTwo); err != nil {
		t.Fatal(err)
	}
	if _, err := hub.OpenRoute("native-routes", &fakePeer{}); !errors.Is(err, ErrRouteLimit) {
		t.Fatalf("third OpenRoute() = %v", err)
	}

	viewerPayload := nativeRelay(1, 7)
	if err := hub.RelayFromViewer("native-routes", routeOne, viewerOne, viewerPayload); err != nil {
		t.Fatal(err)
	}
	hostPayload := nativeRelay(1, 8)
	hostPayload.RouteID = routeOne
	if err := hub.RelayFromHost("native-routes", "host", hostPayload); err != nil {
		t.Fatal(err)
	}
	hostMessages, _, _ := host.snapshot()
	viewerMessages, _, _ := viewerOne.snapshot()
	forwardedToHost := hostMessages[len(hostMessages)-1]
	forwardedToViewer := viewerMessages[len(viewerMessages)-1]
	if forwardedToHost.Payload != viewerPayload.Payload || forwardedToHost.RouteID != routeOne {
		t.Fatalf("viewer payload was changed: %#v", forwardedToHost)
	}
	if forwardedToViewer != hostPayload {
		t.Fatalf("host payload was changed: %#v", forwardedToViewer)
	}
	if err := hub.RelayFromViewer("native-routes", routeOne, viewerOne, nativeRelay(1, 9)); !errors.Is(err, ErrSequence) {
		t.Fatalf("duplicate sequence = %v", err)
	}
}

func TestNativeReconnectGraceAndProcessRestart(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(40_000, 0)}
	hub := newNativeTestHub(clock, 4, 2)
	owner := nativeOwnerHash(10)
	_, _ = hub.Advertise("native-reconnect", owner)
	firstHost := &fakePeer{}
	_ = hub.AttachHost("native-reconnect", owner, "host-1", firstHost)
	_ = hub.Activate("native-reconnect", owner, nativeDescriptor(11))
	viewer := &fakePeer{}
	_, _ = hub.OpenRoute("native-reconnect", viewer)
	if !hub.DetachHost("native-reconnect", "host-1") {
		t.Fatal("current host did not detach")
	}
	if snapshot, found := hub.Snapshot("native-reconnect"); !found || snapshot.State != NativeRendezvousOffline {
		t.Fatalf("grace snapshot = %#v, %v", snapshot, found)
	}
	secondHost := &fakePeer{}
	clock.Advance(9 * time.Second)
	if err := hub.AttachHost("native-reconnect", owner, "host-2", secondHost); err != nil {
		t.Fatalf("reconnect during grace = %v", err)
	}
	if hub.DetachHost("native-reconnect", "host-1") {
		t.Fatal("stale host detached the replacement")
	}
	if !hub.DetachHost("native-reconnect", "host-2") {
		t.Fatal("replacement host did not detach")
	}
	clock.Advance(10 * time.Second)
	if cleanup := hub.Cleanup(); cleanup.ExpiredRendezvous != 1 {
		t.Fatalf("cleanup after grace = %#v", cleanup)
	}

	// Process state is deliberately memory-only. After restart the app can
	// reclaim its persisted opaque ID, while identity signatures let friends
	// reject an impostor descriptor independently of this service.
	restarted := newNativeTestHub(clock, 4, 2)
	created, err := restarted.Advertise("native-reconnect", owner)
	if err != nil || !created.Created {
		t.Fatalf("re-advertise after restart = %#v, %v", created, err)
	}
}

func TestNativeRemoveAtomicallyStopsRoutesAndHost(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(50_000, 0)}
	hub := newNativeTestHub(clock, 4, 2)
	owner := nativeOwnerHash(12)
	_, _ = hub.Advertise("native-remove", owner)
	host := &fakePeer{}
	_ = hub.AttachHost("native-remove", owner, "host", host)
	_ = hub.Activate("native-remove", owner, nativeDescriptor(13))
	viewer := &fakePeer{}
	_, _ = hub.OpenRoute("native-remove", viewer)
	if err := hub.Remove("native-remove", owner); err != nil {
		t.Fatal(err)
	}
	if _, found := hub.Snapshot("native-remove"); found || hub.PendingRouteCount("native-remove") != 0 {
		t.Fatal("removed rendezvous remained visible")
	}
	_, hostClosed, _ := host.snapshot()
	_, viewerClosed, _ := viewer.snapshot()
	if !hostClosed || !viewerClosed {
		t.Fatalf("remove closed host/viewer = %v/%v", hostClosed, viewerClosed)
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
	host := &fakePeer{}
	_ = hub.AttachHost("native-idle", owner, "host", host)
	_ = hub.Activate("native-idle", owner, nativeDescriptor(15))
	viewer := &fakePeer{}
	_, _ = hub.OpenRoute("native-idle", viewer)
	clock.Advance(20 * time.Second)
	if result := hub.Cleanup(); result.IdleRoutes != 1 {
		t.Fatalf("Cleanup() = %#v", result)
	}
	_, closed, _ := viewer.snapshot()
	if !closed || hub.PendingRouteCount("native-idle") != 0 {
		t.Fatal("idle route was not retired")
	}
}
