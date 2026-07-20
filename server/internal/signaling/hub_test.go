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
	reason   string
	failSend bool
	sendErr  error
}

func (p *fakePeer) Send(message protocol.Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.sendErr != nil {
		return p.sendErr
	}
	if p.closed || p.failSend {
		return ErrSocketClosed
	}
	p.messages = append(p.messages, message)
	return nil
}

type routeBoundedPeer struct {
	mu              sync.Mutex
	messages        []protocol.Message
	queuedByRoute   map[string]int
	maximumMessages int
	maximumPerRoute int
	closed          bool
}

func (p *routeBoundedPeer) Send(message protocol.Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return ErrSocketClosed
	}
	if len(p.messages) >= p.maximumMessages {
		return ErrOutboundQueueFull
	}
	limitedRoute := message.Type == protocol.MessageRelay && message.RouteID != ""
	if limitedRoute && p.queuedByRoute[message.RouteID] >= p.maximumPerRoute {
		return ErrRouteQueueFull
	}
	p.messages = append(p.messages, message)
	if limitedRoute {
		p.queuedByRoute[message.RouteID]++
	}
	return nil
}

func (p *routeBoundedPeer) Close(_ int, _ string) {
	p.mu.Lock()
	p.closed = true
	p.mu.Unlock()
}

func (p *routeBoundedPeer) drain() []protocol.Message {
	p.mu.Lock()
	defer p.mu.Unlock()
	messages := append([]protocol.Message(nil), p.messages...)
	p.messages = nil
	p.queuedByRoute = make(map[string]int)
	return messages
}

func (p *routeBoundedPeer) isClosed() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.closed
}

func (p *fakePeer) Close(code int, reason string) {
	p.mu.Lock()
	p.closed = true
	p.code = code
	p.reason = reason
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

func newTestHub(clock *hubClock, maximum int) *Hub {
	return NewHub(Configuration{
		MaximumPendingRoutes: maximum,
		RouteIdleTimeout:     time.Minute,
		Now:                  clock.Now,
		Random:               deterministicRandom(),
	})
}

func newLimitedTestHub(clock *hubClock, maximumMessages, maximumBytes int) *Hub {
	return NewHub(Configuration{
		MaximumPendingRoutes:         8,
		RouteIdleTimeout:             time.Minute,
		RelayBurstWindow:             time.Second,
		MaximumRelayMessagesPerBurst: maximumMessages,
		MaximumRelayBytesPerBurst:    maximumBytes,
		Now:                          clock.Now,
		Random:                       deterministicRandom(),
	})
}

func relay(sequence uint64) protocol.Message {
	return protocol.Message{
		Type:       protocol.MessageRelay,
		Sequence:   sequence,
		Nonce:      base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, protocol.AESGCMNonceBytes)),
		Ciphertext: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, protocol.AESGCMTagBytes)),
	}
}

func TestOpenRouteSendsSharedIdentifierAndKeepsViewerKeyHostOnly(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(1_000, 0)}
	hub := newTestHub(clock, 8)
	host := &fakePeer{}
	viewer := &fakePeer{}
	hub.RegisterHost("ROOM", "host-1", host)
	routeID, err := hub.OpenRoute("ROOM", "viewer-public-key", viewer)
	if err != nil {
		t.Fatal(err)
	}
	if err := protocol.ValidateRouteID(routeID); err != nil {
		t.Fatalf("route identifier = %q: %v", routeID, err)
	}
	hostMessages, _, _ := host.snapshot()
	viewerMessages, _, _ := viewer.snapshot()
	if len(hostMessages) != 1 || len(viewerMessages) != 1 {
		t.Fatalf("opened messages = host:%v viewer:%v", hostMessages, viewerMessages)
	}
	if hostMessages[0].RouteID != routeID || hostMessages[0].ViewerKey != "viewer-public-key" {
		t.Fatalf("host route-opened = %#v", hostMessages[0])
	}
	if viewerMessages[0].RouteID != routeID || viewerMessages[0].ViewerKey != "" {
		t.Fatalf("viewer route-opened = %#v", viewerMessages[0])
	}
}

func TestOpaqueRelaysAreRoutedAndSequencedPerDirection(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(2_000, 0)}
	hub := newTestHub(clock, 8)
	host := &fakePeer{}
	viewer := &fakePeer{}
	hub.RegisterHost("ROOM", "host-1", host)
	routeID, _ := hub.OpenRoute("ROOM", "key", viewer)

	viewerRelay := relay(1)
	if err := hub.RelayFromViewer("ROOM", routeID, viewer, viewerRelay); err != nil {
		t.Fatalf("RelayFromViewer() = %v", err)
	}
	hostRelay := relay(1)
	hostRelay.RouteID = routeID
	if err := hub.RelayFromHost("ROOM", "host-1", hostRelay); err != nil {
		t.Fatalf("RelayFromHost() = %v", err)
	}

	hostMessages, _, _ := host.snapshot()
	viewerMessages, _, _ := viewer.snapshot()
	if len(hostMessages) != 2 || hostMessages[1].RouteID != routeID || hostMessages[1].Ciphertext != viewerRelay.Ciphertext {
		t.Fatalf("host relay = %#v", hostMessages)
	}
	if len(viewerMessages) != 2 || viewerMessages[1] != hostRelay {
		t.Fatalf("viewer relay = %#v", viewerMessages)
	}

	if err := hub.RelayFromViewer("ROOM", routeID, viewer, relay(1)); !errors.Is(err, ErrSequence) {
		t.Fatalf("duplicate viewer sequence = %v", err)
	}
	skipped := relay(3)
	skipped.RouteID = routeID
	if err := hub.RelayFromHost("ROOM", "host-1", skipped); !errors.Is(err, ErrSequence) {
		t.Fatalf("skipped host sequence = %v", err)
	}
}

func TestRouteLimitCountsOnlyPendingRoutes(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(3_000, 0)}
	hub := newTestHub(clock, 2)
	host := &fakePeer{}
	hub.RegisterHost("ROOM", "host", host)
	viewerOne := &fakePeer{}
	viewerTwo := &fakePeer{}
	viewerThree := &fakePeer{}
	routeOne, _ := hub.OpenRoute("ROOM", "key-1", viewerOne)
	_, _ = hub.OpenRoute("ROOM", "key-2", viewerTwo)
	if _, err := hub.OpenRoute("ROOM", "key-3", viewerThree); !errors.Is(err, ErrRouteLimit) {
		t.Fatalf("third OpenRoute() = %v", err)
	}
	if !hub.CloseViewerRoute("ROOM", routeOne, viewerOne, "complete") {
		t.Fatal("first route did not close")
	}
	if _, err := hub.OpenRoute("ROOM", "key-3", viewerThree); err != nil {
		t.Fatalf("OpenRoute() after close = %v", err)
	}
}

func TestHostReplacementInvalidatesOldRoutesAndStaleGeneration(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(4_000, 0)}
	hub := newTestHub(clock, 8)
	oldHost := &fakePeer{}
	viewer := &fakePeer{}
	hub.RegisterHost("ROOM", "host-1", oldHost)
	routeID, _ := hub.OpenRoute("ROOM", "key", viewer)
	newHost := &fakePeer{}
	hub.RegisterHost("ROOM", "host-2", newHost)

	_, oldClosed, oldCode := oldHost.snapshot()
	viewerMessages, viewerClosed, _ := viewer.snapshot()
	if !oldClosed || oldCode != CloseGoingAway {
		t.Fatalf("old host close = %v, %d", oldClosed, oldCode)
	}
	if !viewerClosed || viewerMessages[len(viewerMessages)-1].Type != protocol.MessageHostUnavailable {
		t.Fatalf("viewer replacement state = %#v, %v", viewerMessages, viewerClosed)
	}
	message := relay(1)
	message.RouteID = routeID
	if err := hub.RelayFromHost("ROOM", "host-1", message); !errors.Is(err, ErrStaleHost) {
		t.Fatalf("stale host relay = %v", err)
	}
}

func TestViewerCloseNotifiesHostWithoutTrackingLiveViewer(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(5_000, 0)}
	hub := newTestHub(clock, 8)
	host := &fakePeer{}
	viewer := &fakePeer{}
	hub.RegisterHost("ROOM", "host", host)
	routeID, _ := hub.OpenRoute("ROOM", "key", viewer)
	if !hub.CloseViewerRoute("ROOM", routeID, viewer, "control channel open") {
		t.Fatal("CloseViewerRoute() = false")
	}
	hostMessages, _, _ := host.snapshot()
	last := hostMessages[len(hostMessages)-1]
	if last.Type != protocol.MessageRouteClosed || last.RouteID != routeID {
		t.Fatalf("host close notification = %#v", last)
	}
	if hub.PendingRouteCount("ROOM") != 0 {
		t.Fatal("completed route remained pending")
	}
}

func TestIdleRouteCleanupIsBounded(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(6_000, 0)}
	hub := newTestHub(clock, 8)
	host := &fakePeer{}
	viewer := &fakePeer{}
	hub.RegisterHost("ROOM", "host", host)
	_, _ = hub.OpenRoute("ROOM", "key", viewer)
	clock.Advance(time.Minute)
	if removed := hub.CleanupIdleRoutes(); removed != 1 {
		t.Fatalf("CleanupIdleRoutes() = %d", removed)
	}
	_, viewerClosed, _ := viewer.snapshot()
	if !viewerClosed {
		t.Fatal("idle viewer was not closed")
	}
}

func TestFloodingViewerBackpressureDoesNotCloseHostOrBlockAnotherRoute(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(7_000, 0)}
	hub := newTestHub(clock, 8)
	host := &routeBoundedPeer{
		queuedByRoute:   make(map[string]int),
		maximumMessages: 8,
		maximumPerRoute: 2,
	}
	hub.RegisterHost("ROOM", "host", host)
	floodingViewer := &fakePeer{}
	healthyViewer := &fakePeer{}
	floodingRoute, err := hub.OpenRoute("ROOM", "flood-key", floodingViewer)
	if err != nil {
		t.Fatal(err)
	}
	healthyRoute, err := hub.OpenRoute("ROOM", "healthy-key", healthyViewer)
	if err != nil {
		t.Fatal(err)
	}
	host.drain()

	for sequence := uint64(1); sequence <= 2; sequence++ {
		if err := hub.RelayFromViewer("ROOM", floodingRoute, floodingViewer, relay(sequence)); err != nil {
			t.Fatalf("flood relay %d = %v", sequence, err)
		}
	}
	if err := hub.RelayFromViewer("ROOM", floodingRoute, floodingViewer, relay(3)); !errors.Is(err, ErrRouteBackpressure) {
		t.Fatalf("overflow relay = %v", err)
	}
	if host.isClosed() {
		t.Fatal("viewer backpressure closed the shared host")
	}
	_, floodingClosed, _ := floodingViewer.snapshot()
	if !floodingClosed {
		t.Fatal("flooding viewer route remained open")
	}

	if err := hub.RelayFromViewer("ROOM", healthyRoute, healthyViewer, relay(1)); err != nil {
		t.Fatalf("healthy route relay = %v", err)
	}
	forwarded := host.drain()
	foundHealthyRelay := false
	for _, message := range forwarded {
		if message.Type == protocol.MessageRelay && message.RouteID == healthyRoute {
			foundHealthyRelay = true
		}
	}
	if !foundHealthyRelay {
		t.Fatalf("healthy route was not forwarded: %#v", forwarded)
	}
}

func TestRelayBurstMessageLimitClosesOnlyOffendingRoute(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(8_000, 0)}
	hub := newLimitedTestHub(clock, 2, protocol.MaximumMessageBytes*2)
	host := &fakePeer{}
	viewer := &fakePeer{}
	hub.RegisterHost("ROOM", "host", host)
	routeID, _ := hub.OpenRoute("ROOM", "key", viewer)
	if err := hub.RelayFromViewer("ROOM", routeID, viewer, relay(1)); err != nil {
		t.Fatal(err)
	}
	if err := hub.RelayFromViewer("ROOM", routeID, viewer, relay(2)); err != nil {
		t.Fatal(err)
	}
	if err := hub.RelayFromViewer("ROOM", routeID, viewer, relay(3)); !errors.Is(err, ErrRouteBackpressure) {
		t.Fatalf("third relay = %v", err)
	}
	_, hostClosed, _ := host.snapshot()
	_, viewerClosed, _ := viewer.snapshot()
	if hostClosed || !viewerClosed || hub.PendingRouteCount("ROOM") != 0 {
		t.Fatalf("closed state = host:%v viewer:%v pending:%d", hostClosed, viewerClosed, hub.PendingRouteCount("ROOM"))
	}
}

func TestRelayBurstByteLimitClosesOnlyOffendingRoute(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(9_000, 0)}
	hub := newLimitedTestHub(clock, 8, protocol.MaximumMessageBytes)
	host := &fakePeer{}
	viewer := &fakePeer{}
	hub.RegisterHost("ROOM", "host", host)
	routeID, _ := hub.OpenRoute("ROOM", "key", viewer)
	first := relay(1)
	first.RouteID = routeID
	hub.config.MaximumRelayBytesPerBurst = relayMessageBytes(first)
	first.RouteID = ""
	if err := hub.RelayFromViewer("ROOM", routeID, viewer, first); err != nil {
		t.Fatal(err)
	}
	if err := hub.RelayFromViewer("ROOM", routeID, viewer, relay(2)); !errors.Is(err, ErrRouteBackpressure) {
		t.Fatalf("second relay = %v", err)
	}
	_, hostClosed, _ := host.snapshot()
	_, viewerClosed, _ := viewer.snapshot()
	if hostClosed || !viewerClosed {
		t.Fatalf("closed state = host:%v viewer:%v", hostClosed, viewerClosed)
	}
}

func TestHostToViewerOverflowClosesOnlyViewer(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(10_000, 0)}
	hub := newTestHub(clock, 8)
	host := &fakePeer{}
	overloadedViewer := &fakePeer{}
	hub.RegisterHost("ROOM", "host", host)
	overloadedRoute, _ := hub.OpenRoute("ROOM", "key-1", overloadedViewer)
	overloadedViewer.mu.Lock()
	overloadedViewer.sendErr = ErrOutboundQueueFull
	overloadedViewer.mu.Unlock()
	message := relay(1)
	message.RouteID = overloadedRoute
	if err := hub.RelayFromHost("ROOM", "host", message); !errors.Is(err, ErrStaleViewer) {
		t.Fatalf("overflow relay = %v", err)
	}
	_, hostClosed, _ := host.snapshot()
	_, viewerClosed, _ := overloadedViewer.snapshot()
	if hostClosed || !viewerClosed {
		t.Fatalf("closed state = host:%v viewer:%v", hostClosed, viewerClosed)
	}

	healthyViewer := &fakePeer{}
	healthyRoute, err := hub.OpenRoute("ROOM", "key-2", healthyViewer)
	if err != nil {
		t.Fatal(err)
	}
	healthyRelay := relay(1)
	healthyRelay.RouteID = healthyRoute
	if err := hub.RelayFromHost("ROOM", "host", healthyRelay); err != nil {
		t.Fatalf("healthy relay = %v", err)
	}
}

func TestStaleRegistryGenerationCannotReplaceNewerHost(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(11_000, 0)}
	hub := newTestHub(clock, 8)
	newer := &fakePeer{}
	if !hub.RegisterHostGeneration("ROOM", 10, 22, "host-new", newer) {
		t.Fatal("new host generation was rejected")
	}
	stale := &fakePeer{}
	if hub.RegisterHostGeneration("ROOM", 10, 21, "host-stale", stale) {
		t.Fatal("stale host generation replaced the newer host")
	}
	if hub.UnregisterHost("ROOM", "host-stale") {
		t.Fatal("stale host was installed")
	}
	_, newerClosed, _ := newer.snapshot()
	_, staleClosed, _ := stale.snapshot()
	if newerClosed || staleClosed {
		t.Fatalf("rejected generation changed peers: newer=%v stale=%v", newerClosed, staleClosed)
	}
}

func TestOldRoomGenerationCannotCloseReusedRoom(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(12_000, 0)}
	hub := newTestHub(clock, 8)
	oldHost := &fakePeer{}
	if !hub.RegisterHostGeneration("ROOM", 30, 31, "host-old", oldHost) {
		t.Fatal("old room generation was rejected")
	}
	newHost := &fakePeer{}
	if !hub.RegisterHostGeneration("ROOM", 40, 41, "host-new", newHost) {
		t.Fatal("new room generation was rejected")
	}
	if hub.CloseRoomGeneration("ROOM", 30, "old lease cleanup") {
		t.Fatal("old room generation closed a reused room")
	}
	if !hub.HasHostGeneration("ROOM", 40) {
		t.Fatal("new room host was removed")
	}
	_, newClosed, _ := newHost.snapshot()
	if newClosed {
		t.Fatal("new room host socket was closed")
	}
}
