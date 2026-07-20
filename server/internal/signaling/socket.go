package signaling

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

var (
	ErrSocketClosed      = errors.New("websocket is closed")
	ErrOutboundQueueFull = errors.New("websocket outbound queue is full")
	ErrRouteQueueFull    = errors.New("websocket route outbound queue is full")
	ErrNonTextMessage    = errors.New("only text websocket frames are supported")
)

type SocketConfiguration struct {
	ReadTimeout                   time.Duration
	WriteTimeout                  time.Duration
	PingInterval                  time.Duration
	QueueDepth                    int
	MaximumQueuedBytes            int
	SharedQueuedBytes             *QueuedByteBudget
	MaximumQueuedMessagesPerRoute int
	MaximumQueuedBytesPerRoute    int
	OnKeepAlive                   func()
}

type outboundFrame struct {
	messageType int
	data        []byte
	routeID     string
	accounted   bool
	terminal    bool
}

type routeQueueUsage struct {
	messages int
	bytes    int
}

// QueuedByteBudget provides a process-wide ceiling across every socket queue.
// It counts both queued and currently-writing application frames.
type QueuedByteBudget struct {
	mu      sync.Mutex
	maximum int
	used    int
}

func NewQueuedByteBudget(maximum int) *QueuedByteBudget {
	return &QueuedByteBudget{maximum: maximum}
}

func (b *QueuedByteBudget) tryReserve(bytes int) bool {
	if b == nil {
		return true
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if bytes < 0 || b.maximum <= 0 || b.used+bytes > b.maximum {
		return false
	}
	b.used += bytes
	return true
}

func (b *QueuedByteBudget) release(bytes int) {
	if b == nil || bytes <= 0 {
		return
	}
	b.mu.Lock()
	b.used -= bytes
	if b.used < 0 {
		b.used = 0
	}
	b.mu.Unlock()
}

func (b *QueuedByteBudget) Used() int {
	if b == nil {
		return 0
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.used
}

// Socket owns the sole WebSocket writer. Its bounded queue provides a strict
// memory ceiling. Send reports backpressure to the routing layer, which can
// retire only the affected route instead of disconnecting a shared host.
type Socket struct {
	connection  *websocket.Conn
	config      SocketConfiguration
	outbound    chan outboundFrame
	done        chan struct{}
	writeDone   chan struct{}
	startOnce   sync.Once
	finishOnce  sync.Once
	mu          sync.Mutex
	closing     bool
	queuedBytes int
	routeUsage  map[string]routeQueueUsage
}

func NewSocket(connection *websocket.Conn, configuration SocketConfiguration) *Socket {
	if configuration.QueueDepth <= 0 {
		configuration.QueueDepth = 16
	}
	if configuration.MaximumQueuedBytes <= 0 {
		configuration.MaximumQueuedBytes = 2 << 20
	}
	if configuration.MaximumQueuedMessagesPerRoute <= 0 {
		configuration.MaximumQueuedMessagesPerRoute = max(1, configuration.QueueDepth/2)
	}
	if configuration.MaximumQueuedBytesPerRoute <= 0 {
		configuration.MaximumQueuedBytesPerRoute = 1 << 20
	}
	socket := &Socket{
		connection: connection,
		config:     configuration,
		outbound:   make(chan outboundFrame, configuration.QueueDepth),
		done:       make(chan struct{}),
		writeDone:  make(chan struct{}),
		routeUsage: make(map[string]routeQueueUsage),
	}
	connection.SetReadLimit(protocol.MaximumMessageBytes)
	connection.SetPongHandler(func(string) error {
		_ = connection.SetReadDeadline(time.Now().Add(configuration.ReadTimeout))
		if configuration.OnKeepAlive != nil {
			configuration.OnKeepAlive()
		}
		return nil
	})
	return socket
}

func (s *Socket) Start() {
	s.startOnce.Do(func() {
		go s.writeLoop()
	})
}

func (s *Socket) SetReadDeadline(deadline time.Time) error {
	return s.connection.SetReadDeadline(deadline)
}

func (s *Socket) ResetReadDeadline() error {
	return s.connection.SetReadDeadline(time.Now().Add(s.config.ReadTimeout))
}

func (s *Socket) Read() (protocol.Message, error) {
	messageType, data, err := s.connection.ReadMessage()
	if err != nil {
		return protocol.Message{}, err
	}
	if messageType != websocket.TextMessage {
		return protocol.Message{}, ErrNonTextMessage
	}
	return protocol.DecodeMessage(data)
}

func (s *Socket) Send(message protocol.Message) error {
	data, err := json.Marshal(message)
	if err != nil {
		return fmt.Errorf("marshal protocol message: %w", err)
	}
	if len(data) > protocol.MaximumMessageBytes {
		return fmt.Errorf("protocol message exceeds %d bytes", protocol.MaximumMessageBytes)
	}

	limitedRouteID := ""
	if message.Type == protocol.MessageRelay {
		limitedRouteID = message.RouteID
	}

	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return ErrSocketClosed
	}
	if limitedRouteID != "" {
		usage := s.routeUsage[limitedRouteID]
		if usage.messages >= s.config.MaximumQueuedMessagesPerRoute ||
			usage.bytes+len(data) > s.config.MaximumQueuedBytesPerRoute {
			s.mu.Unlock()
			return ErrRouteQueueFull
		}
	}
	if s.queuedBytes+len(data) > s.config.MaximumQueuedBytes || !s.config.SharedQueuedBytes.tryReserve(len(data)) {
		s.mu.Unlock()
		return ErrOutboundQueueFull
	}
	select {
	case s.outbound <- outboundFrame{messageType: websocket.TextMessage, data: data, routeID: limitedRouteID, accounted: true}:
		s.queuedBytes += len(data)
		if limitedRouteID != "" {
			usage := s.routeUsage[limitedRouteID]
			usage.messages++
			usage.bytes += len(data)
			s.routeUsage[limitedRouteID] = usage
		}
		s.mu.Unlock()
		return nil
	default:
		s.config.SharedQueuedBytes.release(len(data))
		s.mu.Unlock()
		return ErrOutboundQueueFull
	}
}

func (s *Socket) Close(code int, reason string) {
	payload := websocket.FormatCloseMessage(code, boundedReason(reason))
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return
	}
	s.closing = true
	select {
	case s.outbound <- outboundFrame{messageType: websocket.CloseMessage, data: payload, terminal: true}:
		s.mu.Unlock()
	case <-s.done:
		s.mu.Unlock()
	default:
		s.mu.Unlock()
		s.forceClose()
	}
}

func (s *Socket) Done() <-chan struct{} {
	return s.done
}

func (s *Socket) Wait() {
	<-s.writeDone
}

// Abort immediately closes the transport and is reserved for expired shutdown
// deadlines. Normal lifecycle paths should use Close so peers receive a frame.
func (s *Socket) Abort() {
	s.forceClose()
}

func (s *Socket) writeLoop() {
	defer close(s.writeDone)
	defer s.releasePendingFrames()
	pingTicker := time.NewTicker(s.config.PingInterval)
	defer pingTicker.Stop()

	for {
		select {
		case frame := <-s.outbound:
			err := s.write(frame.messageType, frame.data)
			s.releaseFrameUsage(frame)
			if err != nil {
				s.forceClose()
				return
			}
			if frame.terminal {
				s.forceClose()
				return
			}
		case <-pingTicker.C:
			deadline := time.Now().Add(s.config.WriteTimeout)
			if err := s.connection.WriteControl(websocket.PingMessage, nil, deadline); err != nil {
				s.forceClose()
				return
			}
			if s.config.OnKeepAlive != nil {
				s.config.OnKeepAlive()
			}
		case <-s.done:
			return
		}
	}
}

func (s *Socket) releaseFrameUsage(frame outboundFrame) {
	if !frame.accounted {
		return
	}
	s.mu.Lock()
	s.queuedBytes -= len(frame.data)
	if s.queuedBytes < 0 {
		s.queuedBytes = 0
	}
	if frame.routeID != "" {
		usage := s.routeUsage[frame.routeID]
		usage.messages--
		usage.bytes -= len(frame.data)
		if usage.messages <= 0 || usage.bytes <= 0 {
			delete(s.routeUsage, frame.routeID)
		} else {
			s.routeUsage[frame.routeID] = usage
		}
	}
	s.mu.Unlock()
	s.config.SharedQueuedBytes.release(len(frame.data))
}

func (s *Socket) releasePendingFrames() {
	for {
		select {
		case frame := <-s.outbound:
			s.releaseFrameUsage(frame)
		default:
			return
		}
	}
}

func (s *Socket) write(messageType int, data []byte) error {
	if err := s.connection.SetWriteDeadline(time.Now().Add(s.config.WriteTimeout)); err != nil {
		return err
	}
	return s.connection.WriteMessage(messageType, data)
}

func (s *Socket) forceClose() {
	s.mu.Lock()
	s.closing = true
	s.mu.Unlock()
	s.finishOnce.Do(func() {
		close(s.done)
		if s.connection != nil {
			_ = s.connection.Close()
		}
	})
}
