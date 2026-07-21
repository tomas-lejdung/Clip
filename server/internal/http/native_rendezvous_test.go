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
	request, err := http.NewRequest(http.MethodPut, serverURL+"/api/native/v1/rendezvous/"+rendezvousID, bytes.NewReader(body))
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

func dialNativeHost(t *testing.T, serverURL, rendezvousID, token string) *websocket.Conn {
	t.Helper()
	header := http.Header{}
	header.Set("Authorization", "Bearer "+token)
	connection, response, err := websocket.DefaultDialer.Dial(
		websocketURL(serverURL, "/api/native/v1/rendezvous/"+rendezvousID+"/host"),
		header,
	)
	if err != nil {
		if response != nil {
			t.Fatalf("native host websocket status %d: %v", response.StatusCode, err)
		}
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func dialNativeViewer(t *testing.T, serverURL, rendezvousID string) *websocket.Conn {
	t.Helper()
	connection, response, err := websocket.DefaultDialer.Dial(
		websocketURL(serverURL, "/api/native/v1/rendezvous/"+rendezvousID+"/viewer"),
		nil,
	)
	if err != nil {
		if response != nil {
			t.Fatalf("native viewer websocket status %d: %v", response.StatusCode, err)
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
		serverURL+"/api/native/v1/rendezvous/"+rendezvousID+"/session",
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
		response, err := http.Get(serverURL + "/api/native/v1/rendezvous/" + rendezvousID)
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
	var capabilities protocol.NativeRendezvousCapabilities
	if err := json.NewDecoder(capabilityResponse.Body).Decode(&capabilities); err != nil {
		t.Fatal(err)
	}
	capabilityResponse.Body.Close()
	if capabilityResponse.StatusCode != http.StatusOK || capabilities.APIVersion != 1 || capabilities.MessageVersion != protocol.NativeMessageVersion {
		t.Fatalf("native capabilities = %d, %#v", capabilityResponse.StatusCode, capabilities)
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

	_, viewerResponse, err := websocket.DefaultDialer.Dial(
		websocketURL(server.URL, "/api/native/v1/rendezvous/"+rendezvousID+"/viewer"),
		nil,
	)
	if err == nil {
		t.Fatal("native viewer reached admission before activation")
	}
	if viewerResponse == nil || viewerResponse.StatusCode != http.StatusConflict {
		t.Fatalf("not-live viewer response = %#v, %v", viewerResponse, err)
	}
	viewerResponse.Body.Close()

	host := dialNativeHost(t, server.URL, rendezvousID, token)
	_ = host
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousPreparing)
}

func TestNativeWebSocketRoutesOpaqueMessagesAndStopIsAtomic(t *testing.T) {
	_, server := newHTTPTestServer(t)
	rendezvousID := testNativeRendezvousID(3)
	token := ownerToken(33)
	response := advertiseNative(t, server.URL, rendezvousID, token)
	response.Body.Close()
	host := dialNativeHost(t, server.URL, rendezvousID, token)
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousPreparing)
	descriptor := nativeSessionDescriptor(4)
	response = activateNative(t, server.URL, rendezvousID, token, descriptor)
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("activate status = %d", response.StatusCode)
	}
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousActive)

	viewer := dialNativeViewer(t, server.URL, rendezvousID)
	var viewerOpened protocol.Message
	if err := viewer.ReadJSON(&viewerOpened); err != nil {
		t.Fatal(err)
	}
	var hostOpened protocol.Message
	if err := host.ReadJSON(&hostOpened); err != nil {
		t.Fatal(err)
	}
	if viewerOpened.Type != protocol.MessageNativeRouteOpened || viewerOpened.Payload != descriptor || viewerOpened.RouteID == "" {
		t.Fatalf("native viewer route-opened = %#v", viewerOpened)
	}
	if hostOpened.Type != protocol.MessageNativeRouteOpened || hostOpened.Payload != "" || hostOpened.RouteID != viewerOpened.RouteID {
		t.Fatalf("native host route-opened = %#v", hostOpened)
	}

	viewerRelay := nativeRelayEnvelope(1, 5)
	if err := viewer.WriteJSON(viewerRelay); err != nil {
		t.Fatal(err)
	}
	var hostReceived protocol.Message
	if err := host.ReadJSON(&hostReceived); err != nil {
		t.Fatal(err)
	}
	if hostReceived.Payload != viewerRelay.Payload || hostReceived.RouteID != viewerOpened.RouteID {
		t.Fatalf("host received = %#v", hostReceived)
	}
	hostRelay := nativeRelayEnvelope(1, 6)
	hostRelay.RouteID = viewerOpened.RouteID
	if err := host.WriteJSON(hostRelay); err != nil {
		t.Fatal(err)
	}
	var viewerReceived protocol.Message
	if err := viewer.ReadJSON(&viewerReceived); err != nil {
		t.Fatal(err)
	}
	if viewerReceived != hostRelay {
		t.Fatalf("viewer received = %#v", viewerReceived)
	}

	request, _ := http.NewRequest(
		http.MethodDelete,
		server.URL+"/api/native/v1/rendezvous/"+rendezvousID+"/session",
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
	_ = viewer.SetReadDeadline(time.Now().Add(time.Second))
	var stopped protocol.Message
	if err := viewer.ReadJSON(&stopped); err != nil || stopped.Type != protocol.MessageNativeRouteClosed {
		t.Fatalf("deactivate notice = %#v, %v", stopped, err)
	}
	if _, _, err := viewer.ReadMessage(); err == nil {
		t.Fatal("deactivate sent a notice but left native viewer route open")
	}
	_, viewerResponse, err := websocket.DefaultDialer.Dial(
		websocketURL(server.URL, "/api/native/v1/rendezvous/"+rendezvousID+"/viewer"),
		nil,
	)
	if err == nil || viewerResponse == nil || viewerResponse.StatusCode != http.StatusConflict {
		t.Fatalf("viewer admitted after stop = %#v, %v", viewerResponse, err)
	}
	viewerResponse.Body.Close()
}

func TestNativeMalformedPayloadsAreRejectedWithoutChangingBrowserV1(t *testing.T) {
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
		server.URL+"/api/native/v1/rendezvous/"+rendezvousID,
		bytes.NewBufferString(`{"ownerToken":"`+token+`","friendName":"must-not-be-stored"}`),
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
	host := dialNativeHost(t, server.URL, rendezvousID, token)
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousPreparing)
	response = activateNative(t, server.URL, rendezvousID, token, nativeSessionDescriptor(8))
	response.Body.Close()
	viewer := dialNativeViewer(t, server.URL, rendezvousID)
	var opened protocol.Message
	_ = viewer.ReadJSON(&opened)
	var hostOpened protocol.Message
	_ = host.ReadJSON(&hostOpened)
	if err := viewer.WriteJSON(map[string]any{
		"type":     protocol.MessageNativeRelay,
		"version":  protocol.NativeMessageVersion,
		"sequence": 1,
		"payload":  "AA==",
	}); err != nil {
		t.Fatal(err)
	}
	var nativeError protocol.Message
	if err := viewer.ReadJSON(&nativeError); err != nil {
		t.Fatal(err)
	}
	if nativeError.Type != protocol.MessageNativeError || nativeError.Code != "protocol_error" {
		t.Fatalf("malformed native relay response = %#v", nativeError)
	}

	// The original browser v1 surface remains independently functional.
	roomToken := ownerToken(36)
	roomResponse := advertise(t, server.URL, "COEXIST-ROOM", roomToken)
	roomResponse.Body.Close()
	if roomResponse.StatusCode != http.StatusCreated {
		t.Fatalf("browser room create = %d", roomResponse.StatusCode)
	}
	browserHost := dialHost(t, server.URL, "COEXIST-ROOM", roomToken)
	browserViewer := dialViewer(t, server.URL, "COEXIST-ROOM")
	routeID := openRoute(t, browserHost, browserViewer)
	relay := relayEnvelope(1)
	if err := browserViewer.WriteJSON(relay); err != nil {
		t.Fatal(err)
	}
	var received protocol.Message
	if err := browserHost.ReadJSON(&received); err != nil {
		t.Fatal(err)
	}
	if received.Type != protocol.MessageRelay || received.RouteID != routeID {
		t.Fatalf("browser relay after native use = %#v", received)
	}
}

func TestNativeDeleteRemovesRendezvousAndClosesHost(t *testing.T) {
	_, server := newHTTPTestServer(t)
	rendezvousID := testNativeRendezvousID(9)
	token := ownerToken(37)
	response := advertiseNative(t, server.URL, rendezvousID, token)
	response.Body.Close()
	host := dialNativeHost(t, server.URL, rendezvousID, token)
	waitNativeState(t, server.URL, rendezvousID, signaling.NativeRendezvousPreparing)

	request, _ := http.NewRequest(http.MethodDelete, server.URL+"/api/native/v1/rendezvous/"+rendezvousID, nil)
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
	_ = host.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := host.ReadMessage(); err == nil {
		t.Fatal("native delete left host open")
	}
	statusResponse, err := http.Get(server.URL + "/api/native/v1/rendezvous/" + rendezvousID)
	if err != nil {
		t.Fatal(err)
	}
	statusResponse.Body.Close()
	if statusResponse.StatusCode != http.StatusNotFound {
		t.Fatalf("status after native delete = %d", statusResponse.StatusCode)
	}
}
