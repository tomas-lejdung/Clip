package httpapi

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

func TestBrowserReconnectTicketIsBoundedOneUseAndExpires(t *testing.T) {
	store := newBrowserReconnectTicketStore(2)
	now := time.Unix(10_000, 0)
	store.now = func() time.Time { return now }
	nextByte := byte(1)
	store.random = func(destination []byte) error {
		for index := range destination {
			destination[index] = nextByte
		}
		nextByte++
		return nil
	}
	hash := sha256.Sum256([]byte("reconnect"))
	first, ok := store.issue("room-a", "member-a", hash, "source-a")
	if !ok || first == "" {
		t.Fatal("first ticket was not issued")
	}
	if _, ok := store.consume(first, "room-a", "source-b"); ok {
		t.Fatal("ticket was accepted from a different source")
	}
	if _, ok := store.consume(first, "room-a", "source-a"); ok {
		t.Fatal("rejected ticket was reusable")
	}

	second, ok := store.issue("room-a", "member-a", hash, "source-a")
	if !ok {
		t.Fatal("second ticket was not issued")
	}
	credential, ok := store.consume(second, "room-a", "source-a")
	if !ok || credential.memberHandle != "member-a" ||
		credential.reconnectHash != hash {
		t.Fatalf("consumed credential = %#v, %t", credential, ok)
	}
	if _, ok := store.consume(second, "room-a", "source-a"); ok {
		t.Fatal("ticket replay was accepted")
	}

	expired, ok := store.issue("room-a", "member-a", hash, "source-a")
	if !ok {
		t.Fatal("expiring ticket was not issued")
	}
	now = now.Add(browserReconnectTicketLifetime)
	if _, ok := store.consume(expired, "room-a", "source-a"); ok {
		t.Fatal("expired ticket was accepted")
	}
}

func TestBrowserReconnectTicketCapacityRecoversAfterCleanup(t *testing.T) {
	store := newBrowserReconnectTicketStore(1)
	now := time.Unix(20_000, 0)
	store.now = func() time.Time { return now }
	value := byte(10)
	store.random = func(destination []byte) error {
		for index := range destination {
			destination[index] = value
		}
		value++
		return nil
	}
	hash := sha256.Sum256([]byte("capacity"))
	if _, ok := store.issue("room", "member", hash, "source"); !ok {
		t.Fatal("ticket was not issued")
	}
	if _, ok := store.issue("room", "member", hash, "source"); ok {
		t.Fatal("ticket store exceeded its bound")
	}
	now = now.Add(browserReconnectTicketLifetime)
	store.cleanup()
	if _, ok := store.issue("room", "member", hash, "source"); !ok {
		t.Fatal("expired ticket did not release capacity")
	}
}

func issueBrowserReconnectTicket(
	t *testing.T,
	serverURL string,
	roomID string,
	memberHandle string,
	reconnectCapability string,
) string {
	t.Helper()
	body, err := json.Marshal(browserReconnectRequest{
		MemberHandle: memberHandle,
	})
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(body, []byte(reconnectCapability)) ||
		bytes.Contains(body, []byte("reconnectCapability")) {
		t.Fatal("reconnect capability was placed in the request body")
	}
	request, err := http.NewRequest(
		http.MethodPost,
		serverURL+"/api/native/v4/rooms/"+roomID+"/browser-reconnect",
		bytes.NewReader(body),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", serverURL)
	request.Header.Set("Authorization", "Bearer "+reconnectCapability)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("ticket status = %d", response.StatusCode)
	}
	if response.Header.Get("Set-Cookie") != "" {
		t.Fatal("reconnect credential was persisted in a cookie")
	}
	var result browserReconnectResponse
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(result.Ticket)
	if err != nil || len(decoded) != browserReconnectTicketBytes ||
		result.ExpiresInSeconds != int64(browserReconnectTicketLifetime/time.Second) ||
		result.Ticket == reconnectCapability {
		t.Fatalf("ticket response = %#v", result)
	}
	return result.Ticket
}

func browserReconnectTicketStatus(
	t *testing.T,
	serverURL string,
	roomID string,
	memberHandle string,
	reconnectCapability string,
) int {
	t.Helper()
	body, err := json.Marshal(browserReconnectRequest{
		MemberHandle: memberHandle,
	})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(
		http.MethodPost,
		serverURL+"/api/native/v4/rooms/"+roomID+"/browser-reconnect",
		bytes.NewReader(body),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", serverURL)
	request.Header.Set("Authorization", "Bearer "+reconnectCapability)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	return response.StatusCode
}

func dialBrowserRoomV4(
	t *testing.T,
	serverURL string,
	roomID string,
	protocols ...string,
) *websocket.Conn {
	t.Helper()
	dialer := *websocket.DefaultDialer
	dialer.Subprotocols = protocols
	connection, response, err := dialer.Dial(
		websocketURL(serverURL, "/api/native/v4/rooms/"+roomID+"/socket"),
		nil,
	)
	if err != nil {
		if response != nil {
			response.Body.Close()
		}
		t.Fatalf("dial browser room: %v", err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func TestBrowserRoomSocketUsesSameCandidateAndOneUseReconnectFlow(
	t *testing.T,
) {
	_, server := newHTTPTestServer(t)
	roomID := roomV4ID(91)
	token := ownerToken(91)
	createRoomV4(t, server.URL, roomID, token)
	creator := dialRoomV4(t, server.URL, roomID, "Bearer "+token, "")
	_ = readRoomV4Message(t, creator, protocol.MessageMemberAdmitted)

	browser := dialBrowserRoomV4(
		t,
		server.URL,
		roomID,
		browserRoomWebSocketProtocol,
	)
	if browser.Subprotocol() != browserRoomWebSocketProtocol {
		t.Fatalf("selected protocol = %q", browser.Subprotocol())
	}
	admitted := admitRoomV4Member(t, creator, browser, 92)
	_ = browser.Close()
	_ = readRoomV4Message(t, creator, protocol.MessageRosterSnapshot)

	ticket := issueBrowserReconnectTicket(
		t,
		server.URL,
		roomID,
		admitted.MemberHandle,
		admitted.ReconnectCapability,
	)
	reconnected := dialBrowserRoomV4(
		t,
		server.URL,
		roomID,
		browserRoomWebSocketProtocol,
		browserReconnectProtocolPrefix+ticket,
	)
	if reconnected.Subprotocol() != browserRoomWebSocketProtocol {
		t.Fatalf("reconnect selected protocol = %q", reconnected.Subprotocol())
	}
	reconnectedAdmitted := readRoomV4Message(
		t,
		reconnected,
		protocol.MessageMemberAdmitted,
	)
	if reconnectedAdmitted.MemberHandle != admitted.MemberHandle ||
		reconnectedAdmitted.ReconnectCapability != "" {
		t.Fatalf("browser reconnect result = %#v", reconnectedAdmitted)
	}

	replayed := dialBrowserRoomV4(
		t,
		server.URL,
		roomID,
		browserRoomWebSocketProtocol,
		browserReconnectProtocolPrefix+ticket,
	)
	errorMessage := readRoomV4Message(
		t,
		replayed,
		protocol.MessageProtocolError,
	)
	if errorMessage.Code != "room_unauthorized" {
		t.Fatalf("replayed ticket result = %#v", errorMessage)
	}
}

func TestBrowserReconnectRejectsBogusCredentialsBeforeUsingTicketCapacity(
	t *testing.T,
) {
	configuration := testConfiguration()
	configuration.MaximumTrackedSources = 1
	service, err := New(configuration)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(service.Handler())
	t.Cleanup(func() {
		server.Close()
		service.Close()
	})
	roomID := roomV4ID(96)
	token := ownerToken(96)
	createRoomV4(t, server.URL, roomID, token)
	creator := dialRoomV4(t, server.URL, roomID, "Bearer "+token, "")
	_ = readRoomV4Message(t, creator, protocol.MessageMemberAdmitted)
	candidate := dialBrowserRoomV4(
		t,
		server.URL,
		roomID,
		browserRoomWebSocketProtocol,
	)
	admitted := admitRoomV4Member(t, creator, candidate, 97)

	for _, test := range []struct {
		name       string
		handle     string
		capability string
	}{
		{
			name:       "unknown member",
			handle:     roomV4Handle(98),
			capability: admitted.ReconnectCapability,
		},
		{
			name:       "wrong reconnect capability",
			handle:     admitted.MemberHandle,
			capability: ownerToken(99),
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			status := browserReconnectTicketStatus(
				t,
				server.URL,
				roomID,
				test.handle,
				test.capability,
			)
			if status != http.StatusUnauthorized {
				t.Fatalf("status = %d; want %d", status, http.StatusUnauthorized)
			}
		})
	}

	service.webReconnect.mu.Lock()
	usedCapacity := len(service.webReconnect.entries)
	service.webReconnect.mu.Unlock()
	if usedCapacity != 0 {
		t.Fatalf("bogus credentials allocated %d tickets", usedCapacity)
	}

	_ = issueBrowserReconnectTicket(
		t,
		server.URL,
		roomID,
		admitted.MemberHandle,
		admitted.ReconnectCapability,
	)
	if status := browserReconnectTicketStatus(
		t,
		server.URL,
		roomID,
		admitted.MemberHandle,
		admitted.ReconnectCapability,
	); status != http.StatusServiceUnavailable {
		t.Fatalf("full ticket store status = %d; want %d", status, http.StatusServiceUnavailable)
	}
}

func TestBrowserReconnectEndpointRejectsCrossOriginAndMalformedSecrets(
	t *testing.T,
) {
	_, server := newHTTPTestServer(t)
	roomID := roomV4ID(93)
	createRoomV4(t, server.URL, roomID, ownerToken(93))
	validBody := `{"memberHandle":"` + roomV4Handle(93) + `"}`
	for _, test := range []struct {
		name   string
		origin string
		body   string
		auth   string
		query  string
		status int
	}{
		{name: "missing origin", body: validBody, auth: ownerToken(94), status: http.StatusForbidden},
		{name: "cross origin", origin: "https://attacker.example", body: validBody, auth: ownerToken(94), status: http.StatusForbidden},
		{name: "missing authorization", origin: server.URL, body: validBody, status: http.StatusBadRequest},
		{name: "unknown field", origin: server.URL, body: strings.TrimSuffix(validBody, "}") + `,"extra":true}`, auth: ownerToken(94), status: http.StatusBadRequest},
		{name: "capability in body", origin: server.URL, body: strings.TrimSuffix(validBody, "}") + `,"reconnectCapability":"` + ownerToken(94) + `"}`, auth: ownerToken(94), status: http.StatusBadRequest},
		{name: "invalid capability", origin: server.URL, body: validBody, auth: "secret", status: http.StatusBadRequest},
		{name: "capability in query", origin: server.URL, body: validBody, auth: ownerToken(94), query: "?reconnectCapability=" + ownerToken(94), status: http.StatusBadRequest},
	} {
		t.Run(test.name, func(t *testing.T) {
			request, err := http.NewRequest(
				http.MethodPost,
				server.URL+"/api/native/v4/rooms/"+roomID+"/browser-reconnect"+test.query,
				strings.NewReader(test.body),
			)
			if err != nil {
				t.Fatal(err)
			}
			if test.origin != "" {
				request.Header.Set("Origin", test.origin)
			}
			if test.auth != "" {
				request.Header.Set("Authorization", "Bearer "+test.auth)
			}
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			response.Body.Close()
			if response.StatusCode != test.status {
				t.Fatalf("status = %d; want %d", response.StatusCode, test.status)
			}
		})
	}
}

func TestMalformedBrowserReconnectProtocolCannotBecomeCandidate(t *testing.T) {
	_, server := newHTTPTestServer(t)
	roomID := roomV4ID(95)
	createRoomV4(t, server.URL, roomID, ownerToken(95))
	creator := dialRoomV4(t, server.URL, roomID, "Bearer "+ownerToken(95), "")
	_ = readRoomV4Message(t, creator, protocol.MessageMemberAdmitted)

	connection := dialBrowserRoomV4(
		t,
		server.URL,
		roomID,
		browserRoomWebSocketProtocol,
		browserReconnectProtocolPrefix+"invalid",
	)
	message := readRoomV4Message(t, connection, protocol.MessageProtocolError)
	if message.Code != "room_unauthorized" {
		t.Fatalf("malformed reconnect result = %#v", message)
	}
}
