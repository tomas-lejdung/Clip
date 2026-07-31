package protocol

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

const (
	Identifier                      = "clip-native-rendezvous"
	MaximumMessageBytes             = 262_144
	MaximumPendingRoutes            = 8
	OwnerTokenBytes                 = 32
	RouteIDBytes                    = 16
	MaximumProtocolErrorCodeBytes   = 64
	MaximumProtocolErrorTextBytes   = 256
	NativeRendezvousAPIVersion      = 3
	NativeMessageVersion            = 3
	NativeRendezvousIDBytes         = 32
	MaximumNativeDescriptorBytes    = 16_384
	MaximumNativeOpaquePayloadBytes = 196_000
)

var (
	ErrInvalidOwnerToken         = errors.New("invalid owner token")
	ErrInvalidRouteID            = errors.New("invalid route identifier")
	ErrInvalidMessage            = errors.New("invalid protocol message")
	ErrInvalidNativeRendezvousID = errors.New("invalid native rendezvous identifier")
	ErrInvalidNativeDescriptor   = errors.New("invalid native session descriptor")
)

type MessageType string

const (
	MessageNativeRouteOpened      MessageType = "native-route-opened"
	MessageNativeRelay            MessageType = "native-relay"
	MessageNativeRouteClosed      MessageType = "native-route-closed"
	MessageNativeCloseRoute       MessageType = "native-close-route"
	MessageNativeOwnerUnavailable MessageType = "native-owner-unavailable"
	MessageNativeError            MessageType = "native-error"
)

// Message is the bounded outer envelope used only by the opaque rendezvous
// service. Native-v3 bootstrap and mesh contents stay encrypted inside
// Payload; the service validates only routing metadata and byte bounds.
type Message struct {
	Type     MessageType `json:"type"`
	Version  int         `json:"version"`
	RouteID  string      `json:"routeId,omitempty"`
	Sequence uint64      `json:"sequence,omitempty"`
	Payload  string      `json:"payload,omitempty"`
	Reason   string      `json:"reason,omitempty"`
	Code     string      `json:"code,omitempty"`
	Text     string      `json:"message,omitempty"`
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
	Protocol                       string      `json:"protocol"`
	APIVersion                     int         `json:"apiVersion"`
	MessageVersion                 int         `json:"messageVersion"`
	ServerVersion                  string      `json:"serverVersion"`
	RendezvousPathTemplate         string      `json:"rendezvousPathTemplate"`
	OwnerWebSocketPathTemplate     string      `json:"ownerWebSocketPathTemplate"`
	CandidateWebSocketPathTemplate string      `json:"candidateWebSocketPathTemplate"`
	MaximumMessageBytes            int         `json:"maximumMessageBytes"`
	MaximumDescriptorBytes         int         `json:"maximumDescriptorBytes"`
	MaximumOpaquePayloadBytes      int         `json:"maximumOpaquePayloadBytes"`
	MaximumPendingRoutes           int         `json:"maximumPendingRoutes"`
	MaximumRendezvous              int         `json:"maximumRendezvous"`
	ICEServers                     []ICEServer `json:"iceServers"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

// ICEServer remains deployment configuration used by native WebRTC peers. It
// is not inspected by the rendezvous router.
type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

type VersionResponse struct {
	Protocol        string `json:"protocol"`
	ProtocolVersion int    `json:"protocolVersion"`
	ServerVersion   string `json:"serverVersion"`
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
	if _, err := decodeCanonicalBase64URLRange(
		value,
		1,
		MaximumNativeDescriptorBytes,
	); err != nil {
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

func ValidateNativeRelay(message Message, requireRouteID bool) error {
	if message.Type != MessageNativeRelay ||
		message.Version != NativeMessageVersion ||
		message.Sequence == 0 {
		return fmt.Errorf("%w: malformed native relay", ErrInvalidMessage)
	}
	if requireRouteID {
		if err := ValidateRouteID(message.RouteID); err != nil {
			return err
		}
	} else if message.RouteID != "" {
		return fmt.Errorf("%w: candidate route must be implicit", ErrInvalidMessage)
	}
	if _, err := decodeCanonicalBase64URLRange(
		message.Payload,
		1,
		MaximumNativeOpaquePayloadBytes,
	); err != nil {
		return fmt.Errorf("%w: invalid native opaque payload", ErrInvalidMessage)
	}
	if message.Reason != "" || message.Code != "" || message.Text != "" {
		return fmt.Errorf("%w: unexpected native relay fields", ErrInvalidMessage)
	}
	return nil
}

func ValidateNativeCloseRoute(message Message, requireRouteID bool) error {
	if message.Type != MessageNativeCloseRoute ||
		message.Version != NativeMessageVersion {
		return fmt.Errorf("%w: expected native close-route", ErrInvalidMessage)
	}
	if requireRouteID {
		if err := ValidateRouteID(message.RouteID); err != nil {
			return err
		}
	} else if message.RouteID != "" {
		return fmt.Errorf("%w: candidate route must be implicit", ErrInvalidMessage)
	}
	if message.Sequence != 0 ||
		message.Payload != "" ||
		message.Code != "" ||
		message.Text != "" {
		return fmt.Errorf("%w: unexpected native close-route fields", ErrInvalidMessage)
	}
	return nil
}

func DecodeMessage(data []byte) (Message, error) {
	if len(data) == 0 || len(data) > MaximumMessageBytes {
		return Message{}, fmt.Errorf("%w: message size", ErrInvalidMessage)
	}
	var message Message
	if err := DecodeStrictJSON(
		bytes.NewReader(data),
		int64(MaximumMessageBytes),
		&message,
	); err != nil {
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
	if err != nil ||
		len(decoded) != expectedBytes ||
		base64.RawURLEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("invalid base64url value")
	}
	return decoded, nil
}

func decodeCanonicalBase64URLRange(
	value string,
	minimumBytes,
	maximumBytes int,
) ([]byte, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil ||
		len(decoded) < minimumBytes ||
		len(decoded) > maximumBytes ||
		base64.RawURLEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("invalid base64url value")
	}
	return decoded, nil
}

func truncateASCII(value string, maximumBytes int) string {
	value = string(bytes.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e {
			return -1
		}
		return r
	}, []byte(value)))
	if len(value) > maximumBytes {
		return value[:maximumBytes]
	}
	return value
}
