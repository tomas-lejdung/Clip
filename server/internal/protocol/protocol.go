package protocol

import (
	"bytes"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
)

const (
	Identifier                      = "clip-live-share"
	Version                         = 1
	MaximumMessageBytes             = 262_144
	MaximumInnerMessageBytes        = 196_400
	MaximumPendingViewersPerRoom    = 8
	MaximumConnectedViewersInClip   = 8
	MaximumICECandidatesPerPeer     = 256
	InitialAnswerTimeoutSeconds     = 15
	OwnerTokenBytes                 = 32
	RouteIDBytes                    = 16
	AESGCMNonceBytes                = 12
	AESGCMTagBytes                  = 16
	P256X963PublicKeyBytes          = 65
	MaximumCiphertextBytes          = MaximumInnerMessageBytes + AESGCMTagBytes
	MaximumProtocolErrorCodeBytes   = 64
	MaximumProtocolErrorTextBytes   = 256
	MaximumRoomNameBytes            = 64
	MinimumRoomNameBytes            = 3
	NativeRendezvousAPIVersion      = 1
	NativeMessageVersion            = 2
	NativeRendezvousIDBytes         = 32
	MaximumNativeDescriptorBytes    = 16_384
	MaximumNativeOpaquePayloadBytes = 196_000
)

var roomNamePattern = regexp.MustCompile(`^[A-Z0-9](?:[A-Z0-9-]{1,62})[A-Z0-9]$`)

var (
	ErrInvalidRoomName           = errors.New("invalid room name")
	ErrInvalidOwnerToken         = errors.New("invalid owner token")
	ErrInvalidRouteID            = errors.New("invalid route identifier")
	ErrInvalidViewerKey          = errors.New("invalid viewer key")
	ErrInvalidMessage            = errors.New("invalid protocol message")
	ErrInvalidNativeRendezvousID = errors.New("invalid native rendezvous identifier")
	ErrInvalidNativeDescriptor   = errors.New("invalid native session descriptor")
)

type MessageType string

const (
	MessageViewerHello           MessageType = "viewer-hello"
	MessageRouteOpened           MessageType = "route-opened"
	MessageRelay                 MessageType = "relay"
	MessageRouteClosed           MessageType = "route-closed"
	MessageCloseRoute            MessageType = "close-route"
	MessageHostUnavailable       MessageType = "host-unavailable"
	MessageError                 MessageType = "error"
	MessageNativeRouteOpened     MessageType = "native-route-opened"
	MessageNativeRelay           MessageType = "native-relay"
	MessageNativeRouteClosed     MessageType = "native-route-closed"
	MessageNativeCloseRoute      MessageType = "native-close-route"
	MessageNativeHostUnavailable MessageType = "native-host-unavailable"
	MessageNativeError           MessageType = "native-error"
)

// Message is the bounded, metadata-only outer signaling envelope. Ciphertext
// is deliberately opaque to the service.
type Message struct {
	Type       MessageType `json:"type"`
	Version    int         `json:"version,omitempty"`
	RouteID    string      `json:"routeId,omitempty"`
	ViewerKey  string      `json:"viewerKey,omitempty"`
	Sequence   uint64      `json:"sequence,omitempty"`
	Nonce      string      `json:"nonce,omitempty"`
	Ciphertext string      `json:"ciphertext,omitempty"`
	Payload    string      `json:"payload,omitempty"`
	Reason     string      `json:"reason,omitempty"`
	Code       string      `json:"code,omitempty"`
	Text       string      `json:"message,omitempty"`
}

type OwnerRequest struct {
	OwnerToken string `json:"ownerToken"`
}

type RoomResponse struct {
	Room                 string `json:"room"`
	LeaseDurationSeconds int64  `json:"leaseDurationSeconds"`
}

type NativeRendezvousRequest struct {
	OwnerToken string `json:"ownerToken"`
}

type NativeSessionRequest struct {
	// Descriptor is a canonical base64url encoding of a signed descriptor.
	// The service bounds and stores it without parsing its contents.
	Descriptor string `json:"descriptor"`
}

type NativeRendezvousResponse struct {
	RendezvousID         string `json:"rendezvousId"`
	LeaseDurationSeconds int64  `json:"leaseDurationSeconds"`
}

type NativeRendezvousStatus struct {
	RendezvousID string `json:"rendezvousId"`
	State        string `json:"state"`
}

type NativeRendezvousCapabilities struct {
	Protocol                    string `json:"protocol"`
	APIVersion                  int    `json:"apiVersion"`
	MessageVersion              int    `json:"messageVersion"`
	ServerVersion               string `json:"serverVersion"`
	RendezvousPathTemplate      string `json:"rendezvousPathTemplate"`
	HostWebSocketPathTemplate   string `json:"hostWebSocketPathTemplate"`
	ViewerWebSocketPathTemplate string `json:"viewerWebSocketPathTemplate"`
	MaximumMessageBytes         int    `json:"maximumMessageBytes"`
	MaximumDescriptorBytes      int    `json:"maximumDescriptorBytes"`
	MaximumOpaquePayloadBytes   int    `json:"maximumOpaquePayloadBytes"`
	MaximumPendingRoutes        int    `json:"maximumPendingRoutes"`
	MaximumRendezvous           int    `json:"maximumRendezvous"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

type Limits struct {
	MaximumMessageBytes          int `json:"maximumMessageBytes"`
	MaximumPendingViewersPerRoom int `json:"maximumPendingViewersPerRoom"`
}

type Capabilities struct {
	Protocol                    string      `json:"protocol"`
	Versions                    []int       `json:"versions"`
	ServerVersion               string      `json:"serverVersion"`
	ViewerPathTemplate          string      `json:"viewerPathTemplate"`
	HostWebSocketPathTemplate   string      `json:"hostWebSocketPathTemplate"`
	ViewerWebSocketPathTemplate string      `json:"viewerWebSocketPathTemplate"`
	ICEServers                  []ICEServer `json:"iceServers"`
	Limits                      Limits      `json:"limits"`
}

type VersionResponse struct {
	Protocol        string `json:"protocol"`
	ProtocolVersion int    `json:"protocolVersion"`
	ServerVersion   string `json:"serverVersion"`
}

func NormalizeRoomName(value string) (string, error) {
	name := strings.ToUpper(strings.TrimSpace(value))
	if len(name) < MinimumRoomNameBytes || len(name) > MaximumRoomNameBytes || !roomNamePattern.MatchString(name) {
		return "", ErrInvalidRoomName
	}
	return name, nil
}

func DecodeOwnerToken(value string) ([OwnerTokenBytes]byte, error) {
	var token [OwnerTokenBytes]byte
	decoded, err := decodeCanonicalBase64URL(value, OwnerTokenBytes)
	if err != nil {
		return token, ErrInvalidOwnerToken
	}
	copy(token[:], decoded)
	return token, nil
}

func HashOwnerToken(value string) ([sha256.Size]byte, error) {
	token, err := DecodeOwnerToken(value)
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	return sha256.Sum256(token[:]), nil
}

func ValidateNativeRendezvousID(value string) error {
	if _, err := decodeCanonicalBase64URL(value, NativeRendezvousIDBytes); err != nil {
		return ErrInvalidNativeRendezvousID
	}
	return nil
}

func ValidateNativeDescriptor(value string) error {
	if _, err := decodeCanonicalBase64URLRange(value, 1, MaximumNativeDescriptorBytes); err != nil {
		return ErrInvalidNativeDescriptor
	}
	return nil
}

func ValidateRouteID(value string) error {
	if _, err := decodeCanonicalBase64URL(value, RouteIDBytes); err != nil {
		return ErrInvalidRouteID
	}
	return nil
}

func ValidateViewerKey(value string) error {
	decoded, err := decodeCanonicalBase64URL(value, P256X963PublicKeyBytes)
	if err != nil || len(decoded) != P256X963PublicKeyBytes || decoded[0] != 4 {
		return ErrInvalidViewerKey
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), decoded)
	if x == nil || y == nil {
		return ErrInvalidViewerKey
	}
	return nil
}

func ValidateViewerHello(message Message) error {
	if message.Type != MessageViewerHello || message.Version != Version {
		return fmt.Errorf("%w: unsupported viewer hello", ErrInvalidMessage)
	}
	if message.RouteID != "" || message.Sequence != 0 || message.Nonce != "" || message.Ciphertext != "" || message.Payload != "" {
		return fmt.Errorf("%w: unexpected viewer hello fields", ErrInvalidMessage)
	}
	return ValidateViewerKey(message.ViewerKey)
}

func ValidateRelay(message Message, requireRouteID bool) error {
	if message.Type != MessageRelay || message.Sequence == 0 {
		return fmt.Errorf("%w: malformed relay", ErrInvalidMessage)
	}
	if requireRouteID {
		if err := ValidateRouteID(message.RouteID); err != nil {
			return err
		}
	} else if message.RouteID != "" {
		return fmt.Errorf("%w: viewer route must be implicit", ErrInvalidMessage)
	}
	if _, err := decodeCanonicalBase64URL(message.Nonce, AESGCMNonceBytes); err != nil {
		return fmt.Errorf("%w: invalid nonce", ErrInvalidMessage)
	}
	ciphertext, err := decodeCanonicalBase64URLRange(message.Ciphertext, AESGCMTagBytes, MaximumCiphertextBytes)
	if err != nil || len(ciphertext) < AESGCMTagBytes {
		return fmt.Errorf("%w: invalid ciphertext", ErrInvalidMessage)
	}
	if message.Version != 0 || message.ViewerKey != "" || message.Payload != "" || message.Reason != "" || message.Code != "" || message.Text != "" {
		return fmt.Errorf("%w: unexpected relay fields", ErrInvalidMessage)
	}
	return nil
}

func ValidateCloseRoute(message Message) error {
	if message.Type != MessageCloseRoute {
		return fmt.Errorf("%w: expected close-route", ErrInvalidMessage)
	}
	if err := ValidateRouteID(message.RouteID); err != nil {
		return err
	}
	if message.Version != 0 || message.ViewerKey != "" || message.Sequence != 0 || message.Nonce != "" || message.Ciphertext != "" || message.Payload != "" || message.Code != "" || message.Text != "" {
		return fmt.Errorf("%w: unexpected close-route fields", ErrInvalidMessage)
	}
	return nil
}

func ValidateNativeRelay(message Message, requireRouteID bool) error {
	if message.Type != MessageNativeRelay || message.Version != NativeMessageVersion || message.Sequence == 0 {
		return fmt.Errorf("%w: malformed native relay", ErrInvalidMessage)
	}
	if requireRouteID {
		if err := ValidateRouteID(message.RouteID); err != nil {
			return err
		}
	} else if message.RouteID != "" {
		return fmt.Errorf("%w: native viewer route must be implicit", ErrInvalidMessage)
	}
	if _, err := decodeCanonicalBase64URLRange(message.Payload, 1, MaximumNativeOpaquePayloadBytes); err != nil {
		return fmt.Errorf("%w: invalid native opaque payload", ErrInvalidMessage)
	}
	if message.ViewerKey != "" || message.Nonce != "" || message.Ciphertext != "" || message.Reason != "" || message.Code != "" || message.Text != "" {
		return fmt.Errorf("%w: unexpected native relay fields", ErrInvalidMessage)
	}
	return nil
}

func ValidateNativeCloseRoute(message Message, requireRouteID bool) error {
	if message.Type != MessageNativeCloseRoute || message.Version != NativeMessageVersion {
		return fmt.Errorf("%w: expected native close-route", ErrInvalidMessage)
	}
	if requireRouteID {
		if err := ValidateRouteID(message.RouteID); err != nil {
			return err
		}
	} else if message.RouteID != "" {
		return fmt.Errorf("%w: native viewer route must be implicit", ErrInvalidMessage)
	}
	if message.ViewerKey != "" || message.Sequence != 0 || message.Nonce != "" || message.Ciphertext != "" || message.Payload != "" || message.Code != "" || message.Text != "" {
		return fmt.Errorf("%w: unexpected native close-route fields", ErrInvalidMessage)
	}
	return nil
}

func DecodeMessage(data []byte) (Message, error) {
	if len(data) == 0 || len(data) > MaximumMessageBytes {
		return Message{}, fmt.Errorf("%w: message size", ErrInvalidMessage)
	}
	var message Message
	if err := DecodeStrictJSON(bytes.NewReader(data), int64(MaximumMessageBytes), &message); err != nil {
		return Message{}, fmt.Errorf("%w: %v", ErrInvalidMessage, err)
	}
	return message, nil
}

func DecodeStrictJSON(reader io.Reader, maximumBytes int64, destination any) error {
	data, err := io.ReadAll(io.LimitReader(reader, maximumBytes+1))
	if err != nil {
		return err
	}
	if int64(len(data)) > maximumBytes {
		return errors.New("JSON body exceeds limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

func ErrorMessage(code, text string) Message {
	return Message{
		Type: MessageError,
		Code: truncateASCII(code, MaximumProtocolErrorCodeBytes),
		Text: truncateASCII(text, MaximumProtocolErrorTextBytes),
	}
}

func NativeErrorMessage(code, text string) Message {
	return Message{
		Type:    MessageNativeError,
		Version: NativeMessageVersion,
		Code:    truncateASCII(code, MaximumProtocolErrorCodeBytes),
		Text:    truncateASCII(text, MaximumProtocolErrorTextBytes),
	}
}

func decodeCanonicalBase64URL(value string, expectedBytes int) ([]byte, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(decoded) != expectedBytes || base64.RawURLEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("invalid base64url value")
	}
	return decoded, nil
}

func decodeCanonicalBase64URLRange(value string, minimumBytes, maximumBytes int) ([]byte, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(decoded) < minimumBytes || len(decoded) > maximumBytes || base64.RawURLEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("invalid base64url value")
	}
	return decoded, nil
}

func truncateASCII(value string, maximumBytes int) string {
	value = strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e {
			return -1
		}
		return r
	}, value)
	if len(value) > maximumBytes {
		return value[:maximumBytes]
	}
	return value
}
