package signaling

import (
	"encoding/json"
	"errors"
	"testing"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

func newUnstartedTestSocket(queueDepth, maximumPerRoute, maximumBytesPerRoute int) *Socket {
	return &Socket{
		config: SocketConfiguration{
			QueueDepth:                    queueDepth,
			MaximumQueuedBytes:            protocol.MaximumMessageBytes * queueDepth,
			MaximumQueuedMessagesPerRoute: maximumPerRoute,
			MaximumQueuedBytesPerRoute:    maximumBytesPerRoute,
		},
		outbound:   make(chan outboundFrame, queueDepth),
		done:       make(chan struct{}),
		writeDone:  make(chan struct{}),
		routeUsage: make(map[string]routeQueueUsage),
	}
}

func TestSendQueueFullReportsBackpressureWithoutClosingSocket(t *testing.T) {
	t.Parallel()
	socket := newUnstartedTestSocket(1, 1, protocol.MaximumMessageBytes)
	if err := socket.Send(protocol.Message{Type: protocol.MessageHostUnavailable}); err != nil {
		t.Fatal(err)
	}
	if err := socket.Send(protocol.Message{Type: protocol.MessageHostUnavailable}); !errors.Is(err, ErrOutboundQueueFull) {
		t.Fatalf("second Send() = %v", err)
	}
	if socket.closing {
		t.Fatal("queue backpressure marked the socket as closing")
	}
	select {
	case <-socket.Done():
		t.Fatal("queue backpressure closed the socket")
	default:
	}

	<-socket.outbound
	if err := socket.Send(protocol.Message{Type: protocol.MessageHostUnavailable}); err != nil {
		t.Fatalf("Send() after queue capacity returned = %v", err)
	}
}

func TestPerRouteQueueLimitReservesCapacityForOtherRoutes(t *testing.T) {
	t.Parallel()
	socket := newUnstartedTestSocket(4, 2, protocol.MaximumMessageBytes)
	firstRoute := protocol.Message{Type: protocol.MessageRelay, RouteID: "first-route"}
	secondRoute := protocol.Message{Type: protocol.MessageRelay, RouteID: "second-route"}
	if err := socket.Send(firstRoute); err != nil {
		t.Fatal(err)
	}
	if err := socket.Send(firstRoute); err != nil {
		t.Fatal(err)
	}
	if err := socket.Send(firstRoute); !errors.Is(err, ErrRouteQueueFull) {
		t.Fatalf("third first-route Send() = %v", err)
	}
	if err := socket.Send(secondRoute); err != nil {
		t.Fatalf("second route could not use reserved capacity: %v", err)
	}
	if socket.closing {
		t.Fatal("per-route backpressure closed the shared socket")
	}
}

func TestNativeRelayUsesPerRouteQueueLimit(t *testing.T) {
	t.Parallel()
	socket := newUnstartedTestSocket(4, 1, protocol.MaximumMessageBytes)
	firstRoute := protocol.Message{Type: protocol.MessageNativeRelay, RouteID: "first-native-route"}
	secondRoute := protocol.Message{Type: protocol.MessageNativeRelay, RouteID: "second-native-route"}
	if err := socket.Send(firstRoute); err != nil {
		t.Fatal(err)
	}
	if err := socket.Send(firstRoute); !errors.Is(err, ErrRouteQueueFull) {
		t.Fatalf("second first-route native Send() = %v", err)
	}
	if err := socket.Send(secondRoute); err != nil {
		t.Fatalf("second native route could not use reserved capacity: %v", err)
	}
}

func TestPerRouteQueuedByteLimitIsEnforced(t *testing.T) {
	t.Parallel()
	message := protocol.Message{Type: protocol.MessageRelay, RouteID: "byte-route"}
	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	socket := newUnstartedTestSocket(4, 4, len(encoded))
	if err := socket.Send(message); err != nil {
		t.Fatal(err)
	}
	if err := socket.Send(message); !errors.Is(err, ErrRouteQueueFull) {
		t.Fatalf("byte overflow Send() = %v", err)
	}
	if socket.closing {
		t.Fatal("per-route byte backpressure closed the shared socket")
	}
}

func TestPerSocketQueuedByteLimitIsEnforced(t *testing.T) {
	t.Parallel()
	message := protocol.Message{Type: protocol.MessageHostUnavailable}
	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	socket := newUnstartedTestSocket(4, 4, protocol.MaximumMessageBytes)
	socket.config.MaximumQueuedBytes = len(encoded)
	if err := socket.Send(message); err != nil {
		t.Fatal(err)
	}
	if err := socket.Send(message); !errors.Is(err, ErrOutboundQueueFull) {
		t.Fatalf("per-socket byte overflow Send() = %v", err)
	}
	if socket.closing {
		t.Fatal("per-socket byte backpressure closed the socket")
	}
}

func TestSharedQueuedByteBudgetIsReleasedWithFrames(t *testing.T) {
	t.Parallel()
	message := protocol.Message{Type: protocol.MessageHostUnavailable}
	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	budget := NewQueuedByteBudget(len(encoded) * 2)
	first := newUnstartedTestSocket(4, 4, protocol.MaximumMessageBytes)
	second := newUnstartedTestSocket(4, 4, protocol.MaximumMessageBytes)
	first.config.SharedQueuedBytes = budget
	second.config.SharedQueuedBytes = budget
	if err := first.Send(message); err != nil {
		t.Fatal(err)
	}
	if err := second.Send(message); err != nil {
		t.Fatal(err)
	}
	if err := second.Send(message); !errors.Is(err, ErrOutboundQueueFull) {
		t.Fatalf("shared byte overflow Send() = %v", err)
	}
	frame := <-first.outbound
	first.releaseFrameUsage(frame)
	if budget.Used() != len(encoded) {
		t.Fatalf("queued bytes after release = %d; want %d", budget.Used(), len(encoded))
	}
	if err := second.Send(message); err != nil {
		t.Fatalf("Send() after shared capacity returned = %v", err)
	}
}

func TestAbortClosesSocketImmediately(t *testing.T) {
	t.Parallel()
	socket := newUnstartedTestSocket(1, 1, protocol.MaximumMessageBytes)
	socket.Abort()
	select {
	case <-socket.Done():
	default:
		t.Fatal("Abort() did not close Done")
	}
	if err := socket.Send(protocol.Message{Type: protocol.MessageHostUnavailable}); !errors.Is(err, ErrSocketClosed) {
		t.Fatalf("Send() after Abort() = %v", err)
	}
}
