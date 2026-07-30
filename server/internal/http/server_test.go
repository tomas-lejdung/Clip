package httpapi

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/config"
	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

func testConfiguration() config.Config {
	configuration := config.Default("test-version")
	configuration.LeaseDuration = 2 * time.Minute
	configuration.ReconnectGrace = time.Second
	configuration.CleanupInterval = 100 * time.Millisecond
	configuration.HelloTimeout = 2 * time.Second
	configuration.ReadTimeout = 5 * time.Second
	configuration.WriteTimeout = 2 * time.Second
	configuration.PingInterval = time.Second
	configuration.RouteIdleTimeout = 10 * time.Second
	configuration.ShutdownTimeout = 2 * time.Second
	configuration.MaximumRooms = 32
	configuration.MaximumConnections = 64
	configuration.ReservedHostConnections = 8
	return configuration
}

func newHTTPTestServer(t *testing.T) (*Service, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	service, err := New(testConfiguration(), logger)
	if err != nil {
		t.Fatal(err)
	}
	testServer := httptest.NewServer(service.Handler())
	t.Cleanup(func() {
		testServer.Close()
		service.Close()
	})
	return service, testServer
}

func ownerToken(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, protocol.OwnerTokenBytes))
}

func allocateRoom(t *testing.T, serverURL, token string) (protocol.RoomResponse, int) {
	t.Helper()
	body, err := json.Marshal(protocol.OwnerRequest{OwnerToken: token})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, serverURL+"/api/v1/rooms", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var lease protocol.RoomResponse
	if response.StatusCode == http.StatusCreated || response.StatusCode == http.StatusOK {
		if err := json.NewDecoder(response.Body).Decode(&lease); err != nil {
			t.Fatal(err)
		}
	}
	return lease, response.StatusCode
}

func renewRoom(t *testing.T, serverURL, room, token string) *http.Response {
	t.Helper()
	request, err := http.NewRequest(http.MethodPut, serverURL+"/api/v1/rooms/"+room, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func websocketURL(serverURL, path string) string {
	return "ws" + strings.TrimPrefix(serverURL, "http") + path
}

func dialHost(t *testing.T, serverURL, room, token string) *websocket.Conn {
	t.Helper()
	header := http.Header{}
	header.Set("Authorization", "Bearer "+token)
	connection, response, err := websocket.DefaultDialer.Dial(websocketURL(serverURL, "/api/v1/rooms/"+room+"/host"), header)
	if err != nil {
		if response != nil {
			t.Fatalf("host websocket status %d: %v", response.StatusCode, err)
		}
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func viewerKey(t *testing.T) string {
	t.Helper()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), privateKey.X, privateKey.Y))
}

func dialViewer(t *testing.T, serverURL, room string) *websocket.Conn {
	t.Helper()
	connection, response, err := websocket.DefaultDialer.Dial(websocketURL(serverURL, "/api/v1/rooms/"+room+"/viewer"), nil)
	if err != nil {
		if response != nil {
			t.Fatalf("viewer websocket status %d: %v", response.StatusCode, err)
		}
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func openRoute(t *testing.T, host, viewer *websocket.Conn) string {
	t.Helper()
	if err := viewer.WriteJSON(protocol.Message{Type: protocol.MessageViewerHello, Version: protocol.Version, ViewerKey: viewerKey(t)}); err != nil {
		t.Fatal(err)
	}
	var viewerOpened protocol.Message
	if err := viewer.ReadJSON(&viewerOpened); err != nil {
		t.Fatal(err)
	}
	var hostOpened protocol.Message
	if err := host.ReadJSON(&hostOpened); err != nil {
		t.Fatal(err)
	}
	if viewerOpened.Type != protocol.MessageRouteOpened || hostOpened.Type != protocol.MessageRouteOpened {
		t.Fatalf("route open messages = viewer:%#v host:%#v", viewerOpened, hostOpened)
	}
	if viewerOpened.RouteID == "" || viewerOpened.RouteID != hostOpened.RouteID || viewerOpened.ViewerKey != "" || hostOpened.ViewerKey == "" {
		t.Fatalf("route open contract = viewer:%#v host:%#v", viewerOpened, hostOpened)
	}
	return viewerOpened.RouteID
}

func relayEnvelope(sequence uint64) protocol.Message {
	return protocol.Message{
		Type:       protocol.MessageRelay,
		Sequence:   sequence,
		Nonce:      base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, protocol.AESGCMNonceBytes)),
		Ciphertext: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{8}, protocol.AESGCMTagBytes)),
	}
}

func TestCapabilitiesViewerAndSecurityHeaders(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)

	response, err := http.Get(server.URL + "/.well-known/clip-live-share")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var capabilities protocol.Capabilities
	if err := json.NewDecoder(response.Body).Decode(&capabilities); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK || capabilities.Protocol != protocol.Identifier || capabilities.ServerVersion != "test-version" {
		t.Fatalf("capabilities status/body = %d, %#v", response.StatusCode, capabilities)
	}
	if capabilities.Limits.MaximumMessageBytes != protocol.MaximumMessageBytes || capabilities.Limits.MaximumPendingViewersPerRoom != 8 {
		t.Fatalf("capability limits = %#v", capabilities.Limits)
	}
	if !strings.Contains(response.Header.Get("Content-Security-Policy"), "stun: stuns: turn: turns:") {
		t.Fatalf("CSP does not permit configured ICE schemes: %s", response.Header.Get("Content-Security-Policy"))
	}

	viewerResponse, err := http.Get(server.URL + "/crisp-frog-042")
	if err != nil {
		t.Fatal(err)
	}
	viewerBody, _ := io.ReadAll(viewerResponse.Body)
	viewerResponse.Body.Close()
	if viewerResponse.StatusCode != http.StatusOK || !bytes.Contains(viewerBody, []byte("clip-viewer.js")) {
		t.Fatalf("viewer response = %d, %d bytes", viewerResponse.StatusCode, len(viewerBody))
	}
	if !bytes.Contains(viewerBody, []byte(`class="pan-zoom-content native-mode"`)) ||
		!bytes.Contains(viewerBody, []byte(`class="main-video scale-native"`)) ||
		!bytes.Contains(viewerBody, []byte(`class="scale-btn active" data-scale="native"`)) {
		t.Fatal("viewer does not render Native as the default scale mode")
	}
	assetResponse, err := http.Get(server.URL + "/assets/clip-protocol.js")
	if err != nil {
		t.Fatal(err)
	}
	assetResponse.Body.Close()
	if assetResponse.StatusCode != http.StatusOK || !strings.Contains(assetResponse.Header.Get("Content-Type"), "javascript") {
		t.Fatalf("asset response = %d, %q", assetResponse.StatusCode, assetResponse.Header.Get("Content-Type"))
	}
	mediaAssetResponse, err := http.Get(server.URL + "/assets/clip-media.js")
	if err != nil {
		t.Fatal(err)
	}
	mediaAssetResponse.Body.Close()
	if mediaAssetResponse.StatusCode != http.StatusOK || !strings.Contains(mediaAssetResponse.Header.Get("Content-Type"), "javascript") {
		t.Fatalf("media asset response = %d, %q", mediaAssetResponse.StatusCode, mediaAssetResponse.Header.Get("Content-Type"))
	}
	viewerAssetResponse, err := http.Get(server.URL + "/assets/clip-viewer.js")
	if err != nil {
		t.Fatal(err)
	}
	viewerAssetBody, _ := io.ReadAll(viewerAssetResponse.Body)
	viewerAssetResponse.Body.Close()
	if viewerAssetResponse.StatusCode != http.StatusOK ||
		!bytes.Contains(viewerAssetBody, []byte(`let currentScale = "native";`)) {
		t.Fatal("viewer script does not initialize Native as the default scale mode")
	}
	fixtureResponse, err := http.Get(server.URL + "/assets/clip-protocol-tests.html")
	if err != nil {
		t.Fatal(err)
	}
	fixtureResponse.Body.Close()
	if fixtureResponse.StatusCode != http.StatusNotFound {
		t.Fatalf("browser test fixture was served in production: %d", fixtureResponse.StatusCode)
	}
}

func TestRoomAllocationRenewalOwnershipAndDeletion(t *testing.T) {
	t.Parallel()
	service, server := newHTTPTestServer(t)
	generatedNames := []string{
		"CRISP-FROG-042",
		"BRIGHT-OWL-999",
		"CRISP-FROG-042",
		"CALM-OTTER-007",
	}
	service.roomNameGenerator = func() (string, error) {
		name := generatedNames[0]
		generatedNames = generatedNames[1:]
		return name, nil
	}
	token := ownerToken(1)
	created, status := allocateRoom(t, server.URL, token)
	if status != http.StatusCreated || created.Room != "CRISP-FROG-042" || created.LeaseDurationSeconds != 120 {
		t.Fatalf("created response = %d, %#v", status, created)
	}

	repeated, status := allocateRoom(t, server.URL, token)
	if status != http.StatusOK || repeated.Room != created.Room {
		t.Fatalf("idempotent allocation response = %d, %#v", status, repeated)
	}

	second, status := allocateRoom(t, server.URL, ownerToken(3))
	if status != http.StatusCreated || second.Room != "CALM-OTTER-007" {
		t.Fatalf("collision retry response = %d, %#v", status, second)
	}

	response := renewRoom(t, server.URL, created.Room, token)
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("renewal status = %d", response.StatusCode)
	}
	response = renewRoom(t, server.URL, created.Room, ownerToken(2))
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong-owner renewal status = %d", response.StatusCode)
	}
	response = renewRoom(t, server.URL, "BRIGHT-OWL-999", token)
	response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown-room renewal status = %d", response.StatusCode)
	}

	request, _ := http.NewRequest(http.MethodDelete, server.URL+"/api/v1/rooms/"+created.Room, nil)
	request.Header.Set("Authorization", "Bearer "+ownerToken(2))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong-owner delete status = %d", response.StatusCode)
	}
	request, _ = http.NewRequest(http.MethodDelete, server.URL+"/api/v1/rooms/"+created.Room, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("owner delete status = %d", response.StatusCode)
	}
}

func TestRoomAllocationRejectsClientSelectedNamesAndViewerSecrets(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)
	token := ownerToken(2)

	body := fmt.Sprintf(`{"ownerToken":%q}`, token)
	request, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/api/v1/rooms/CLIENT-CHOICE-001",
		strings.NewReader(body),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("client-selected allocation status = %d", response.StatusCode)
	}

	body = fmt.Sprintf(
		`{"ownerToken":%q,"joinCapability":%q}`,
		token,
		base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32)),
	)
	response, err = http.Post(
		server.URL+"/api/v1/rooms",
		"application/json",
		strings.NewReader(body),
	)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("server-visible join capability status = %d", response.StatusCode)
	}

	response = renewRoom(t, server.URL, "CLIENT-CHOICE-001", token)
	response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("renewal created a client-selected room: %d", response.StatusCode)
	}
}

func TestWebSocketRoutesOpaqueRelaysBothDirections(t *testing.T) {
	_, server := newHTTPTestServer(t)
	token := ownerToken(3)
	lease, status := allocateRoom(t, server.URL, token)
	if status != http.StatusCreated {
		t.Fatalf("allocation status = %d", status)
	}
	host := dialHost(t, server.URL, lease.Room, token)
	viewer := dialViewer(t, server.URL, lease.Room)
	routeID := openRoute(t, host, viewer)

	viewerRelay := relayEnvelope(1)
	if err := viewer.WriteJSON(viewerRelay); err != nil {
		t.Fatal(err)
	}
	var hostReceived protocol.Message
	if err := host.ReadJSON(&hostReceived); err != nil {
		t.Fatal(err)
	}
	if hostReceived.RouteID != routeID || hostReceived.Ciphertext != viewerRelay.Ciphertext {
		t.Fatalf("host received = %#v", hostReceived)
	}

	hostRelay := relayEnvelope(1)
	hostRelay.RouteID = routeID
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
}

func TestLateRouteRelayDoesNotDisconnectHostOrOtherRoutes(t *testing.T) {
	_, server := newHTTPTestServer(t)
	token := ownerToken(4)
	lease, status := allocateRoom(t, server.URL, token)
	if status != http.StatusCreated {
		t.Fatalf("allocation status = %d", status)
	}
	host := dialHost(t, server.URL, lease.Room, token)
	viewerOne := dialViewer(t, server.URL, lease.Room)
	routeOne := openRoute(t, host, viewerOne)
	if err := viewerOne.WriteJSON(protocol.Message{Type: protocol.MessageCloseRoute, RouteID: routeOne}); err != nil {
		t.Fatal(err)
	}
	var closed protocol.Message
	if err := host.ReadJSON(&closed); err != nil || closed.Type != protocol.MessageRouteClosed {
		t.Fatalf("route close = %#v, %v", closed, err)
	}

	late := relayEnvelope(1)
	late.RouteID = routeOne
	if err := host.WriteJSON(late); err != nil {
		t.Fatal(err)
	}
	var routeError protocol.Message
	if err := host.ReadJSON(&routeError); err != nil {
		t.Fatal(err)
	}
	if routeError.Type != protocol.MessageError || routeError.Code != "route_unavailable" {
		t.Fatalf("late relay result = %#v", routeError)
	}

	viewerTwo := dialViewer(t, server.URL, lease.Room)
	routeTwo := openRoute(t, host, viewerTwo)
	secondRelay := relayEnvelope(1)
	if err := viewerTwo.WriteJSON(secondRelay); err != nil {
		t.Fatal(err)
	}
	var forwarded protocol.Message
	if err := host.ReadJSON(&forwarded); err != nil {
		t.Fatalf("host was disconnected by stale route: %v", err)
	}
	if forwarded.Type != protocol.MessageRelay || forwarded.RouteID != routeTwo {
		t.Fatalf("second route relay = %#v", forwarded)
	}
}

func TestSequenceFailureClosesOnlyAffectedRoute(t *testing.T) {
	_, server := newHTTPTestServer(t)
	token := ownerToken(5)
	lease, status := allocateRoom(t, server.URL, token)
	if status != http.StatusCreated {
		t.Fatalf("allocation status = %d", status)
	}
	host := dialHost(t, server.URL, lease.Room, token)
	viewer := dialViewer(t, server.URL, lease.Room)
	routeID := openRoute(t, host, viewer)
	skipped := relayEnvelope(2)
	skipped.RouteID = routeID
	if err := host.WriteJSON(skipped); err != nil {
		t.Fatal(err)
	}
	var routeError protocol.Message
	if err := host.ReadJSON(&routeError); err != nil {
		t.Fatal(err)
	}
	if routeError.Type != protocol.MessageError || routeError.Code != "route_sequence_rejected" {
		t.Fatalf("sequence result = %#v", routeError)
	}

	secondViewer := dialViewer(t, server.URL, lease.Room)
	_ = openRoute(t, host, secondViewer)
}

func TestHostUnavailableAndOriginPolicy(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)
	token := ownerToken(6)
	lease, status := allocateRoom(t, server.URL, token)
	if status != http.StatusCreated {
		t.Fatalf("allocation status = %d", status)
	}
	viewer := dialViewer(t, server.URL, lease.Room)
	var unavailable protocol.Message
	if err := viewer.ReadJSON(&unavailable); err != nil {
		t.Fatal(err)
	}
	if unavailable.Type != protocol.MessageHostUnavailable {
		t.Fatalf("unavailable message = %#v", unavailable)
	}

	header := http.Header{}
	header.Set("Origin", "https://attacker.example")
	header.Set("Authorization", "Bearer "+token)
	_, response, err := websocket.DefaultDialer.Dial(
		websocketURL(server.URL, "/api/v1/rooms/"+lease.Room+"/host"),
		header,
	)
	if err == nil {
		t.Fatal("cross-origin websocket was accepted")
	}
	if response == nil || response.StatusCode != http.StatusForbidden {
		t.Fatalf("cross-origin status = %#v, %v", response, err)
	}
}

func TestUnknownAndOversizedWebSocketMessagesAreRejected(t *testing.T) {
	_, server := newHTTPTestServer(t)
	token := ownerToken(7)
	lease, status := allocateRoom(t, server.URL, token)
	if status != http.StatusCreated {
		t.Fatalf("allocation status = %d", status)
	}
	host := dialHost(t, server.URL, lease.Room, token)
	if err := host.WriteJSON(map[string]any{"type": "relay", "unknown": true}); err != nil {
		t.Fatal(err)
	}
	var protocolError protocol.Message
	if err := host.ReadJSON(&protocolError); err != nil {
		t.Fatal(err)
	}
	if protocolError.Type != protocol.MessageError || protocolError.Code != "protocol_error" {
		t.Fatalf("unknown field response = %#v", protocolError)
	}

	secondHost := dialHost(t, server.URL, lease.Room, token)
	oversized := bytes.Repeat([]byte("x"), protocol.MaximumMessageBytes+1)
	if err := secondHost.WriteMessage(websocket.TextMessage, oversized); err != nil {
		t.Fatal(err)
	}
	_ = secondHost.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := secondHost.ReadMessage(); err == nil {
		t.Fatal("oversized frame did not close the websocket")
	}
}

func TestServiceShutdownClosesActiveWebSocketsWithinDeadline(t *testing.T) {
	service, server := newHTTPTestServer(t)
	token := ownerToken(22)
	lease, status := allocateRoom(t, server.URL, token)
	if status != http.StatusCreated {
		t.Fatalf("allocation status = %d", status)
	}
	host := dialHost(t, server.URL, lease.Room, token)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	started := time.Now()
	if err := service.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown() = %v", err)
	}
	if elapsed := time.Since(started); elapsed >= time.Second {
		t.Fatalf("Shutdown() exceeded deadline: %v", elapsed)
	}
	_ = host.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := host.ReadMessage(); err == nil {
		t.Fatal("host websocket remained open after shutdown")
	}
}
