package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
)

func encodedBytes(value byte, count int) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, count))
}

func TestRoomIdentifiersCapabilitiesAndPairIDAreCanonical(t *testing.T) {
	t.Parallel()
	room := encodedBytes(1, NativeRoomIDBytes)
	left := encodedBytes(2, NativeMemberHandleBytes)
	right := encodedBytes(3, NativeMemberHandleBytes)
	if err := ValidateNativeRoomID(room); err != nil {
		t.Fatal(err)
	}
	if err := ValidateNativeRoomID(room + "="); !errors.Is(err, ErrInvalidNativeRoomID) {
		t.Fatalf("padded room = %v", err)
	}
	forward, err := NativePairID(room, left, right)
	if err != nil {
		t.Fatal(err)
	}
	reverse, err := NativePairID(room, right, left)
	if err != nil || reverse != forward {
		t.Fatalf("reverse pair = %q, %v; forward=%q", reverse, err, forward)
	}
	if err := ValidateNativePairID(forward); err != nil {
		t.Fatal(err)
	}
	if _, err := NativePairID(room, left, left); err == nil {
		t.Fatal("self pair accepted")
	}
}

func TestOwnerAndReconnectCapabilitiesRequireCanonicalThirtyTwoBytes(t *testing.T) {
	t.Parallel()
	valid := encodedBytes(4, OwnerTokenBytes)
	if _, err := DecodeOwnerToken(valid); err != nil {
		t.Fatal(err)
	}
	if _, err := HashNativeReconnectCapability(valid); err != nil {
		t.Fatal(err)
	}
	for _, invalid := range []string{valid + "=", encodedBytes(4, OwnerTokenBytes-1), strings.Repeat("!", len(valid))} {
		if _, err := DecodeOwnerToken(invalid); !errors.Is(err, ErrInvalidOwnerToken) {
			t.Fatalf("owner %q = %v", invalid, err)
		}
		if _, err := HashNativeReconnectCapability(invalid); !errors.Is(err, ErrInvalidOwnerToken) {
			t.Fatalf("reconnect %q = %v", invalid, err)
		}
	}
}

func TestNativeRoomV4MessagesAreStrictOpaqueAndBounded(t *testing.T) {
	t.Parallel()
	handle := encodedBytes(5, NativeMemberHandleBytes)
	pairID := encodedBytes(6, NativePairIDBytes)
	payload := encodedBytes(7, 128)
	descriptor := encodedBytes(8, 256)
	valid := []Message{
		{Type: MessageJoinKnock, Version: NativeRoomMessageVersion, Sequence: 1, Payload: payload},
		{Type: MessageAdmitCandidate, Version: NativeRoomMessageVersion, CandidateHandle: handle, Payload: descriptor},
		{Type: MessageDenyCandidate, Version: NativeRoomMessageVersion, CandidateHandle: handle, Reason: "denied"},
		{Type: MessagePairSignal, Version: NativeRoomMessageVersion, To: handle, PairID: pairID, Sequence: 1, Payload: payload},
		{Type: MessageLeaveRoom, Version: NativeRoomMessageVersion},
		{Type: MessageRemoveMember, Version: NativeRoomMessageVersion, To: handle},
	}
	for index, message := range valid {
		if err := ValidateNativeRoomClientMessage(message); err != nil {
			t.Fatalf("valid %d = %v", index, err)
		}
	}
	invalid := []Message{
		{Type: MessageJoinKnock, Version: 3, Sequence: 1, Payload: payload},
		{Type: MessageJoinKnock, Version: 4, Payload: payload},
		{Type: MessagePairSignal, Version: 4, To: handle, PairID: pairID, Sequence: 1, Payload: "AA=="},
		{Type: MessagePairSignal, Version: 4, From: handle, To: handle, PairID: pairID, Sequence: 1, Payload: payload},
		{Type: MessageRemoveMember, Version: 4, To: "short"},
	}
	for index, message := range invalid {
		if err := ValidateNativeRoomClientMessage(message); err == nil {
			t.Fatalf("invalid %d accepted", index)
		}
	}
	if _, err := DecodeMessage([]byte(`{"type":"leave-room","version":4,"inviteSecret":"must-not-reach-server"}`)); !errors.Is(err, ErrInvalidMessage) {
		t.Fatalf("unknown secret field accepted: %v", err)
	}
}

func TestRosterRequiresCreatorUniqueMembersAndOpaqueDescriptors(t *testing.T) {
	t.Parallel()
	creator := encodedBytes(9, NativeMemberHandleBytes)
	member := encodedBytes(10, NativeMemberHandleBytes)
	descriptor := encodedBytes(11, 128)
	snapshot := RosterSnapshot{Revision: 2, CreatorHandle: creator, Members: []RosterMember{{Handle: creator, Descriptor: descriptor, Connected: true}, {Handle: member, Descriptor: descriptor}}}
	if err := ValidateRosterSnapshot(snapshot); err != nil {
		t.Fatal(err)
	}
	duplicate := snapshot
	duplicate.Members = append(duplicate.Members, duplicate.Members[0])
	if err := ValidateRosterSnapshot(duplicate); err == nil {
		t.Fatal("duplicate accepted")
	}
	missing := snapshot
	missing.CreatorHandle = encodedBytes(12, NativeMemberHandleBytes)
	if err := ValidateRosterSnapshot(missing); err == nil {
		t.Fatal("missing creator accepted")
	}
}

func TestStrictJSONRejectsUnknownTrailingAndOversized(t *testing.T) {
	t.Parallel()
	var request NativeRoomRequest
	if err := DecodeStrictJSON(strings.NewReader(`{"ownerToken":"x","descriptor":"y","secret":"z"}`), 1024, &request); err == nil {
		t.Fatal("unknown field accepted")
	}
	if err := DecodeStrictJSON(strings.NewReader(`{} {}`), 1024, &request); err == nil {
		t.Fatal("trailing value accepted")
	}
	if err := DecodeStrictJSON(strings.NewReader(strings.Repeat("x", 1025)), 1024, &request); err == nil {
		t.Fatal("oversized JSON accepted")
	}
}

func TestCanonicalNativeRoomV4WireFixture(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile("testdata/native-room-v4-wire.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		RoomID        string `json:"roomId"`
		CreatorHandle string `json:"creatorHandle"`
		MemberHandle  string `json:"memberHandle"`
		Messages      []struct {
			Name    string  `json:"name"`
			Message Message `json:"message"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if ValidateNativeRoomID(fixture.RoomID) != nil ||
		ValidateNativeMemberHandle(fixture.CreatorHandle) != nil ||
		ValidateNativeMemberHandle(fixture.MemberHandle) != nil {
		t.Fatal("fixture routing identifiers are invalid")
	}
	pairID, err := NativePairID(fixture.RoomID, fixture.CreatorHandle, fixture.MemberHandle)
	if err != nil {
		t.Fatal(err)
	}
	wantTypes := []MessageType{MessageCandidateOpened, MessageMemberAdmitted, MessageMemberAdmitted, MessageRosterSnapshot, MessagePairSignal, MessageRoomEnded}
	if len(fixture.Messages) != len(wantTypes) {
		t.Fatalf("fixture messages = %d", len(fixture.Messages))
	}
	for index, entry := range fixture.Messages {
		if entry.Message.Type != wantTypes[index] || entry.Message.Version != NativeRoomMessageVersion {
			t.Fatalf("fixture %q = %#v", entry.Name, entry.Message)
		}
		if entry.Message.Roster != nil {
			if err := ValidateRosterSnapshot(*entry.Message.Roster); err != nil {
				t.Fatalf("fixture %q roster = %v", entry.Name, err)
			}
		}
		if entry.Message.Type == MessagePairSignal && entry.Message.PairID != pairID {
			t.Fatalf("fixture pairId = %q; want %q", entry.Message.PairID, pairID)
		}
	}
}
