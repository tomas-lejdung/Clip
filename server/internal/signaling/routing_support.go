package signaling

import (
	"errors"

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

var ErrRouteBackpressure = errors.New("pair signaling capacity exceeded")

// Peer is the narrow transport boundary used by the opaque room coordinator.
// The service never interprets the encrypted descriptors or pair payloads.
type Peer interface {
	Send(protocol.Message) error
	Close(code int, reason string)
}

func boundedReason(reason string) string {
	if len(reason) > 120 {
		return reason[:120]
	}
	return reason
}
