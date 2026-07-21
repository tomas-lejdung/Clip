package protocol

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestNormalizeRoomName(t *testing.T) {
	t.Parallel()
	valid := map[string]string{
		"abc":                "ABC",
		"  crisp-frog-042  ": "CRISP-FROG-042",
		"A--B":               "A--B",
		strings.Repeat("a", MaximumRoomNameBytes): strings.Repeat("A", MaximumRoomNameBytes),
	}
	for input, expected := range valid {
		input, expected := input, expected
		t.Run(input, func(t *testing.T) {
			t.Parallel()
			actual, err := NormalizeRoomName(input)
			if err != nil || actual != expected {
				t.Fatalf("NormalizeRoomName(%q) = %q, %v; want %q", input, actual, err, expected)
			}
		})
	}

	invalid := []string{
		"AB", "-ABC", "ABC-", "A B", "A_B", "ÅBC", strings.Repeat("A", MaximumRoomNameBytes+1),
	}
	for _, input := range invalid {
		input := input
		t.Run("invalid_"+input, func(t *testing.T) {
			t.Parallel()
			if _, err := NormalizeRoomName(input); !errors.Is(err, ErrInvalidRoomName) {
				t.Fatalf("NormalizeRoomName(%q) error = %v; want ErrInvalidRoomName", input, err)
			}
		})
	}
}

func TestOwnerTokenRequiresCanonicalThirtyTwoByteBase64URL(t *testing.T) {
	t.Parallel()
	raw := bytes.Repeat([]byte{0xa5}, OwnerTokenBytes)
	encoded := base64.RawURLEncoding.EncodeToString(raw)
	decoded, err := DecodeOwnerToken(encoded)
	if err != nil || !bytes.Equal(decoded[:], raw) {
		t.Fatalf("DecodeOwnerToken() = %x, %v", decoded, err)
	}
	for _, invalid := range []string{
		encoded + "=",
		base64.RawURLEncoding.EncodeToString(raw[:OwnerTokenBytes-1]),
		strings.Repeat("!", len(encoded)),
	} {
		if _, err := DecodeOwnerToken(invalid); !errors.Is(err, ErrInvalidOwnerToken) {
			t.Fatalf("DecodeOwnerToken(%q) error = %v; want ErrInvalidOwnerToken", invalid, err)
		}
	}
}

func TestViewerKeyMustBeP256X963Point(t *testing.T) {
	t.Parallel()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key := elliptic.Marshal(elliptic.P256(), privateKey.X, privateKey.Y)
	encoded := base64.RawURLEncoding.EncodeToString(key)
	if err := ValidateViewerKey(encoded); err != nil {
		t.Fatalf("ValidateViewerKey(valid) = %v", err)
	}
	invalidPoint := make([]byte, P256X963PublicKeyBytes)
	invalidPoint[0] = 4
	if err := ValidateViewerKey(base64.RawURLEncoding.EncodeToString(invalidPoint)); !errors.Is(err, ErrInvalidViewerKey) {
		t.Fatalf("ValidateViewerKey(invalid curve point) = %v", err)
	}
}

func TestNativeRendezvousIDRequiresCanonicalHighEntropyValue(t *testing.T) {
	t.Parallel()
	raw := bytes.Repeat([]byte{0x5a}, NativeRendezvousIDBytes)
	encoded := base64.RawURLEncoding.EncodeToString(raw)
	if err := ValidateNativeRendezvousID(encoded); err != nil {
		t.Fatalf("ValidateNativeRendezvousID(valid) = %v", err)
	}
	for _, invalid := range []string{
		encoded + "=",
		base64.RawURLEncoding.EncodeToString(raw[:NativeRendezvousIDBytes-1]),
		strings.Repeat("!", len(encoded)),
	} {
		if err := ValidateNativeRendezvousID(invalid); !errors.Is(err, ErrInvalidNativeRendezvousID) {
			t.Fatalf("ValidateNativeRendezvousID(%q) = %v", invalid, err)
		}
	}
}

func TestNativeDescriptorAndRelayAreOpaqueCanonicalAndBounded(t *testing.T) {
	t.Parallel()
	descriptor := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, MaximumNativeDescriptorBytes))
	if err := ValidateNativeDescriptor(descriptor); err != nil {
		t.Fatalf("ValidateNativeDescriptor(maximum) = %v", err)
	}
	if err := ValidateNativeDescriptor(""); !errors.Is(err, ErrInvalidNativeDescriptor) {
		t.Fatalf("ValidateNativeDescriptor(empty) = %v", err)
	}
	if err := ValidateNativeDescriptor(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, MaximumNativeDescriptorBytes+1))); !errors.Is(err, ErrInvalidNativeDescriptor) {
		t.Fatalf("ValidateNativeDescriptor(oversized) = %v", err)
	}

	payload := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, MaximumNativeOpaquePayloadBytes))
	routeID := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, RouteIDBytes))
	viewerRelay := Message{
		Type:     MessageNativeRelay,
		Version:  NativeMessageVersion,
		Sequence: 1,
		Payload:  payload,
	}
	if err := ValidateNativeRelay(viewerRelay, false); err != nil {
		t.Fatalf("ValidateNativeRelay(viewer maximum) = %v", err)
	}
	hostRelay := viewerRelay
	hostRelay.RouteID = routeID
	if err := ValidateNativeRelay(hostRelay, true); err != nil {
		t.Fatalf("ValidateNativeRelay(host maximum) = %v", err)
	}
	encoded, err := json.Marshal(hostRelay)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > MaximumMessageBytes {
		t.Fatalf("maximum native relay JSON is %d bytes; outer limit is %d", len(encoded), MaximumMessageBytes)
	}

	invalid := []Message{
		{Type: MessageNativeRelay, Version: NativeMessageVersion, Sequence: 1, Payload: payload, RouteID: routeID},
		{Type: MessageNativeRelay, Version: NativeMessageVersion - 1, Sequence: 1, Payload: payload},
		{Type: MessageNativeRelay, Version: NativeMessageVersion, Sequence: 0, Payload: payload},
		{Type: MessageNativeRelay, Version: NativeMessageVersion, Sequence: 1, Payload: "AA=="},
		{Type: MessageNativeRelay, Version: NativeMessageVersion, Sequence: 1, Payload: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{4}, MaximumNativeOpaquePayloadBytes+1))},
		{Type: MessageNativeRelay, Version: NativeMessageVersion, Sequence: 1, Payload: payload, Ciphertext: "AA"},
	}
	for index, message := range invalid {
		if err := ValidateNativeRelay(message, false); err == nil {
			t.Fatalf("invalid native relay %d was accepted", index)
		}
	}
}

func TestNativeCloseRouteRequiresRoleAppropriateRoute(t *testing.T) {
	t.Parallel()
	routeID := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, RouteIDBytes))
	if err := ValidateNativeCloseRoute(Message{
		Type:    MessageNativeCloseRoute,
		Version: NativeMessageVersion,
		RouteID: routeID,
	}, true); err != nil {
		t.Fatalf("host native close = %v", err)
	}
	if err := ValidateNativeCloseRoute(Message{
		Type:    MessageNativeCloseRoute,
		Version: NativeMessageVersion,
	}, false); err != nil {
		t.Fatalf("viewer native close = %v", err)
	}
	if err := ValidateNativeCloseRoute(Message{
		Type:    MessageNativeCloseRoute,
		Version: NativeMessageVersion,
		RouteID: routeID,
	}, false); err == nil {
		t.Fatal("viewer supplied an explicit native route")
	}
}

func TestValidateRelayEnforcesOpaqueEnvelopeBounds(t *testing.T) {
	t.Parallel()
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, AESGCMNonceBytes))
	ciphertext := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, AESGCMTagBytes))
	routeID := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, RouteIDBytes))

	viewerRelay := Message{Type: MessageRelay, Sequence: 1, Nonce: nonce, Ciphertext: ciphertext}
	if err := ValidateRelay(viewerRelay, false); err != nil {
		t.Fatalf("ValidateRelay(viewer) = %v", err)
	}
	hostRelay := viewerRelay
	hostRelay.RouteID = routeID
	if err := ValidateRelay(hostRelay, true); err != nil {
		t.Fatalf("ValidateRelay(host) = %v", err)
	}

	invalid := []Message{
		{Type: MessageRelay, Sequence: 0, Nonce: nonce, Ciphertext: ciphertext},
		{Type: MessageRelay, Sequence: 1, Nonce: nonce, Ciphertext: ciphertext, RouteID: routeID},
		{Type: MessageRelay, Sequence: 1, Nonce: "AA", Ciphertext: ciphertext},
		{Type: MessageRelay, Sequence: 1, Nonce: nonce, Ciphertext: "AA"},
		{Type: MessageRelay, Sequence: 1, Nonce: nonce, Ciphertext: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{4}, MaximumCiphertextBytes+1))},
		{Type: MessageRelay, Sequence: 1, Nonce: nonce, Ciphertext: ciphertext, Payload: "AA"},
	}
	for index, message := range invalid {
		if err := ValidateRelay(message, false); err == nil {
			t.Fatalf("invalid relay %d was accepted", index)
		}
	}
}

func TestMaximumEncryptedInnerMessageFitsOuterFrame(t *testing.T) {
	t.Parallel()
	message := Message{
		Type:       MessageRelay,
		RouteID:    base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, RouteIDBytes)),
		Sequence:   ^uint64(0),
		Nonce:      base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, AESGCMNonceBytes)),
		Ciphertext: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, MaximumCiphertextBytes)),
	}
	data, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) > MaximumMessageBytes {
		t.Fatalf("maximum relay JSON is %d bytes; outer limit is %d", len(data), MaximumMessageBytes)
	}
	if err := ValidateRelay(message, true); err != nil {
		t.Fatalf("maximum relay was rejected: %v", err)
	}
}

func TestDecodeMessageIsStrictAndBounded(t *testing.T) {
	t.Parallel()
	valid := []byte(`{"type":"host-unavailable"}`)
	message, err := DecodeMessage(valid)
	if err != nil || message.Type != MessageHostUnavailable {
		t.Fatalf("DecodeMessage(valid) = %#v, %v", message, err)
	}
	for _, input := range [][]byte{
		[]byte(`{"type":"host-unavailable","unknown":true}`),
		[]byte(`{"type":"host-unavailable"}{}`),
		bytes.Repeat([]byte(" "), MaximumMessageBytes+1),
	} {
		if _, err := DecodeMessage(input); err == nil {
			t.Fatalf("DecodeMessage accepted invalid payload of %d bytes", len(input))
		}
	}
}

func TestMessageJSONMatchesContract(t *testing.T) {
	t.Parallel()
	message := Message{Type: MessageRouteOpened, RouteID: "route", ViewerKey: "key"}
	data, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"type":"route-opened","routeId":"route","viewerKey":"key"}` {
		t.Fatalf("unexpected JSON: %s", data)
	}
}

func TestErrorMessageRemovesControlCharactersAndBoundsFields(t *testing.T) {
	t.Parallel()
	message := ErrorMessage(strings.Repeat("x", 100)+"\n", strings.Repeat("y", 300)+"\u0000")
	if len(message.Code) != MaximumProtocolErrorCodeBytes || len(message.Text) != MaximumProtocolErrorTextBytes {
		t.Fatalf("unexpected error bounds: %d, %d", len(message.Code), len(message.Text))
	}
	if strings.ContainsAny(message.Code+message.Text, "\n\x00") {
		t.Fatal("error message retained control characters")
	}
}
