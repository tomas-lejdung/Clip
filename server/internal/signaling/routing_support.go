package signaling

import (
	"encoding/json"
	"errors"
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
	ErrRouteLimit        = errors.New("pending route limit reached")
	ErrRouteNotFound     = errors.New("route not found")
	ErrStaleOwner        = errors.New("owner connection is stale")
	ErrStaleCandidate    = errors.New("candidate connection is stale")
	ErrSequence          = errors.New("relay sequence is not monotonic")
	ErrRouteBackpressure = errors.New("route signaling capacity exceeded")
)

// Peer is the narrow transport boundary used by the opaque rendezvous router.
// The service never interprets the encrypted native-v3 payload carried by a
// peer.
type Peer interface {
	Send(protocol.Message) error
	Close(code int, reason string)
}

type relayConfiguration struct {
	RelayBurstWindow             time.Duration
	MaximumRelayMessagesPerBurst int
	MaximumRelayBytesPerBurst    int
}

type relayBurstBudget struct {
	initialized   bool
	lastRefill    time.Time
	messageTokens float64
	byteTokens    float64
}

func (b *relayBurstBudget) allow(
	now time.Time,
	configuration relayConfiguration,
	messageBytes int,
) bool {
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
