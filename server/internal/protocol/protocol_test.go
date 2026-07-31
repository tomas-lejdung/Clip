package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

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
			t.Fatalf("DecodeOwnerToken(%q) error = %v", invalid, err)
		}
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
		if err := ValidateNativeRendezvousID(invalid); !errors.Is(
			err,
			ErrInvalidNativeRendezvousID,
		) {
			t.Fatalf("ValidateNativeRendezvousID(%q) = %v", invalid, err)
		}
	}
}

func TestNativeDescriptorAndRelayAreOpaqueCanonicalAndBounded(t *testing.T) {
	t.Parallel()
	descriptor := base64.RawURLEncoding.EncodeToString(
		bytes.Repeat([]byte{1}, MaximumNativeDescriptorBytes),
	)
	if err := ValidateNativeDescriptor(descriptor); err != nil {
		t.Fatalf("ValidateNativeDescriptor(maximum) = %v", err)
	}
	if err := ValidateNativeDescriptor(""); !errors.Is(
		err,
		ErrInvalidNativeDescriptor,
	) {
		t.Fatalf("ValidateNativeDescriptor(empty) = %v", err)
	}

	payload := base64.RawURLEncoding.EncodeToString(
		bytes.Repeat([]byte{2}, MaximumNativeOpaquePayloadBytes),
	)
	routeID := base64.RawURLEncoding.EncodeToString(
		bytes.Repeat([]byte{3}, RouteIDBytes),
	)
	candidateRelay := Message{
		Type:     MessageNativeRelay,
		Version:  NativeMessageVersion,
		Sequence: 1,
		Payload:  payload,
	}
	if err := ValidateNativeRelay(candidateRelay, false); err != nil {
		t.Fatalf("ValidateNativeRelay(candidate maximum) = %v", err)
	}
	ownerRelay := candidateRelay
	ownerRelay.RouteID = routeID
	if err := ValidateNativeRelay(ownerRelay, true); err != nil {
		t.Fatalf("ValidateNativeRelay(owner maximum) = %v", err)
	}
	encoded, err := json.Marshal(ownerRelay)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > MaximumMessageBytes {
		t.Fatalf(
			"maximum native relay JSON is %d bytes; outer limit is %d",
			len(encoded),
			MaximumMessageBytes,
		)
	}

	invalidJSON := `{"type":"native-relay","version":3,"sequence":1,` +
		`"payload":"AA","ciphertext":"legacy"}`
	if _, err := DecodeMessage([]byte(invalidJSON)); !errors.Is(
		err,
		ErrInvalidMessage,
	) {
		t.Fatalf("legacy envelope field was accepted: %v", err)
	}

	invalid := []Message{
		{
			Type: MessageNativeRelay, Version: NativeMessageVersion,
			Sequence: 1, Payload: payload, RouteID: routeID,
		},
		{
			Type: MessageNativeRelay, Version: NativeMessageVersion - 1,
			Sequence: 1, Payload: payload,
		},
		{
			Type: MessageNativeRelay, Version: NativeMessageVersion,
			Sequence: 0, Payload: payload,
		},
		{
			Type: MessageNativeRelay, Version: NativeMessageVersion,
			Sequence: 1, Payload: "AA==",
		},
	}
	for index, message := range invalid {
		if err := ValidateNativeRelay(message, false); err == nil {
			t.Fatalf("invalid native relay %d was accepted", index)
		}
	}
}

func TestNativeCloseRouteRequiresRoleAppropriateRoute(t *testing.T) {
	t.Parallel()
	routeID := base64.RawURLEncoding.EncodeToString(
		bytes.Repeat([]byte{9}, RouteIDBytes),
	)
	if err := ValidateNativeCloseRoute(Message{
		Type:    MessageNativeCloseRoute,
		Version: NativeMessageVersion,
		RouteID: routeID,
	}, true); err != nil {
		t.Fatalf("owner native close = %v", err)
	}
	if err := ValidateNativeCloseRoute(Message{
		Type:    MessageNativeCloseRoute,
		Version: NativeMessageVersion,
	}, false); err != nil {
		t.Fatalf("candidate native close = %v", err)
	}
	if err := ValidateNativeCloseRoute(Message{
		Type:    MessageNativeCloseRoute,
		Version: NativeMessageVersion,
		RouteID: routeID,
	}, false); err == nil {
		t.Fatal("candidate supplied an explicit native route")
	}
}

func TestStrictJSONRejectsUnknownAndTrailingValues(t *testing.T) {
	t.Parallel()
	for _, input := range []string{
		`{"ownerToken":"value","legacy":true}`,
		`{"ownerToken":"value"} {"ownerToken":"other"}`,
	} {
		var request NativeRendezvousRequest
		if err := DecodeStrictJSON(
			strings.NewReader(input),
			1_024,
			&request,
		); err == nil {
			t.Fatalf("accepted %q", input)
		}
	}
}
