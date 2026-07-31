package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
	"github.com/tomas-lejdung/Clip/server/internal/signaling"
)

func testNativeRendezvousID(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, protocol.NativeRendezvousIDBytes))
}

func nativeSessionDescriptor(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 512))
}

func advertiseNative(t *testing.T, serverURL, rendezvousID, token string) *http.Response {
	t.Helper()
	body, err := json.Marshal(protocol.NativeRendezvousRequest{OwnerToken: token})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPut, serverURL+"/api/native/v3/rendezvous/"+rendezvousID, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func dialNativeOwner(t *testing.T, serverURL, rendezvousID, token string) *websocket.Conn {
	t.Helper()
	header := http.Header{}
	header.Set("Authorization", "Bearer "+token)
	connection, response, err := websocket.DefaultDialer.Dial(
		websocketURL(serverURL, "/api/native/v3/rendezvous/"+rendezvousID+"/owner"),
		header,
	)
	if err != nil {
		if response != nil {
			t.Fatalf("native owner websocket status %d: %v", response.StatusCode, err)
		}
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func dialNativeCandidate(t *testing.T, serverURL, rendezvousID string) *websocket.Conn {
	t.Helper()
	connection, response, err := websocket.DefaultDialer.Dial(
		websocketURL(serverURL, "/api/native/v3/rendezvous/"+rendezvousID+"/candidate"),
		nil,
	)
	if err != nil {
		if response != nil {
			t.Fatalf("native candidate websocket status %d: %v", response.StatusCode, err)
		}
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func activateNative(t *testing.T, serverURL, rendezvousID, token, descriptor string) *http.Response {
	t.Helper()
	body, err := json.Marshal(protocol.NativeSessionRequest{Descriptor: descriptor})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(
		http.MethodPut,
		serverURL+"/api/native/v3/rendezvous/"+rendezvousID+"/session",
		bytes.NewReader(body),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func waitNativeState(t *testing.T, serverURL, rendezvousID string, expected signaling.NativeRendezvousState) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		response, err := http.Get(serverURL + "/api/native/v3/rendezvous/" + rendezvousID)
		if err == nil {
			var status protocol.NativeRendezvousStatus
			decodeErr := json.NewDecoder(response.Body).Decode(&status)
			response.Body.Close()
			if decodeErr == nil && response.StatusCode == http.StatusOK && status.State == string(expected) {
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("native rendezvous did not reach state %q", expected)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func nativeRelayEnvelope(sequence uint64, value byte) protocol.Message {
	return protocol.Message{
		Type:     protocol.MessageNativeRelay,
		Version:  protocol.NativeMessageVersion,
		Sequence: sequence,
		Payload:  base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 128)),
	}
}

func TestNativeCapabilitiesOwnershipAndNotLiveGate(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)

	capabilityResponse, err := http.Get(server.URL + "/.well-known/clip-native-rendezvous")
	if err != nil {
		t.Fatal(err)
	}
	capabilityBody, err := io.ReadAll(capabilityResponse.Body)
	if err != nil {
		t.Fatal(err)
	}
	var capabilities protocol.NativeRendezvousCapabilities
	if err := json.Unmarshal(capabilityBody, &capabilities); err != nil {
		t.Fatal(err)
	}
	capabilityResponse.Body.Close()
	if capabilityResponse.StatusCode != http.StatusOK ||
		capabilities.APIVersion != protocol.NativeRendezvousAPIVersion ||
		capabilities.MessageVersion != protocol.NativeMessageVersion ||
		capabilities.RendezvousPathTemplate != "/api/native/v3/rendezvous/{rendezvous}" ||
		capabilities.OwnerWebSocketPathTemplate != "/api/native/v3/rendezvous/{rendezvous}/owner" ||
		capabilities.CandidateWebSocketPathTemplate != "/api/native/v3/rendezvous/{rendezvous}/candidate" {
		t.Fatalf("native capabilities = %d, %#v", capabilityResponse.StatusCode, capabilities)
	}
	var capabilityKeys map[string]json.RawMessage
	if err := json.Unmarshal(capabilityBody, &capabilityKeys); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{
		"ownerWebSocketPathTemplate",
		"candidateWebSocketPathTemplate",
	} {
		if _, found := capabilityKeys[key]; !found {
			t.Fatalf("native capabilities omitted %q", key)
		}
	}
	for _, legacyKey := range []string{
		"hostWebSocketPathTemplate",
		"viewerWebSocketPathTemplate",
	} {
		if _, found := capabilityKeys[legacyKey]; found {
			t.Fatalf("native capabilities retained legacy key %q", legacyKey)
		}
	}

	rendezvousID := testNativeRendezvousID(1)
	token := ownerToken(31)
	response := advertiseNative(t, server.URL, rendezvousID, token)
	var created protocol.NativeRendezvousResponse
	if err := json.NewDecoder(response.Body).Decode(&created); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusCreated || created.RendezvousID != rendezvousID {
		t.Fatalf("native create = %d, %#v", response.StatusCode, created)
	}
	response = advertiseNative(t, server.URL, rendezvousID, token)
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("native renewal = %d", response.StatusCode)
	}
	response = advertiseNative(t, server.URL, rendezvousID, ownerToken(32))
	response.Body.Close()
	if response.StatusCode != http.StatusConflict {
		t.Fatalf("native owner conflict = %d", response.StatusCode)
	}
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousOffline)

	response = activateNative(t, server.URL, rendezvousID, token, nativeSessionDescriptor(2))
	response.Body.Close()
	if response.StatusCode != http.StatusConflict {
		t.Fatalf("activate while offline = %d", response.StatusCode)
	}

	_, candidateResponse, err := websocket.DefaultDialer.Dial(
		websocketURL(server.URL, "/api/native/v3/rendezvous/"+rendezvousID+"/candidate"),
		nil,
	)
	if err == nil {
		t.Fatal("native candidate reached admission before activation")
	}
	if candidateResponse == nil || candidateResponse.StatusCode != http.StatusConflict {
		t.Fatalf("not-live candidate response = %#v, %v", candidateResponse, err)
	}
	candidateResponse.Body.Close()

	ownerConnection := dialNativeOwner(t, server.URL, rendezvousID, token)
	_ = ownerConnection
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousPreparing)
}

func TestNativeWebSocketRoutesOpaqueMessagesAndStopIsAtomic(t *testing.T) {
	_, server := newHTTPTestServer(t)
	rendezvousID := testNativeRendezvousID(3)
	token := ownerToken(33)
	response := advertiseNative(t, server.URL, rendezvousID, token)
	response.Body.Close()
	ownerConnection := dialNativeOwner(t, server.URL, rendezvousID, token)
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousPreparing)
	descriptor := nativeSessionDescriptor(4)
	response = activateNative(t, server.URL, rendezvousID, token, descriptor)
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("activate status = %d", response.StatusCode)
	}
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousActive)

	candidateConnection := dialNativeCandidate(t, server.URL, rendezvousID)
	var candidateOpened protocol.Message
	if err := candidateConnection.ReadJSON(&candidateOpened); err != nil {
		t.Fatal(err)
	}
	var ownerOpened protocol.Message
	if err := ownerConnection.ReadJSON(&ownerOpened); err != nil {
		t.Fatal(err)
	}
	if candidateOpened.Type != protocol.MessageNativeRouteOpened || candidateOpened.Payload != descriptor || candidateOpened.RouteID == "" {
		t.Fatalf("native candidate route-opened = %#v", candidateOpened)
	}
	if ownerOpened.Type != protocol.MessageNativeRouteOpened || ownerOpened.Payload != "" || ownerOpened.RouteID != candidateOpened.RouteID {
		t.Fatalf("native owner route-opened = %#v", ownerOpened)
	}

	candidateRelay := nativeRelayEnvelope(1, 5)
	if err := candidateConnection.WriteJSON(candidateRelay); err != nil {
		t.Fatal(err)
	}
	var ownerReceived protocol.Message
	if err := ownerConnection.ReadJSON(&ownerReceived); err != nil {
		t.Fatal(err)
	}
	if ownerReceived.Payload != candidateRelay.Payload || ownerReceived.RouteID != candidateOpened.RouteID {
		t.Fatalf("owner received = %#v", ownerReceived)
	}
	ownerRelay := nativeRelayEnvelope(1, 6)
	ownerRelay.RouteID = candidateOpened.RouteID
	if err := ownerConnection.WriteJSON(ownerRelay); err != nil {
		t.Fatal(err)
	}
	var candidateReceived protocol.Message
	if err := candidateConnection.ReadJSON(&candidateReceived); err != nil {
		t.Fatal(err)
	}
	if candidateReceived != ownerRelay {
		t.Fatalf("candidate received = %#v", candidateReceived)
	}

	request, _ := http.NewRequest(
		http.MethodDelete,
		server.URL+"/api/native/v3/rendezvous/"+rendezvousID+"/session",
		nil,
	)
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("deactivate status = %d", response.StatusCode)
	}
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousPreparing)
	_ = candidateConnection.SetReadDeadline(time.Now().Add(time.Second))
	var stopped protocol.Message
	if err := candidateConnection.ReadJSON(&stopped); err != nil || stopped.Type != protocol.MessageNativeRouteClosed {
		t.Fatalf("deactivate notice = %#v, %v", stopped, err)
	}
	if _, _, err := candidateConnection.ReadMessage(); err == nil {
		t.Fatal("deactivate sent a notice but left native candidate route open")
	}
	_, candidateResponse, err := websocket.DefaultDialer.Dial(
		websocketURL(server.URL, "/api/native/v3/rendezvous/"+rendezvousID+"/candidate"),
		nil,
	)
	if err == nil || candidateResponse == nil || candidateResponse.StatusCode != http.StatusConflict {
		t.Fatalf("candidate admitted after stop = %#v, %v", candidateResponse, err)
	}
	candidateResponse.Body.Close()
}

func TestNativeMalformedPayloadsAreRejected(t *testing.T) {
	_, server := newHTTPTestServer(t)
	invalidResponse := advertiseNative(t, server.URL, "short", ownerToken(34))
	invalidResponse.Body.Close()
	if invalidResponse.StatusCode != http.StatusBadRequest {
		t.Fatalf("invalid native identifier status = %d", invalidResponse.StatusCode)
	}

	rendezvousID := testNativeRendezvousID(7)
	token := ownerToken(35)
	request, _ := http.NewRequest(
		http.MethodPut,
		server.URL+"/api/native/v3/rendezvous/"+rendezvousID,
		bytes.NewBufferString(`{"ownerToken":"`+token+`","participantName":"must-not-be-stored"}`),
	)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("unknown native owner field status = %d", response.StatusCode)
	}
	response = advertiseNative(t, server.URL, rendezvousID, token)
	response.Body.Close()
	ownerConnection := dialNativeOwner(t, server.URL, rendezvousID, token)
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousPreparing)
	response = activateNative(t, server.URL, rendezvousID, token, nativeSessionDescriptor(8))
	response.Body.Close()
	candidateConnection := dialNativeCandidate(t, server.URL, rendezvousID)
	var opened protocol.Message
	_ = candidateConnection.ReadJSON(&opened)
	var ownerOpened protocol.Message
	_ = ownerConnection.ReadJSON(&ownerOpened)
	if err := candidateConnection.WriteJSON(map[string]any{
		"type":     protocol.MessageNativeRelay,
		"version":  protocol.NativeMessageVersion,
		"sequence": 1,
		"payload":  "AA==",
	}); err != nil {
		t.Fatal(err)
	}
	var nativeError protocol.Message
	if err := candidateConnection.ReadJSON(&nativeError); err != nil {
		t.Fatal(err)
	}
	if nativeError.Type != protocol.MessageNativeError || nativeError.Code != "protocol_error" {
		t.Fatalf("malformed native relay response = %#v", nativeError)
	}
}

func TestNativeDeleteRemovesRendezvousAndClosesOwner(t *testing.T) {
	_, server := newHTTPTestServer(t)
	rendezvousID := testNativeRendezvousID(9)
	token := ownerToken(37)
	response := advertiseNative(t, server.URL, rendezvousID, token)
	response.Body.Close()
	ownerConnection := dialNativeOwner(t, server.URL, rendezvousID, token)
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousPreparing)

	request, _ := http.NewRequest(http.MethodDelete, server.URL+"/api/native/v3/rendezvous/"+rendezvousID, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("native delete = %d", response.StatusCode)
	}
	_ = ownerConnection.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := ownerConnection.ReadMessage(); err == nil {
		t.Fatal("native delete left owner open")
	}
	statusResponse, err := http.Get(server.URL + "/api/native/v3/rendezvous/" + rendezvousID)
	if err != nil {
		t.Fatal(err)
	}
	statusResponse.Body.Close()
	if statusResponse.StatusCode != http.StatusNotFound {
		t.Fatalf("status after native delete = %d", statusResponse.StatusCode)
	}
}
