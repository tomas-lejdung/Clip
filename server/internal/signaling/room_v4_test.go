package signaling

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

type fakePeer struct {
	mu       sync.Mutex
	messages []protocol.Message
	closed   bool
	code     int
	sendErr  error
}

func (p *fakePeer) Send(message protocol.Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.sendErr != nil {
		return p.sendErr
	}
	if p.closed {
		return ErrSocketClosed
	}
	p.messages = append(p.messages, message)
	return nil
}

func (p *fakePeer) Close(code int, _ string) {
	p.mu.Lock()
	p.closed = true
	p.code = code
	p.mu.Unlock()
}

func (p *fakePeer) snapshot() ([]protocol.Message, bool, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]protocol.Message(nil), p.messages...), p.closed, p.code
}

func (p *fakePeer) failSends(err error) {
	p.mu.Lock()
	p.sendErr = err
	p.mu.Unlock()
}

type hubClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *hubClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *hubClock) Advance(duration time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(duration)
	c.mu.Unlock()
}

func deterministicRandom() func([]byte) error {
	var mu sync.Mutex
	value := byte(1)
	return func(destination []byte) error {
		mu.Lock()
		defer mu.Unlock()
		for index := range destination {
			destination[index] = value
		}
		value++
		return nil
	}
}

func nativeDescriptor(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 256))
}

func newRoomTestHub(clock *hubClock) *RoomHub {
	return NewRoomHub(RoomConfiguration{
		LeaseDuration: time.Minute, ReconnectGrace: 10 * time.Second,
		CandidateIdleTimeout: 20 * time.Second, MaximumRooms: 4,
		MaximumPending: 8, Now: clock.Now, Random: deterministicRandom(),
	})
}

func roomTestID(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, protocol.NativeRoomIDBytes))
}

func roomTestPayload(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 96))
}

func roomTestHandle(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, protocol.NativeMemberHandleBytes))
}

func roomTestOwner(value byte) [sha256.Size]byte {
	var hash [sha256.Size]byte
	for index := range hash {
		hash[index] = value
	}
	return hash
}

func roomPairID(t *testing.T, roomID, left, right string) string {
	t.Helper()
	pairID, err := protocol.NativePairID(roomID, left, right)
	if err != nil {
		t.Fatal(err)
	}
	return pairID
}

func attachRoomCreator(t *testing.T, hub *RoomHub, roomID string, owner [sha256.Size]byte, peer *fakePeer) RoomSession {
	t.Helper()
	result, err := hub.CreateRoom(roomID, owner, roomTestHandle(240), nativeDescriptor(1))
	if err != nil || result.CreatorHandle == "" {
		t.Fatalf("CreateRoom() = %#v, %v", result, err)
	}
	session, err := hub.AttachCreator(roomID, owner, "creator-connection", peer)
	if err != nil {
		t.Fatalf("AttachCreator() = %v", err)
	}
	return session
}

func admitRoomMember(t *testing.T, hub *RoomHub, roomID string, creator RoomSession, creatorPeer *fakePeer, connectionID string, descriptorByte byte) (RoomSession, *fakePeer, string) {
	t.Helper()
	peer := &fakePeer{}
	candidate, err := hub.OpenCandidate(roomID, connectionID, peer)
	if err != nil {
		t.Fatalf("OpenCandidate() = %v", err)
	}
	if err := hub.JoinKnock(candidate, protocol.Message{Type: protocol.MessageJoinKnock, Version: protocol.NativeRoomMessageVersion, Sequence: 1, Payload: roomTestPayload(descriptorByte)}); err != nil {
		t.Fatalf("JoinKnock() = %v", err)
	}
	creatorMessages, _, _ := creatorPeer.snapshot()
	last := creatorMessages[len(creatorMessages)-1]
	if last.Type != protocol.MessageJoinKnock || last.CandidateHandle != candidate.Handle {
		t.Fatalf("creator join request = %#v", last)
	}
	if err := hub.AdmitCandidate(creator, protocol.Message{Type: protocol.MessageAdmitCandidate, Version: protocol.NativeRoomMessageVersion, CandidateHandle: candidate.Handle, Payload: nativeDescriptor(descriptorByte)}); err != nil {
		t.Fatalf("AdmitCandidate() = %v", err)
	}
	candidate = hub.ResolveSession(candidate)
	if candidate.Candidate {
		t.Fatal("admitted socket remained a candidate session")
	}
	messages, _, _ := peer.snapshot()
	capability := ""
	for _, message := range messages {
		if message.Type == protocol.MessageMemberAdmitted {
			capability = message.ReconnectCapability
		}
	}
	if capability == "" {
		t.Fatal("admitted member did not receive reconnect capability")
	}
	return candidate, peer, capability
}

func TestRoomHubBuildsCompleteFourParticipantMeshWithoutReplacingExistingPairs(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(20_000, 0)}
	hub := newRoomTestHub(clock)
	roomID := roomTestID(1)
	creatorPeer := &fakePeer{}
	creator := attachRoomCreator(t, hub, roomID, roomTestOwner(1), creatorPeer)
	b, bPeer, _ := admitRoomMember(t, hub, roomID, creator, creatorPeer, "b", 2)

	pairAB := roomPairID(t, roomID, creator.Handle, b.Handle)
	if err := hub.PairSignal(creator, protocol.Message{Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion, To: b.Handle, PairID: pairAB, Sequence: 1, Payload: roomTestPayload(10)}); err != nil {
		t.Fatalf("A->B signal = %v", err)
	}
	beforeB, bClosed, _ := bPeer.snapshot()
	if bClosed || beforeB[len(beforeB)-1].From != creator.Handle {
		t.Fatalf("B delivery before C = %#v, closed=%v", beforeB[len(beforeB)-1], bClosed)
	}

	c, _, _ := admitRoomMember(t, hub, roomID, creator, creatorPeer, "c", 3)
	// Existing A-B direction continues at sequence 2 after C is added.
	if err := hub.PairSignal(creator, protocol.Message{Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion, To: b.Handle, PairID: pairAB, Sequence: 2, Payload: roomTestPayload(11)}); err != nil {
		t.Fatalf("retained A->B signal = %v", err)
	}
	for index, edge := range []struct {
		from RoomSession
		to   string
	}{
		{creator, c.Handle}, {b, creator.Handle}, {b, c.Handle}, {c, creator.Handle}, {c, b.Handle},
	} {
		if err := hub.PairSignal(edge.from, protocol.Message{Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion, To: edge.to, PairID: roomPairID(t, roomID, edge.from.Handle, edge.to), Sequence: 1, Payload: roomTestPayload(byte(20 + index))}); err != nil {
			t.Fatalf("mesh signal %d = %v", index, err)
		}
	}

	d, _, _ := admitRoomMember(t, hub, roomID, creator, creatorPeer, "d", 4)
	if d.Handle == "" {
		t.Fatal("fourth member has no handle")
	}
	if _, err := hub.OpenCandidate(roomID, "fifth", &fakePeer{}); !errors.Is(err, ErrRoomCapacity) {
		t.Fatalf("fifth OpenCandidate() = %v", err)
	}
	snapshot, found := hub.Snapshot(roomID)
	if !found || snapshot.MemberCount != 4 {
		t.Fatalf("room snapshot = %#v, found=%v", snapshot, found)
	}
}

func TestRoomHubInviteAndHandlesStayStableAcrossJoinsAndReconnect(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(30_000, 0)}
	hub := newRoomTestHub(clock)
	roomID := roomTestID(2)
	owner := roomTestOwner(2)
	creatorPeer := &fakePeer{}
	creator := attachRoomCreator(t, hub, roomID, owner, creatorPeer)
	b, bPeer, capability := admitRoomMember(t, hub, roomID, creator, creatorPeer, "b-first", 2)

	retry, err := hub.CreateRoom(roomID, owner, creator.Handle, nativeDescriptor(1))
	if err != nil || retry.Created || retry.CreatorHandle != creator.Handle {
		t.Fatalf("idempotent CreateRoom() = %#v, %v", retry, err)
	}
	if _, err := hub.CreateRoom(roomID, owner, roomTestHandle(239), nativeDescriptor(1)); !errors.Is(err, ErrRoomConflict) {
		t.Fatalf("changed creator handle retry = %v", err)
	}
	hub.Detach(b)
	if _, closed, _ := bPeer.snapshot(); closed {
		t.Fatal("unexpected disconnect closed the P2P participant socket immediately")
	}
	reconnectHash, err := protocol.HashNativeReconnectCapability(capability)
	if err != nil {
		t.Fatal(err)
	}
	reconnectedPeer := &fakePeer{}
	reconnected, err := hub.ReconnectMember(roomID, b.Handle, reconnectHash, "b-second", reconnectedPeer)
	if err != nil || reconnected.Handle != b.Handle {
		t.Fatalf("ReconnectMember() = %#v, %v", reconnected, err)
	}
	snapshot, _ := hub.Snapshot(roomID)
	if snapshot.MemberCount != 2 || snapshot.State != "active" {
		t.Fatalf("snapshot after reconnect = %#v", snapshot)
	}
}

func TestRoomHubNoncreatorLeaveAndPairFailureAreIsolated(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(40_000, 0)}
	hub := newRoomTestHub(clock)
	roomID := roomTestID(3)
	creatorPeer := &fakePeer{}
	creator := attachRoomCreator(t, hub, roomID, roomTestOwner(3), creatorPeer)
	b, bPeer, _ := admitRoomMember(t, hub, roomID, creator, creatorPeer, "b", 2)
	c, cPeer, _ := admitRoomMember(t, hub, roomID, creator, creatorPeer, "c", 3)

	badPair := roomPairID(t, roomID, b.Handle, c.Handle)
	// Sequence 1 may have been consumed by an ambiguous failed WebSocket send.
	// The service accepts the later authenticated signal, then rejects replay.
	if err := hub.PairSignal(b, protocol.Message{Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion, To: c.Handle, PairID: badPair, Sequence: 2, Payload: roomTestPayload(1)}); err != nil {
		t.Fatalf("gapped pair sequence = %v", err)
	}
	if err := hub.PairSignal(b, protocol.Message{Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion, To: c.Handle, PairID: badPair, Sequence: 2, Payload: roomTestPayload(1)}); !errors.Is(err, ErrRoomSequence) {
		t.Fatalf("duplicate pair sequence = %v", err)
	}
	if err := hub.PairSignal(b, protocol.Message{Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion, To: c.Handle, PairID: badPair, Sequence: 1, Payload: roomTestPayload(1)}); !errors.Is(err, ErrRoomSequence) {
		t.Fatalf("replayed pair sequence = %v", err)
	}
	if err := hub.PairSignal(creator, protocol.Message{Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion, To: c.Handle, PairID: roomPairID(t, roomID, creator.Handle, c.Handle), Sequence: 1, Payload: roomTestPayload(2)}); err != nil {
		t.Fatalf("unrelated A-C pair after B-C failure = %v", err)
	}
	if err := hub.Leave(b); err != nil {
		t.Fatalf("B Leave() = %v", err)
	}
	_, bClosed, _ := bPeer.snapshot()
	_, cClosed, _ := cPeer.snapshot()
	if !bClosed || cClosed {
		t.Fatalf("leave closure: B=%v C=%v", bClosed, cClosed)
	}
	snapshot, _ := hub.Snapshot(roomID)
	if snapshot.MemberCount != 2 {
		t.Fatalf("member count after B leave = %d", snapshot.MemberCount)
	}
}

func TestRoomHubCreatorLeaveAndGraceExpiryEndRoomWithoutElection(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name     string
		explicit bool
	}{
		{"explicit", true}, {"grace-expired", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			clock := &hubClock{now: time.Unix(50_000, 0)}
			hub := newRoomTestHub(clock)
			roomID := roomTestID(byte(10 + len(test.name)))
			creatorPeer := &fakePeer{}
			creator := attachRoomCreator(t, hub, roomID, roomTestOwner(4), creatorPeer)
			_, memberPeer, _ := admitRoomMember(t, hub, roomID, creator, creatorPeer, "member", 2)
			if test.explicit {
				if err := hub.Leave(creator); err != nil {
					t.Fatal(err)
				}
			} else {
				hub.Detach(creator)
				clock.Advance(11 * time.Second)
				result := hub.Cleanup()
				if result.EndedRooms != 1 {
					t.Fatalf("Cleanup() = %#v", result)
				}
			}
			if _, found := hub.Snapshot(roomID); found {
				t.Fatal("ended room remained available")
			}
			messages, closed, _ := memberPeer.snapshot()
			if !closed || messages[len(messages)-1].Type != protocol.MessageRoomEnded {
				t.Fatalf("member termination = %#v, closed=%v", messages, closed)
			}
		})
	}
}

func TestRoomHubCandidateDenyAndReconnectExpiry(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(60_000, 0)}
	hub := newRoomTestHub(clock)
	roomID := roomTestID(8)
	creatorPeer := &fakePeer{}
	creator := attachRoomCreator(t, hub, roomID, roomTestOwner(8), creatorPeer)
	candidatePeer := &fakePeer{}
	candidate, err := hub.OpenCandidate(roomID, "candidate", candidatePeer)
	if err != nil {
		t.Fatal(err)
	}
	if err := hub.DenyCandidate(creator, protocol.Message{Type: protocol.MessageDenyCandidate, Version: protocol.NativeRoomMessageVersion, CandidateHandle: candidate.Handle, Reason: "not-now"}); err != nil {
		t.Fatal(err)
	}
	messages, closed, _ := candidatePeer.snapshot()
	if !closed || messages[len(messages)-1].Type != protocol.MessageDenyCandidate {
		t.Fatalf("denial = %#v closed=%v", messages, closed)
	}

	b, _, _ := admitRoomMember(t, hub, roomID, creator, creatorPeer, "b", 2)
	hub.Detach(b)
	clock.Advance(11 * time.Second)
	result := hub.Cleanup()
	if result.RemovedMembers != 1 {
		t.Fatalf("Cleanup() = %#v", result)
	}
	snapshot, _ := hub.Snapshot(roomID)
	if snapshot.MemberCount != 1 {
		t.Fatalf("member count = %d", snapshot.MemberCount)
	}
}

func TestRoomHubAdmissionAndDenialReplaysAreIdempotent(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(61_000, 0)}
	hub := newRoomTestHub(clock)
	roomID := roomTestID(18)
	creatorPeer := &fakePeer{}
	creator := attachRoomCreator(t, hub, roomID, roomTestOwner(18), creatorPeer)

	candidatePeer := &fakePeer{}
	candidate, err := hub.OpenCandidate(roomID, "candidate-replay", candidatePeer)
	if err != nil {
		t.Fatal(err)
	}
	knock := protocol.Message{Type: protocol.MessageJoinKnock, Version: protocol.NativeRoomMessageVersion, Sequence: 2, Payload: roomTestPayload(7)}
	if err := hub.JoinKnock(candidate, knock); err != nil {
		t.Fatalf("gapped JoinKnock() = %v", err)
	}
	knock.Sequence = 4
	if err := hub.JoinKnock(candidate, knock); err != nil {
		t.Fatalf("retried JoinKnock() = %v", err)
	}
	if err := hub.JoinKnock(candidate, knock); !errors.Is(err, ErrRoomSequence) {
		t.Fatalf("duplicate JoinKnock() = %v", err)
	}
	admit := protocol.Message{Type: protocol.MessageAdmitCandidate, Version: protocol.NativeRoomMessageVersion, CandidateHandle: candidate.Handle, Payload: nativeDescriptor(7)}
	if err := hub.AdmitCandidate(creator, admit); err != nil {
		t.Fatal(err)
	}
	if err := hub.AdmitCandidate(creator, admit); err != nil {
		t.Fatalf("admission replay = %v", err)
	}

	deniedPeer := &fakePeer{}
	denied, err := hub.OpenCandidate(roomID, "candidate-denial-replay", deniedPeer)
	if err != nil {
		t.Fatal(err)
	}
	deny := protocol.Message{Type: protocol.MessageDenyCandidate, Version: protocol.NativeRoomMessageVersion, CandidateHandle: denied.Handle, Reason: "no"}
	if err := hub.DenyCandidate(creator, deny); err != nil {
		t.Fatal(err)
	}
	if err := hub.DenyCandidate(creator, deny); err != nil {
		t.Fatalf("denial replay = %v", err)
	}
}

func TestRoomHubFailedCredentialDeliveryRollsBackAndNotifiesCreator(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(62_000, 0)}
	hub := newRoomTestHub(clock)
	roomID := roomTestID(19)
	creatorPeer := &fakePeer{}
	creator := attachRoomCreator(t, hub, roomID, roomTestOwner(19), creatorPeer)
	candidatePeer := &fakePeer{}
	candidate, err := hub.OpenCandidate(roomID, "candidate-failed-delivery", candidatePeer)
	if err != nil {
		t.Fatal(err)
	}
	if err := hub.JoinKnock(candidate, protocol.Message{Type: protocol.MessageJoinKnock, Version: protocol.NativeRoomMessageVersion, Sequence: 1, Payload: roomTestPayload(8)}); err != nil {
		t.Fatal(err)
	}
	candidatePeer.failSends(errors.New("forced member-admitted failure"))
	if err := hub.AdmitCandidate(creator, protocol.Message{Type: protocol.MessageAdmitCandidate, Version: protocol.NativeRoomMessageVersion, CandidateHandle: candidate.Handle, Payload: nativeDescriptor(8)}); err != nil {
		t.Fatalf("transactional admission = %v", err)
	}
	snapshot, _ := hub.Snapshot(roomID)
	if snapshot.MemberCount != 1 {
		t.Fatalf("poisoned member retained: %#v", snapshot)
	}
	messages, _, _ := creatorPeer.snapshot()
	last := messages[len(messages)-1]
	if last.Type != protocol.MessageDenyCandidate || last.CandidateHandle != candidate.Handle {
		t.Fatalf("creator cleanup notification = %#v", last)
	}
}

func TestRoomHubRacedAdmissionAtCapacityDeniesCandidateWithoutEndingCreator(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(62_500, 0)}
	hub := newRoomTestHub(clock)
	roomID := roomTestID(21)
	creatorPeer := &fakePeer{}
	creator := attachRoomCreator(t, hub, roomID, roomTestOwner(21), creatorPeer)
	b, bPeer, _ := admitRoomMember(t, hub, roomID, creator, creatorPeer, "capacity-b", 2)
	_, _, _ = admitRoomMember(t, hub, roomID, creator, creatorPeer, "capacity-c", 3)

	open := func(connection string, value byte) (RoomSession, *fakePeer) {
		peer := &fakePeer{}
		candidate, err := hub.OpenCandidate(roomID, connection, peer)
		if err != nil {
			t.Fatalf("OpenCandidate(%s) = %v", connection, err)
		}
		if err := hub.JoinKnock(candidate, protocol.Message{
			Type: protocol.MessageJoinKnock, Version: protocol.NativeRoomMessageVersion,
			Sequence: 1, Payload: roomTestPayload(value),
		}); err != nil {
			t.Fatalf("JoinKnock(%s) = %v", connection, err)
		}
		return candidate, peer
	}
	d, _ := open("capacity-d", 4)
	e, ePeer := open("capacity-e", 5)
	if err := hub.AdmitCandidate(creator, protocol.Message{
		Type: protocol.MessageAdmitCandidate, Version: protocol.NativeRoomMessageVersion,
		CandidateHandle: d.Handle, Payload: nativeDescriptor(4),
	}); err != nil {
		t.Fatalf("first raced admission = %v", err)
	}
	if err := hub.AdmitCandidate(creator, protocol.Message{
		Type: protocol.MessageAdmitCandidate, Version: protocol.NativeRoomMessageVersion,
		CandidateHandle: e.Handle, Payload: nativeDescriptor(5),
	}); err != nil {
		t.Fatalf("capacity admission should be candidate-local: %v", err)
	}
	messages, closed, _ := ePeer.snapshot()
	if !closed || messages[len(messages)-1].Type != protocol.MessageDenyCandidate ||
		messages[len(messages)-1].Reason != "room-full" {
		t.Fatalf("raced candidate denial = %#v closed=%v", messages, closed)
	}
	creatorMessages, creatorClosed, _ := creatorPeer.snapshot()
	last := creatorMessages[len(creatorMessages)-1]
	if creatorClosed || last.Type != protocol.MessageDenyCandidate ||
		last.CandidateHandle != e.Handle {
		t.Fatalf("creator capacity cleanup = %#v closed=%v", last, creatorClosed)
	}
	// The creator and an unrelated established edge remain usable.
	pairID := roomPairID(t, roomID, creator.Handle, b.Handle)
	if err := hub.PairSignal(creator, protocol.Message{
		Type: protocol.MessagePairSignal, Version: protocol.NativeRoomMessageVersion,
		To: b.Handle, PairID: pairID, Sequence: 1, Payload: roomTestPayload(42),
	}); err != nil {
		t.Fatalf("healthy pair after capacity race = %v", err)
	}
	if _, bClosed, _ := bPeer.snapshot(); bClosed {
		t.Fatal("unrelated admitted member was closed")
	}
}

func TestRoomHubCandidateDetachNotifiesCreator(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(63_000, 0)}
	hub := newRoomTestHub(clock)
	roomID := roomTestID(20)
	creatorPeer := &fakePeer{}
	_ = attachRoomCreator(t, hub, roomID, roomTestOwner(20), creatorPeer)
	candidate, err := hub.OpenCandidate(roomID, "candidate-detach", &fakePeer{})
	if err != nil {
		t.Fatal(err)
	}
	hub.Detach(candidate)
	messages, _, _ := creatorPeer.snapshot()
	last := messages[len(messages)-1]
	if last.Type != protocol.MessageDenyCandidate || last.CandidateHandle != candidate.Handle {
		t.Fatalf("detach notification = %#v", last)
	}
}

func TestRoomHubCandidateExpiryNotifiesCreator(t *testing.T) {
	t.Parallel()
	clock := &hubClock{now: time.Unix(64_000, 0)}
	hub := newRoomTestHub(clock)
	roomID := roomTestID(22)
	creatorPeer := &fakePeer{}
	_ = attachRoomCreator(t, hub, roomID, roomTestOwner(22), creatorPeer)
	candidate, err := hub.OpenCandidate(
		roomID,
		"candidate-expiry",
		&fakePeer{},
	)
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(21 * time.Second)
	result := hub.Cleanup()
	if result.ExpiredPending != 1 {
		t.Fatalf("Cleanup() = %#v", result)
	}
	messages, _, _ := creatorPeer.snapshot()
	last := messages[len(messages)-1]
	if last.Type != protocol.MessageDenyCandidate ||
		last.CandidateHandle != candidate.Handle {
		t.Fatalf("expiry notification = %#v", last)
	}
}
