package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/config"
	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

func testConfiguration() config.Config {
	configuration := config.Default("test-version")
	configuration.LeaseDuration = 2 * time.Minute
	configuration.ReconnectGrace = time.Second
	configuration.CleanupInterval = 100 * time.Millisecond
	configuration.ReadTimeout = 5 * time.Second
	configuration.WriteTimeout = 2 * time.Second
	configuration.PingInterval = time.Second
	configuration.RouteIdleTimeout = 10 * time.Second
	configuration.ShutdownTimeout = 2 * time.Second
	configuration.MaximumRendezvous = 32
	configuration.MaximumConnections = 64
	return configuration
}

func newHTTPTestServer(t *testing.T) (*Service, *httptest.Server) {
	t.Helper()
	service, err := New(testConfiguration())
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
	return base64.RawURLEncoding.EncodeToString(
		bytes.Repeat([]byte{value}, protocol.OwnerTokenBytes),
	)
}

func websocketURL(serverURL, path string) string {
	return "ws" + strings.TrimPrefix(serverURL, "http") + path
}

func TestNativeOnlyCapabilitiesHealthAndSecurityHeaders(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)

	response, err := http.Get(
		server.URL + "/.well-known/clip-native-rendezvous",
	)
	if err != nil {
		t.Fatal(err)
	}
	var capabilities protocol.NativeRoomCapabilities
	if err := json.NewDecoder(response.Body).Decode(&capabilities); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK ||
		capabilities.Protocol != protocol.Identifier ||
		capabilities.APIVersion != protocol.NativeRoomAPIVersion ||
		capabilities.MessageVersion != protocol.NativeRoomMessageVersion ||
		capabilities.RoomPathTemplate != "/api/native/v4/rooms/{room}" ||
		capabilities.RoomWebSocketPathTemplate != "/api/native/v4/rooms/{room}/socket" ||
		capabilities.MaximumRoomMembers != protocol.MaximumNativeRoomMembers ||
		len(capabilities.ICEServers) != 1 ||
		len(capabilities.ICEServers[0].URLs) != 1 {
		t.Fatalf("native capabilities = %d, %#v", response.StatusCode, capabilities)
	}
	if response.Header.Get("X-Content-Type-Options") != "nosniff" ||
		!strings.Contains(
			response.Header.Get("Content-Security-Policy"),
			"default-src 'none'",
		) {
		t.Fatalf("security headers = %#v", response.Header)
	}

	for _, path := range []string{"/healthz", "/version"} {
		response, err = http.Get(server.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("%s status = %d", path, response.StatusCode)
		}
	}
}

func TestLegacyBrowserAndRoomSurfacesAreAbsent(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)
	tests := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/.well-known/clip-live-share"},
		{http.MethodPost, "/api/v1/rooms"},
		{http.MethodGet, "/api/v1/rooms/OLD-ROOM/host"},
		{http.MethodGet, "/api/native/v1/rendezvous/OLD/host"},
		{http.MethodGet, "/api/native/v1/rendezvous/OLD/viewer"},
		{http.MethodGet, "/api/native/v3/rendezvous/OLD/host"},
		{http.MethodGet, "/api/native/v3/rendezvous/OLD/viewer"},
		{http.MethodPut, "/api/native/v3/rendezvous/OLD"},
		{http.MethodGet, "/api/native/v3/rendezvous/OLD/owner"},
		{http.MethodGet, "/api/native/v3/rendezvous/OLD/candidate"},
		{http.MethodGet, "/assets/clip-viewer.js"},
		{http.MethodGet, "/OLD-ROOM"},
	}
	for _, test := range tests {
		request, err := http.NewRequest(test.method, server.URL+test.path, nil)
		if err != nil {
			t.Fatal(err)
		}
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusNotFound {
			t.Fatalf(
				"%s %s status = %d; want 404",
				test.method,
				test.path,
				response.StatusCode,
			)
		}
	}
}

func TestServiceShutdownClosesNativeCoordinatorSocket(t *testing.T) {
	service, server := newHTTPTestServer(t)
	roomID := roomV4ID(44)
	token := ownerToken(45)
	createRoomV4(t, server.URL, roomID, token)
	ownerConnection := dialRoomV4(t, server.URL, roomID, "Bearer "+token, "")
	_ = readRoomV4Message(t, ownerConnection, protocol.MessageMemberAdmitted)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := service.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	_ = ownerConnection.SetReadDeadline(time.Now().Add(time.Second))
	for attempt := 0; attempt < 3; attempt++ {
		if _, _, err := ownerConnection.ReadMessage(); err != nil {
			return
		}
	}
	t.Fatal("shutdown left native room WebSocket open")
}
