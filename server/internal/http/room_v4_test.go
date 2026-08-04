package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
	"github.com/tomas-lejdung/Clip/server/internal/signaling"
)

func roomV4ID(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, protocol.NativeRoomIDBytes))
}

func roomV4Descriptor(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 256))
}

func roomV4Payload(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 96))
}

func roomV4Handle(value byte) string {
	return base64.RawURLEncoding.EncodeToString(
		bytes.Repeat([]byte{value}, protocol.NativeMemberHandleBytes),
	)
}

func createRoomV4(t *testing.T, serverURL, roomID, token string) protocol.NativeRoomResponse {
	t.Helper()
	body, _ := json.Marshal(protocol.NativeRoomRequest{
		OwnerToken:    token,
		CreatorHandle: roomV4Handle(240),
		Descriptor:    roomV4Descriptor(1),
	})
	request, _ := http.NewRequest(http.MethodPut, serverURL+"/api/native/v4/rooms/"+roomID, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated && response.StatusCode != http.StatusOK {
		t.Fatalf("create room status = %d", response.StatusCode)
	}
	var result protocol.NativeRoomResponse
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result
}

func dialRoomV4(t *testing.T, serverURL, roomID, authorization, memberHandle string) *websocket.Conn {
	t.Helper()
	headers := http.Header{}
	if authorization != "" {
		headers.Set("Authorization", authorization)
	}
	if memberHandle != "" {
		headers.Set("X-Clip-Member-Handle", memberHandle)
	}
	connection, response, err := websocket.DefaultDialer.Dial(websocketURL(serverURL, "/api/native/v4/rooms/"+roomID+"/socket"), headers)
	if err != nil {
		if response != nil {
			response.Body.Close()
		}
		t.Fatalf("dial room: %v", err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func readRoomV4Message(t *testing.T, connection *websocket.Conn, expected protocol.MessageType) protocol.Message {
	t.Helper()
	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	for attempt := 0; attempt < 12; attempt++ {
		var message protocol.Message
		if err := connection.ReadJSON(&message); err != nil {
			t.Fatalf("read %s: %v", expected, err)
		}
		if message.Type == expected {
			return message
		}
	}
	t.Fatalf("did not receive %s", expected)
	return protocol.Message{}
}

func admitRoomV4Member(t *testing.T, creator, candidate *websocket.Conn, descriptorByte byte) protocol.Message {
	t.Helper()
	opened := readRoomV4Message(t, candidate, protocol.MessageCandidateOpened)
	knock := protocol.Message{Type: protocol.MessageJoinKnock, Version: protocol.NativeRoomMessageVersion, Sequence: 1, Payload: roomV4Payload(descriptorByte)}
	if err := candidate.WriteJSON(knock); err != nil {
		t.Fatal(err)
	}
	request := readRoomV4Message(t, creator, protocol.MessageJoinKnock)
	if request.CandidateHandle != opened.CandidateHandle || request.Payload != knock.Payload {
		t.Fatalf("join request = %#v", request)
	}
	if err := creator.WriteJSON(protocol.Message{Type: protocol.MessageAdmitCandidate, Version: protocol.NativeRoomMessageVersion, CandidateHandle: opened.CandidateHandle, Payload: roomV4Descriptor(descriptorByte)}); err != nil {
		t.Fatal(err)
	}
	admitted := readRoomV4Message(t, candidate, protocol.MessageMemberAdmitted)
	if admitted.MemberHandle != opened.CandidateHandle || admitted.ReconnectCapability == "" || admitted.Roster == nil {
		t.Fatalf("member admitted = %#v", admitted)
	}
	return admitted
}

func TestNativeRoomV4FullThreeMemberFlowStableRoomAndCreatorExit(t *testing.T) {
	_, server := newHTTPTestServer(t)
	roomID := roomV4ID(31)
	token := ownerToken(31)
	created := createRoomV4(t, server.URL, roomID, token)
	creator := dialRoomV4(t, server.URL, roomID, "Bearer "+token, "")
	creatorAdmitted := readRoomV4Message(t, creator, protocol.MessageMemberAdmitted)
	if creatorAdmitted.MemberHandle != created.CreatorHandle || creatorAdmitted.Roster == nil {
		t.Fatalf("creator admitted = %#v", creatorAdmitted)
	}

	b := dialRoomV4(t, server.URL, roomID, "", "")
	bAdmitted := admitRoomV4Member(t, creator, b, 2)
	_ = readRoomV4Message(t, creator, protocol.MessageRosterSnapshot)
	c := dialRoomV4(t, server.URL, roomID, "", "")
	cAdmitted := admitRoomV4Member(t, creator, c, 3)
	creatorRoster := readRoomV4Message(t, creator, protocol.MessageRosterSnapshot)
	if creatorRoster.Roster == nil || len(creatorRoster.Roster.Members) != 3 {
		t.Fatalf("creator roster = %#v", creatorRoster)
	}

	// The same room URL remains reusable after multiple admissions.
	retried := createRoomV4(t, server.URL, roomID, token)
	if retried.CreatorHandle != created.CreatorHandle || retried.RoomID != roomID {
		t.Fatalf("stable room retry = %#v", retried)
	}

	pairID, err := protocol.NativePairID(roomID, bAdmitted.MemberHandle, cAdmitted.MemberHandle)
	if err != nil {
		t.Fatal(err)
	}
	signal := protocol.Message{Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion, To: cAdmitted.MemberHandle, PairID: pairID, Sequence: 1, Payload: roomV4Payload(9)}
	if err := b.WriteJSON(signal); err != nil {
		t.Fatal(err)
	}
	received := readRoomV4Message(t, c, protocol.MessagePairSignal)
	if received.From != bAdmitted.MemberHandle || received.To != cAdmitted.MemberHandle || received.Payload != signal.Payload {
		t.Fatalf("pair signal = %#v", received)
	}

	if err := creator.WriteJSON(protocol.Message{Type: protocol.MessageLeaveRoom, Version: protocol.NativeRoomMessageVersion}); err != nil {
		t.Fatal(err)
	}
	if ended := readRoomV4Message(t, b, protocol.MessageRoomEnded); ended.Reason != "creator-left" {
		t.Fatalf("B room ended = %#v", ended)
	}
	if ended := readRoomV4Message(t, c, protocol.MessageRoomEnded); ended.Reason != "creator-left" {
		t.Fatalf("C room ended = %#v", ended)
	}
	response, err := http.Get(server.URL + "/api/native/v4/rooms/" + roomID)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("ended room status = %d", response.StatusCode)
	}
}

func TestNativeRoomV4ReconnectKeepsHandleAndRoster(t *testing.T) {
	_, server := newHTTPTestServer(t)
	roomID := roomV4ID(32)
	token := ownerToken(32)
	createRoomV4(t, server.URL, roomID, token)
	creator := dialRoomV4(t, server.URL, roomID, "Bearer "+token, "")
	_ = readRoomV4Message(t, creator, protocol.MessageMemberAdmitted)
	b := dialRoomV4(t, server.URL, roomID, "", "")
	admitted := admitRoomV4Member(t, creator, b, 2)
	_ = b.Close()
	// Wait for the server read loop to mark the member disconnected.
	_ = readRoomV4Message(t, creator, protocol.MessageRosterSnapshot)
	reconnected := dialRoomV4(t, server.URL, roomID, "Reconnect "+admitted.ReconnectCapability, admitted.MemberHandle)
	reconnectedAdmitted := readRoomV4Message(t, reconnected, protocol.MessageMemberAdmitted)
	if reconnectedAdmitted.MemberHandle != admitted.MemberHandle || reconnectedAdmitted.Roster == nil || len(reconnectedAdmitted.Roster.Members) != 2 {
		t.Fatalf("reconnected member = %#v", reconnectedAdmitted)
	}
}

func TestRoomV4PairRoutingErrorsCarryOnlyTheirPairContext(t *testing.T) {
	t.Parallel()
	to := roomV4Handle(81)
	pairID := base64.RawURLEncoding.EncodeToString(
		bytes.Repeat([]byte{82}, protocol.NativePairIDBytes),
	)
	signal := protocol.Message{
		Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion,
		To: to, PairID: pairID, Sequence: 7, Payload: roomV4Payload(83),
	}
	for _, value := range []struct {
		err  error
		code string
	}{
		{signaling.ErrRoomSequence, "sequence_rejected"},
		{signaling.ErrRoomMemberNotFound, "member_unavailable"},
		{signaling.ErrRouteBackpressure, "route_backpressure"},
	} {
		message := roomMessageError(signal, value.err)
		if message.Code != value.code || message.To != to ||
			message.PairID != pairID || message.Sequence != 7 {
			t.Fatalf("%s error context = %#v", value.code, message)
		}
	}
	roomError := roomMessageError(
		protocol.Message{Type: protocol.MessageLeaveRoom, Version: protocol.NativeRoomMessageVersion},
		protocol.ErrInvalidMessage,
	)
	if roomError.Code != "protocol_error" || roomError.To != "" ||
		roomError.PairID != "" || roomError.Sequence != 0 {
		t.Fatalf("room error leaked pair context = %#v", roomError)
	}
}
