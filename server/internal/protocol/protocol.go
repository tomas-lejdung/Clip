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
	Identifier                                  = "clip-native-room"
	MaximumMessageBytes                         = 262_144
	MaximumPendingCandidates                    = 8
	OwnerTokenBytes                             = 32
	MaximumProtocolErrorCodeBytes               = 64
	MaximumProtocolErrorTextBytes               = 256
	NativeRoomAPIVersion                        = 4
	NativeRoomMessageVersion                    = 4
	NativeRoomIDBytes                           = 32
	NativeMemberHandleBytes                     = 16
	NativeReconnectCapabilityBytes              = 32
	NativePairIDBytes                           = 32
	MaximumNativeRoomMembers                    = 4
	MaximumNativeDescriptorBytes                = 16_384
	MaximumNativeOpaquePayloadBytes             = 196_000
	NativeFriendPresenceRoutingIDBytes          = 32
	MinimumNativeFriendPresencePayloadBytes     = 29
	MaximumNativeFriendPresencePayloadBytes     = 16_384
	MaximumNativeFriendPresenceLifetimeSeconds  = 5 * 60
	MaximumNativeFriendPresenceClockSkewSeconds = 30
)

var (
	ErrInvalidOwnerToken           = errors.New("invalid owner token")
	ErrInvalidMessage              = errors.New("invalid protocol message")
	ErrInvalidNativeRoomID         = errors.New("invalid native room identifier")
	ErrInvalidNativeDescriptor     = errors.New("invalid native descriptor")
	ErrInvalidNativeFriendPresence = errors.New("invalid native friend presence")
)

type MessageType string

const (
	MessageCandidateOpened MessageType = "candidate-opened"
	MessageJoinKnock       MessageType = "join-knock"
	MessageAdmitCandidate  MessageType = "admit-candidate"
	MessageDenyCandidate   MessageType = "deny-candidate"
	MessageMemberAdmitted  MessageType = "member-admitted"
	MessageRosterSnapshot  MessageType = "roster-snapshot"
	MessagePairSignal      MessageType = "pair-signal"
	MessageLeaveRoom       MessageType = "leave-room"
	MessageRemoveMember    MessageType = "remove-member"
	MessageRoomEnded       MessageType = "room-ended"
	MessageProtocolError   MessageType = "protocol-error"
)

// Message is the bounded native-room-v4 outer routing envelope. Payload,
// descriptors, admission records, and pair signals are opaque ciphertext.
type Message struct {
	Type                MessageType     `json:"type"`
	Version             int             `json:"version"`
	Sequence            uint64          `json:"sequence,omitempty"`
	Payload             string          `json:"payload,omitempty"`
	Reason              string          `json:"reason,omitempty"`
	Code                string          `json:"code,omitempty"`
	Text                string          `json:"message,omitempty"`
	CandidateHandle     string          `json:"candidateHandle,omitempty"`
	MemberHandle        string          `json:"memberHandle,omitempty"`
	ReconnectCapability string          `json:"reconnectCapability,omitempty"`
	RoomDescriptor      string          `json:"roomDescriptor,omitempty"`
	From                string          `json:"from,omitempty"`
	To                  string          `json:"to,omitempty"`
	PairID              string          `json:"pairId,omitempty"`
	Roster              *RosterSnapshot `json:"roster,omitempty"`
}

type RosterMember struct {
	Handle     string `json:"handle"`
	Descriptor string `json:"descriptor"`
	Connected  bool   `json:"connected"`
}

type RosterSnapshot struct {
	Revision      uint64         `json:"revision"`
	CreatorHandle string         `json:"creatorHandle"`
	Members       []RosterMember `json:"members"`
}

type NativeRoomRequest struct {
	OwnerToken    string `json:"ownerToken"`
	CreatorHandle string `json:"creatorHandle"`
	Descriptor    string `json:"descriptor"`
}

type NativeRoomResponse struct {
	RoomID               string `json:"roomId"`
	CreatorHandle        string `json:"creatorHandle"`
	LeaseDurationSeconds int64  `json:"leaseDurationSeconds"`
}

type NativeRoomStatus struct {
	RoomID         string `json:"roomId"`
	State          string `json:"state"`
	RosterRevision uint64 `json:"rosterRevision"`
	MemberCount    int    `json:"memberCount"`
}

// NativeFriendPresence is intentionally opaque. The server may enforce only
// routing, monotonic revision, size, and expiry bounds; identity, names, the
// canonical room invite, and the per-friend decryption key remain client-only.
type NativeFriendPresence struct {
	Revision              uint64 `json:"revision"`
	ExpiresAtMilliseconds int64  `json:"expiresAtMilliseconds"`
	Payload               string `json:"payload"`
}

type NativeRoomCapabilities struct {
	Protocol                  string      `json:"protocol"`
	APIVersion                int         `json:"apiVersion"`
	MessageVersion            int         `json:"messageVersion"`
	ServerVersion             string      `json:"serverVersion"`
	RoomPathTemplate          string      `json:"roomPathTemplate"`
	RoomWebSocketPathTemplate string      `json:"roomWebSocketPathTemplate"`
	MaximumMessageBytes       int         `json:"maximumMessageBytes"`
	MaximumDescriptorBytes    int         `json:"maximumDescriptorBytes"`
	MaximumOpaquePayloadBytes int         `json:"maximumOpaquePayloadBytes"`
	MaximumPendingCandidates  int         `json:"maximumPendingCandidates"`
	MaximumRoomMembers        int         `json:"maximumRoomMembers"`
	MaximumRooms              int         `json:"maximumRooms"`
	ICEServers                []ICEServer `json:"iceServers"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

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

func ValidateNativeRoomID(value string) error {
	if _, err := decodeCanonicalBase64URL(value, NativeRoomIDBytes); err != nil {
		return ErrInvalidNativeRoomID
	}
	return nil
}

func ValidateNativeFriendPresenceRoutingID(value string) error {
	if _, err := decodeCanonicalBase64URL(value, NativeFriendPresenceRoutingIDBytes); err != nil {
		return ErrInvalidNativeFriendPresence
	}
	return nil
}

func ValidateNativeFriendPresence(value NativeFriendPresence) error {
	if value.Revision == 0 || value.ExpiresAtMilliseconds <= 0 {
		return ErrInvalidNativeFriendPresence
	}
	if _, err := decodeCanonicalBase64URLRange(
		value.Payload,
		MinimumNativeFriendPresencePayloadBytes,
		MaximumNativeFriendPresencePayloadBytes,
	); err != nil {
		return ErrInvalidNativeFriendPresence
	}
	return nil
}

func ValidateNativeDescriptor(value string) error {
	if _, err := decodeCanonicalBase64URLRange(value, 1, MaximumNativeDescriptorBytes); err != nil {
		return ErrInvalidNativeDescriptor
	}
	return nil
}

func ValidateNativeMemberHandle(value string) error {
	if _, err := decodeCanonicalBase64URL(value, NativeMemberHandleBytes); err != nil {
		return fmt.Errorf("%w: invalid member handle", ErrInvalidMessage)
	}
	return nil
}

func ValidateNativeReconnectCapability(value string) error {
	if _, err := decodeCanonicalBase64URL(value, NativeReconnectCapabilityBytes); err != nil {
		return ErrInvalidOwnerToken
	}
	return nil
}

func HashNativeReconnectCapability(value string) ([sha256.Size]byte, error) {
	decoded, err := decodeCanonicalBase64URL(value, NativeReconnectCapabilityBytes)
	if err != nil {
		return [sha256.Size]byte{}, ErrInvalidOwnerToken
	}
	return sha256.Sum256(decoded), nil
}

func ValidateNativePairID(value string) error {
	if _, err := decodeCanonicalBase64URL(value, NativePairIDBytes); err != nil {
		return fmt.Errorf("%w: invalid pair identifier", ErrInvalidMessage)
	}
	return nil
}

// NativePairID is the sole pair identifier for two room handles. Canonical
// base64url strings make this algorithm byte-identical in Go, Swift, and web
// clients without exposing any secret room material.
func NativePairID(roomID, leftHandle, rightHandle string) (string, error) {
	if ValidateNativeRoomID(roomID) != nil ||
		ValidateNativeMemberHandle(leftHandle) != nil ||
		ValidateNativeMemberHandle(rightHandle) != nil ||
		leftHandle == rightHandle {
		return "", fmt.Errorf("%w: invalid pair members", ErrInvalidMessage)
	}
	if rightHandle < leftHandle {
		leftHandle, rightHandle = rightHandle, leftHandle
	}
	digest := sha256.Sum256([]byte(
		"clip-native-room-v4-pair\x00" + roomID + "\x00" +
			leftHandle + "\x00" + rightHandle,
	))
	return base64.RawURLEncoding.EncodeToString(digest[:]), nil
}

func ValidateRosterSnapshot(snapshot RosterSnapshot) error {
	if snapshot.Revision == 0 || ValidateNativeMemberHandle(snapshot.CreatorHandle) != nil ||
		len(snapshot.Members) == 0 || len(snapshot.Members) > MaximumNativeRoomMembers {
		return fmt.Errorf("%w: invalid roster header", ErrInvalidMessage)
	}
	seen := make(map[string]struct{}, len(snapshot.Members))
	creatorFound := false
	for _, member := range snapshot.Members {
		if ValidateNativeMemberHandle(member.Handle) != nil || ValidateNativeDescriptor(member.Descriptor) != nil {
			return fmt.Errorf("%w: invalid roster member", ErrInvalidMessage)
		}
		if _, found := seen[member.Handle]; found {
			return fmt.Errorf("%w: duplicate roster member", ErrInvalidMessage)
		}
		seen[member.Handle] = struct{}{}
		creatorFound = creatorFound || member.Handle == snapshot.CreatorHandle
	}
	if !creatorFound {
		return fmt.Errorf("%w: missing roster creator", ErrInvalidMessage)
	}
	return nil
}

// ValidateNativeRoomClientMessage validates only the outer routing envelope.
func ValidateNativeRoomClientMessage(message Message) error {
	if message.Version != NativeRoomMessageVersion || message.Roster != nil ||
		message.RoomDescriptor != "" || message.ReconnectCapability != "" ||
		message.From != "" || message.MemberHandle != "" || message.Code != "" ||
		message.Text != "" {
		return fmt.Errorf("%w: invalid native-room envelope", ErrInvalidMessage)
	}
	switch message.Type {
	case MessageJoinKnock:
		if message.CandidateHandle != "" || message.To != "" || message.PairID != "" ||
			message.Sequence == 0 || message.Reason != "" {
			return fmt.Errorf("%w: invalid join knock", ErrInvalidMessage)
		}
		return validateOpaquePayload(message.Payload)
	case MessageAdmitCandidate:
		if ValidateNativeMemberHandle(message.CandidateHandle) != nil ||
			message.Sequence != 0 || message.To != "" || message.PairID != "" ||
			message.Reason != "" {
			return fmt.Errorf("%w: invalid candidate admission", ErrInvalidMessage)
		}
		return ValidateNativeDescriptor(message.Payload)
	case MessageDenyCandidate:
		if ValidateNativeMemberHandle(message.CandidateHandle) != nil ||
			message.Sequence != 0 || message.Payload != "" || message.To != "" ||
			message.PairID != "" || len(message.Reason) > MaximumProtocolErrorTextBytes {
			return fmt.Errorf("%w: invalid candidate denial", ErrInvalidMessage)
		}
		return nil
	case MessagePairSignal:
		if ValidateNativeMemberHandle(message.To) != nil ||
			ValidateNativePairID(message.PairID) != nil || message.Sequence == 0 ||
			message.CandidateHandle != "" || message.Reason != "" {
			return fmt.Errorf("%w: invalid pair signal", ErrInvalidMessage)
		}
		return validateOpaquePayload(message.Payload)
	case MessageLeaveRoom:
		if message.CandidateHandle != "" || message.To != "" || message.PairID != "" ||
			message.Sequence != 0 || message.Payload != "" || message.Reason != "" {
			return fmt.Errorf("%w: invalid leave-room", ErrInvalidMessage)
		}
		return nil
	case MessageRemoveMember:
		if ValidateNativeMemberHandle(message.To) != nil || message.CandidateHandle != "" ||
			message.PairID != "" || message.Sequence != 0 || message.Payload != "" ||
			message.Reason != "" {
			return fmt.Errorf("%w: invalid remove-member", ErrInvalidMessage)
		}
		return nil
	default:
		return fmt.Errorf("%w: unsupported native-room message", ErrInvalidMessage)
	}
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

func RoomProtocolError(code, text string) Message {
	return Message{
		Type: MessageProtocolError, Version: NativeRoomMessageVersion,
		Code: truncateASCII(code, MaximumProtocolErrorCodeBytes),
		Text: truncateASCII(text, MaximumProtocolErrorTextBytes),
	}
}

// RoomPairProtocolError preserves only opaque routing identifiers from the
// rejected pair-signal. It lets a client retry or warn for that one direct
// edge without treating a healthy room or unrelated P2P links as failed.
func RoomPairProtocolError(code, text string, signal Message) Message {
	message := RoomProtocolError(code, text)
	if signal.Type == MessagePairSignal {
		message.Sequence = signal.Sequence
		message.To = signal.To
		message.PairID = signal.PairID
	}
	return message
}

func validateOpaquePayload(value string) error {
	if _, err := decodeCanonicalBase64URLRange(value, 1, MaximumNativeOpaquePayloadBytes); err != nil {
		return fmt.Errorf("%w: invalid opaque payload", ErrInvalidMessage)
	}
	return nil
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
	if err != nil || len(decoded) < minimumBytes || len(decoded) > maximumBytes ||
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
