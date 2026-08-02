package signaling

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

var (
	ErrRoomNotFound          = errors.New("room not found")
	ErrRoomConflict          = errors.New("room is already owned")
	ErrRoomUnauthorized      = errors.New("room capability was rejected")
	ErrRoomCapacity          = errors.New("room capacity reached")
	ErrRoomCreatorOffline    = errors.New("room creator is offline")
	ErrRoomCandidateNotFound = errors.New("room candidate not found")
	ErrRoomMemberNotFound    = errors.New("room member not found")
	ErrRoomStaleSession      = errors.New("room session is stale")
	ErrRoomSequence          = errors.New("room signal sequence is not monotonic")
	ErrRoomNotCreator        = errors.New("operation requires the room creator")
)

type RoomConfiguration struct {
	LeaseDuration        time.Duration
	ReconnectGrace       time.Duration
	CandidateIdleTimeout time.Duration
	MaximumRooms         int
	MaximumPending       int
	Now                  func() time.Time
	Random               func([]byte) error
}

type RoomCreateResult struct {
	Created       bool
	CreatorHandle string
	Lease         time.Duration
}

type RoomStateSnapshot struct {
	RoomID         string
	State          string
	RosterRevision uint64
	MemberCount    int
}

type RoomCleanupResult struct {
	EndedRooms     int
	RemovedMembers int
	ExpiredPending int
}

type RoomSession struct {
	RoomID       string
	Handle       string
	ConnectionID string
	Candidate    bool
	Creator      bool
}

type roomMember struct {
	handle           string
	descriptor       string
	reconnectHash    [sha256.Size]byte
	hasReconnect     bool
	peer             Peer
	connectionID     string
	graceDeadline    time.Time
	outgoingSequence map[string]uint64
}

type roomCandidate struct {
	handle       string
	peer         Peer
	connectionID string
	sequence     uint64
	deadline     time.Time
}

type roomEntry struct {
	ownerHash       [sha256.Size]byte
	creatorHandle   string
	roomDescriptor  string
	revision        uint64
	members         map[string]*roomMember
	pending         map[string]*roomCandidate
	usedHandles     map[string]struct{}
	initialDeadline time.Time
}

// RoomHub is the authoritative, deliberately small room coordinator for the
// native-v4 complete mesh. It owns only opaque routing state. Each admitted
// participant still creates one direct WebRTC connection to every other
// admitted participant; media never traverses this hub.
type RoomHub struct {
	mu     sync.Mutex
	rooms  map[string]*roomEntry
	config RoomConfiguration
}

func NewRoomHub(configuration RoomConfiguration) *RoomHub {
	if configuration.LeaseDuration <= 0 {
		configuration.LeaseDuration = 5 * time.Minute
	}
	if configuration.ReconnectGrace <= 0 {
		configuration.ReconnectGrace = 30 * time.Second
	}
	if configuration.CandidateIdleTimeout <= 0 {
		configuration.CandidateIdleTimeout = 2 * time.Minute
	}
	if configuration.MaximumRooms <= 0 {
		configuration.MaximumRooms = 1_024
	}
	if configuration.MaximumPending <= 0 {
		configuration.MaximumPending = protocol.MaximumPendingCandidates
	}
	if configuration.Now == nil {
		configuration.Now = time.Now
	}
	if configuration.Random == nil {
		configuration.Random = func(destination []byte) error {
			_, err := rand.Read(destination)
			return err
		}
	}
	return &RoomHub{rooms: make(map[string]*roomEntry), config: configuration}
}

func (h *RoomHub) CreateRoom(roomID string, ownerHash [sha256.Size]byte, creatorHandle, descriptor string) (RoomCreateResult, error) {
	if err := protocol.ValidateNativeRoomID(roomID); err != nil {
		return RoomCreateResult{}, err
	}
	if err := protocol.ValidateNativeMemberHandle(creatorHandle); err != nil {
		return RoomCreateResult{}, err
	}
	if err := protocol.ValidateNativeDescriptor(descriptor); err != nil {
		return RoomCreateResult{}, err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.config.Now()
	if existing := h.rooms[roomID]; existing != nil {
		if !sameRoomCapability(existing.ownerHash, ownerHash) {
			return RoomCreateResult{Lease: h.config.LeaseDuration}, ErrRoomConflict
		}
		if existing.creatorHandle != creatorHandle || existing.roomDescriptor != descriptor {
			return RoomCreateResult{Lease: h.config.LeaseDuration}, ErrRoomConflict
		}
		return RoomCreateResult{CreatorHandle: existing.creatorHandle, Lease: h.config.LeaseDuration}, nil
	}
	if len(h.rooms) >= h.config.MaximumRooms {
		return RoomCreateResult{Lease: h.config.LeaseDuration}, ErrRoomCapacity
	}
	creator := &roomMember{
		handle: creatorHandle, descriptor: descriptor,
		outgoingSequence: make(map[string]uint64),
	}
	h.rooms[roomID] = &roomEntry{
		ownerHash: ownerHash, creatorHandle: creatorHandle, roomDescriptor: descriptor,
		revision: 1, members: map[string]*roomMember{creatorHandle: creator},
		pending:         make(map[string]*roomCandidate),
		usedHandles:     map[string]struct{}{creatorHandle: {}},
		initialDeadline: now.Add(h.config.LeaseDuration),
	}
	return RoomCreateResult{Created: true, CreatorHandle: creatorHandle, Lease: h.config.LeaseDuration}, nil
}

func (h *RoomHub) Snapshot(roomID string) (RoomStateSnapshot, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	room := h.rooms[roomID]
	if room == nil {
		return RoomStateSnapshot{}, false
	}
	state := "active"
	creator := room.members[room.creatorHandle]
	if creator == nil || creator.peer == nil {
		state = "creator-grace"
	}
	return RoomStateSnapshot{RoomID: roomID, State: state, RosterRevision: room.revision, MemberCount: len(room.members)}, true
}

func (h *RoomHub) AuthenticateOwner(roomID string, ownerHash [sha256.Size]byte) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	room := h.rooms[roomID]
	if room == nil {
		return ErrRoomNotFound
	}
	if !sameRoomCapability(room.ownerHash, ownerHash) {
		return ErrRoomUnauthorized
	}
	return nil
}

func (h *RoomHub) EndRoomByOwner(roomID string, ownerHash [sha256.Size]byte, reason string) error {
	h.mu.Lock()
	room := h.rooms[roomID]
	if room == nil {
		h.mu.Unlock()
		return ErrRoomNotFound
	}
	if !sameRoomCapability(room.ownerHash, ownerHash) {
		h.mu.Unlock()
		return ErrRoomUnauthorized
	}
	delete(h.rooms, roomID)
	peers := roomPeers(room)
	h.mu.Unlock()
	endRoomPeers(peers, reason)
	return nil
}

func (h *RoomHub) AttachCreator(roomID string, ownerHash [sha256.Size]byte, connectionID string, peer Peer) (RoomSession, error) {
	if connectionID == "" || peer == nil {
		return RoomSession{}, ErrRoomUnauthorized
	}
	h.mu.Lock()
	room := h.rooms[roomID]
	if room == nil {
		h.mu.Unlock()
		return RoomSession{}, ErrRoomNotFound
	}
	if !sameRoomCapability(room.ownerHash, ownerHash) {
		h.mu.Unlock()
		return RoomSession{}, ErrRoomUnauthorized
	}
	creator := room.members[room.creatorHandle]
	deadline := room.initialDeadline
	if creator != nil && !creator.graceDeadline.IsZero() {
		deadline = creator.graceDeadline
	}
	if !deadline.IsZero() && !h.config.Now().Before(deadline) {
		h.mu.Unlock()
		return RoomSession{}, ErrRoomNotFound
	}
	oldPeer := creator.peer
	creator.peer = peer
	creator.connectionID = connectionID
	creator.graceDeadline = time.Time{}
	room.initialDeadline = time.Time{}
	room.revision++
	snapshot := roomRosterSnapshot(room)
	session := RoomSession{RoomID: roomID, Handle: creator.handle, ConnectionID: connectionID, Creator: true}
	h.mu.Unlock()
	if oldPeer != nil && oldPeer != peer {
		oldPeer.Close(CloseGoingAway, "room creator reconnected")
	}
	if err := peer.Send(memberAdmitted(creator.handle, "", snapshot)); err != nil {
		h.Detach(session)
		return RoomSession{}, err
	}
	h.broadcastSnapshot(roomID)
	return session, nil
}

func (h *RoomHub) OpenCandidate(roomID, connectionID string, peer Peer) (RoomSession, error) {
	if connectionID == "" || peer == nil {
		return RoomSession{}, ErrRoomUnauthorized
	}
	h.mu.Lock()
	room := h.rooms[roomID]
	if room == nil {
		h.mu.Unlock()
		return RoomSession{}, ErrRoomNotFound
	}
	creator := room.members[room.creatorHandle]
	if creator == nil || creator.peer == nil {
		h.mu.Unlock()
		return RoomSession{}, ErrRoomCreatorOffline
	}
	if len(room.members) >= protocol.MaximumNativeRoomMembers || len(room.pending) >= h.config.MaximumPending {
		h.mu.Unlock()
		return RoomSession{}, ErrRoomCapacity
	}
	handle, err := h.uniqueHandleLocked(room)
	if err != nil {
		h.mu.Unlock()
		return RoomSession{}, err
	}
	candidate := &roomCandidate{handle: handle, peer: peer, connectionID: connectionID, deadline: h.config.Now().Add(h.config.CandidateIdleTimeout)}
	room.pending[handle] = candidate
	descriptor := room.roomDescriptor
	session := RoomSession{RoomID: roomID, Handle: handle, ConnectionID: connectionID, Candidate: true}
	h.mu.Unlock()
	if err := peer.Send(protocol.Message{Type: protocol.MessageCandidateOpened, Version: protocol.NativeRoomMessageVersion, CandidateHandle: handle, RoomDescriptor: descriptor}); err != nil {
		h.Detach(session)
		return RoomSession{}, err
	}
	return session, nil
}

func (h *RoomHub) ReconnectMember(roomID, handle string, reconnectHash [sha256.Size]byte, connectionID string, peer Peer) (RoomSession, error) {
	if protocol.ValidateNativeMemberHandle(handle) != nil || connectionID == "" || peer == nil {
		return RoomSession{}, ErrRoomUnauthorized
	}
	h.mu.Lock()
	room := h.rooms[roomID]
	if room == nil {
		h.mu.Unlock()
		return RoomSession{}, ErrRoomNotFound
	}
	member := room.members[handle]
	if member == nil || !member.hasReconnect || !sameRoomCapability(member.reconnectHash, reconnectHash) {
		h.mu.Unlock()
		return RoomSession{}, ErrRoomUnauthorized
	}
	if member.peer == nil && !member.graceDeadline.IsZero() && !h.config.Now().Before(member.graceDeadline) {
		h.mu.Unlock()
		return RoomSession{}, ErrRoomMemberNotFound
	}
	oldPeer := member.peer
	member.peer = peer
	member.connectionID = connectionID
	member.graceDeadline = time.Time{}
	room.revision++
	snapshot := roomRosterSnapshot(room)
	session := RoomSession{RoomID: roomID, Handle: handle, ConnectionID: connectionID}
	h.mu.Unlock()
	if oldPeer != nil && oldPeer != peer {
		oldPeer.Close(CloseGoingAway, "room member reconnected")
	}
	if err := peer.Send(memberAdmitted(handle, "", snapshot)); err != nil {
		h.Detach(session)
		return RoomSession{}, err
	}
	h.broadcastSnapshot(roomID)
	return session, nil
}

// ResolveSession promotes a pending socket to an admitted member session after
// the creator accepts it. The physical WebSocket is intentionally retained;
// admission must not reconnect or replace the candidate's transport.
func (h *RoomHub) ResolveSession(session RoomSession) RoomSession {
	if !session.Candidate {
		return session
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	room := h.rooms[session.RoomID]
	if room == nil {
		return session
	}
	member := room.members[session.Handle]
	if member != nil && member.connectionID == session.ConnectionID {
		session.Candidate = false
		session.Creator = session.Handle == room.creatorHandle
	}
	return session
}

func (h *RoomHub) JoinKnock(session RoomSession, message protocol.Message) error {
	if err := protocol.ValidateNativeRoomClientMessage(message); err != nil || !session.Candidate {
		if err != nil {
			return err
		}
		return protocol.ErrInvalidMessage
	}
	h.mu.Lock()
	room := h.rooms[session.RoomID]
	if room == nil {
		h.mu.Unlock()
		return ErrRoomNotFound
	}
	candidate := room.pending[session.Handle]
	if candidate == nil || candidate.connectionID != session.ConnectionID {
		h.mu.Unlock()
		return ErrRoomStaleSession
	}
	// A client may consume a sequence before an ambiguous WebSocket write is
	// lost. Accept gaps while still rejecting duplicates/replays; the creator
	// validates the encrypted knock and treats an identical retry idempotently.
	if message.Sequence <= candidate.sequence {
		h.mu.Unlock()
		return ErrRoomSequence
	}
	creator := room.members[room.creatorHandle]
	if creator == nil || creator.peer == nil {
		h.mu.Unlock()
		return ErrRoomCreatorOffline
	}
	forward := message
	forward.CandidateHandle = candidate.handle
	if err := creator.peer.Send(forward); err != nil {
		h.mu.Unlock()
		return ErrRoomCreatorOffline
	}
	candidate.sequence = message.Sequence
	candidate.deadline = h.config.Now().Add(h.config.CandidateIdleTimeout)
	h.mu.Unlock()
	return nil
}

func (h *RoomHub) AdmitCandidate(session RoomSession, message protocol.Message) error {
	if err := protocol.ValidateNativeRoomClientMessage(message); err != nil || !session.Creator {
		if err != nil {
			return err
		}
		return ErrRoomNotCreator
	}
	h.mu.Lock()
	room := h.rooms[session.RoomID]
	if !h.validMemberSessionLocked(room, session) {
		h.mu.Unlock()
		return ErrRoomStaleSession
	}
	candidate := room.pending[message.CandidateHandle]
	if candidate == nil {
		// Admission writes are ambiguous across reconnect. The promoted member
		// uses the exact candidate handle, so an identical replay is a no-op;
		// a conflicting descriptor remains rejected.
		if member := room.members[message.CandidateHandle]; member != nil {
			if member.descriptor == message.Payload {
				h.mu.Unlock()
				return nil
			}
			h.mu.Unlock()
			return protocol.ErrInvalidMessage
		}
		h.mu.Unlock()
		return ErrRoomCandidateNotFound
	}
	if len(room.members) >= protocol.MaximumNativeRoomMembers {
		delete(room.pending, candidate.handle)
		creator := room.members[room.creatorHandle]
		var creatorPeer Peer
		if creator != nil {
			creatorPeer = creator.peer
		}
		h.mu.Unlock()
		_ = candidate.peer.Send(protocol.Message{
			Type:    protocol.MessageDenyCandidate,
			Version: protocol.NativeRoomMessageVersion,
			Reason:  "room-full",
		})
		if creatorPeer != nil {
			_ = creatorPeer.Send(protocol.Message{
				Type:            protocol.MessageDenyCandidate,
				Version:         protocol.NativeRoomMessageVersion,
				CandidateHandle: candidate.handle,
				Reason:          "room-full",
			})
		}
		candidate.peer.Close(ClosePolicyViolation, "room full")
		return nil
	}
	capability, hash, err := h.newReconnectCapabilityLocked()
	if err != nil {
		h.mu.Unlock()
		return err
	}
	member := &roomMember{handle: candidate.handle, descriptor: message.Payload, reconnectHash: hash, hasReconnect: true, peer: candidate.peer, connectionID: candidate.connectionID, outgoingSequence: make(map[string]uint64)}
	room.members[member.handle] = member
	delete(room.pending, member.handle)
	room.revision++
	snapshot := roomRosterSnapshot(room)
	// Credential delivery is the admission commit point. Do not expose a
	// roster member whose reconnect capability never reached that member.
	// Keeping the hub lock across this one bounded socket enqueue makes the
	// mutation transactional with respect to snapshots and other admissions.
	if err := member.peer.Send(memberAdmitted(member.handle, capability, snapshot)); err != nil {
		delete(room.members, member.handle)
		room.revision--
		creator := room.members[room.creatorHandle]
		var creatorPeer Peer
		if creator != nil {
			creatorPeer = creator.peer
		}
		h.mu.Unlock()
		if creatorPeer != nil {
			_ = creatorPeer.Send(protocol.Message{
				Type:            protocol.MessageDenyCandidate,
				Version:         protocol.NativeRoomMessageVersion,
				CandidateHandle: member.handle,
				Reason:          "candidate-disconnected",
			})
		}
		member.peer.Close(CloseGoingAway, "room admission delivery failed")
		return nil
	}
	h.mu.Unlock()
	h.broadcastSnapshot(session.RoomID)
	return nil
}

func (h *RoomHub) DenyCandidate(session RoomSession, message protocol.Message) error {
	if err := protocol.ValidateNativeRoomClientMessage(message); err != nil || !session.Creator {
		if err != nil {
			return err
		}
		return ErrRoomNotCreator
	}
	h.mu.Lock()
	room := h.rooms[session.RoomID]
	if !h.validMemberSessionLocked(room, session) {
		h.mu.Unlock()
		return ErrRoomStaleSession
	}
	candidate := room.pending[message.CandidateHandle]
	if candidate == nil {
		// A denial has no durable payload after the candidate is removed. A
		// creator replay after an ambiguous write is therefore harmless unless
		// that handle has since become an admitted member.
		if room.members[message.CandidateHandle] == nil {
			h.mu.Unlock()
			return nil
		}
		h.mu.Unlock()
		return ErrRoomCandidateNotFound
	}
	delete(room.pending, message.CandidateHandle)
	h.mu.Unlock()
	_ = candidate.peer.Send(protocol.Message{Type: protocol.MessageDenyCandidate, Version: protocol.NativeRoomMessageVersion, Reason: message.Reason})
	candidate.peer.Close(ClosePolicyViolation, "room admission denied")
	return nil
}

func (h *RoomHub) PairSignal(session RoomSession, message protocol.Message) error {
	if err := protocol.ValidateNativeRoomClientMessage(message); err != nil || session.Candidate {
		if err != nil {
			return err
		}
		return protocol.ErrInvalidMessage
	}
	h.mu.Lock()
	room := h.rooms[session.RoomID]
	if !h.validMemberSessionLocked(room, session) {
		h.mu.Unlock()
		return ErrRoomStaleSession
	}
	sender := room.members[session.Handle]
	target := room.members[message.To]
	if target == nil || target.peer == nil || target.handle == sender.handle {
		h.mu.Unlock()
		return ErrRoomMemberNotFound
	}
	expectedPairID, err := protocol.NativePairID(session.RoomID, sender.handle, target.handle)
	if err != nil || message.PairID != expectedPairID {
		h.mu.Unlock()
		return protocol.ErrInvalidMessage
	}
	sequenceKey := message.To + "\x00" + message.PairID
	// Pair ciphertext is end-to-end sequenced. A WebSocket send can fail after
	// the client has sealed (and therefore consumed) a sequence number, so the
	// router must tolerate gaps while still rejecting duplicates and replays.
	// Join-knock sequencing remains exact because candidates can retry the same
	// opaque knock without advancing an encrypted pair channel.
	if message.Sequence <= sender.outgoingSequence[sequenceKey] {
		h.mu.Unlock()
		return ErrRoomSequence
	}
	forward := message
	forward.From = sender.handle
	if err := target.peer.Send(forward); err != nil {
		h.mu.Unlock()
		return ErrRouteBackpressure
	}
	sender.outgoingSequence[sequenceKey] = message.Sequence
	h.mu.Unlock()
	return nil
}

func (h *RoomHub) Leave(session RoomSession) error {
	if session.Candidate {
		h.Detach(session)
		return nil
	}
	if session.Creator {
		return h.EndRoom(session.RoomID, "creator-left")
	}
	h.mu.Lock()
	room := h.rooms[session.RoomID]
	if !h.validMemberSessionLocked(room, session) {
		h.mu.Unlock()
		return ErrRoomStaleSession
	}
	member := room.members[session.Handle]
	delete(room.members, session.Handle)
	room.revision++
	h.mu.Unlock()
	member.peer.Close(CloseNormal, "left room")
	h.broadcastSnapshot(session.RoomID)
	return nil
}

func (h *RoomHub) RemoveMember(session RoomSession, targetHandle string) error {
	if !session.Creator || targetHandle == session.Handle {
		return ErrRoomNotCreator
	}
	h.mu.Lock()
	room := h.rooms[session.RoomID]
	if !h.validMemberSessionLocked(room, session) {
		h.mu.Unlock()
		return ErrRoomStaleSession
	}
	target := room.members[targetHandle]
	if target == nil {
		h.mu.Unlock()
		return ErrRoomMemberNotFound
	}
	delete(room.members, targetHandle)
	room.revision++
	h.mu.Unlock()
	if target.peer != nil {
		_ = target.peer.Send(protocol.Message{Type: protocol.MessageRoomEnded, Version: protocol.NativeRoomMessageVersion, Reason: "removed"})
		target.peer.Close(ClosePolicyViolation, "removed from room")
	}
	h.broadcastSnapshot(session.RoomID)
	return nil
}

func (h *RoomHub) Detach(session RoomSession) {
	h.mu.Lock()
	room := h.rooms[session.RoomID]
	if room == nil {
		h.mu.Unlock()
		return
	}
	if session.Candidate {
		candidate := room.pending[session.Handle]
		if candidate != nil && candidate.connectionID == session.ConnectionID {
			delete(room.pending, session.Handle)
			creator := room.members[room.creatorHandle]
			var creatorPeer Peer
			if creator != nil {
				creatorPeer = creator.peer
			}
			h.mu.Unlock()
			if creatorPeer != nil {
				_ = creatorPeer.Send(protocol.Message{
					Type:            protocol.MessageDenyCandidate,
					Version:         protocol.NativeRoomMessageVersion,
					CandidateHandle: session.Handle,
					Reason:          "candidate-disconnected",
				})
			}
			return
		}
		// The creator may have admitted this still-open candidate socket. Fall
		// through so the admitted member receives normal reconnect grace.
	}
	member := room.members[session.Handle]
	if member == nil || member.connectionID != session.ConnectionID {
		h.mu.Unlock()
		return
	}
	member.peer = nil
	member.connectionID = ""
	member.graceDeadline = h.config.Now().Add(h.config.ReconnectGrace)
	room.revision++
	h.mu.Unlock()
	h.broadcastSnapshot(session.RoomID)
}

func (h *RoomHub) EndRoom(roomID, reason string) error {
	h.mu.Lock()
	room := h.rooms[roomID]
	if room == nil {
		h.mu.Unlock()
		return ErrRoomNotFound
	}
	delete(h.rooms, roomID)
	peers := roomPeers(room)
	h.mu.Unlock()
	endRoomPeers(peers, reason)
	return nil
}

func (h *RoomHub) Cleanup() RoomCleanupResult {
	h.mu.Lock()
	result := RoomCleanupResult{}
	ended := make([][]Peer, 0)
	type expiredCandidate struct {
		peer    Peer
		creator Peer
		handle  string
	}
	expiredCandidates := make([]expiredCandidate, 0)
	changedRoomIDs := make([]string, 0)
	now := h.config.Now()
	h.expireLocked(now, func(peers []Peer) { ended = append(ended, peers) })
	for roomID, room := range h.rooms {
		changed := false
		for handle, candidate := range room.pending {
			if !now.Before(candidate.deadline) {
				delete(room.pending, handle)
				var creatorPeer Peer
				if creator := room.members[room.creatorHandle]; creator != nil {
					creatorPeer = creator.peer
				}
				expiredCandidates = append(expiredCandidates, expiredCandidate{
					peer:    candidate.peer,
					creator: creatorPeer,
					handle:  handle,
				})
				result.ExpiredPending++
			}
		}
		for handle, member := range room.members {
			if handle == room.creatorHandle || member.peer != nil || member.graceDeadline.IsZero() || now.Before(member.graceDeadline) {
				continue
			}
			delete(room.members, handle)
			result.RemovedMembers++
			changed = true
		}
		if changed {
			room.revision++
			changedRoomIDs = append(changedRoomIDs, roomID)
		}
	}
	h.mu.Unlock()
	for _, candidate := range expiredCandidates {
		if candidate.creator != nil {
			_ = candidate.creator.Send(protocol.Message{
				Type:            protocol.MessageDenyCandidate,
				Version:         protocol.NativeRoomMessageVersion,
				CandidateHandle: candidate.handle,
				Reason:          "candidate-expired",
			})
		}
		candidate.peer.Close(CloseGoingAway, "room candidate timeout")
	}
	for _, peers := range ended {
		endRoomPeers(peers, "creator-reconnect-expired")
		result.EndedRooms++
	}
	for _, id := range changedRoomIDs {
		h.broadcastSnapshot(id)
	}
	return result
}

func (h *RoomHub) Shutdown(reason string) {
	h.mu.Lock()
	rooms := h.rooms
	h.rooms = make(map[string]*roomEntry)
	h.mu.Unlock()
	for _, room := range rooms {
		endRoomPeers(roomPeers(room), reason)
	}
}

func (h *RoomHub) broadcastSnapshot(roomID string) {
	h.mu.Lock()
	room := h.rooms[roomID]
	if room == nil {
		h.mu.Unlock()
		return
	}
	snapshot := roomRosterSnapshot(room)
	peers := roomMemberPeers(room)
	h.mu.Unlock()
	message := protocol.Message{Type: protocol.MessageRosterSnapshot, Version: protocol.NativeRoomMessageVersion, Roster: &snapshot}
	for _, peer := range peers {
		if err := peer.Send(message); err != nil {
			peer.Close(CloseGoingAway, "room roster delivery failed")
		}
	}
}

func (h *RoomHub) validMemberSessionLocked(room *roomEntry, session RoomSession) bool {
	if room == nil {
		return false
	}
	member := room.members[session.Handle]
	return member != nil && member.peer != nil && member.connectionID == session.ConnectionID
}

func (h *RoomHub) uniqueHandleLocked(room *roomEntry) (string, error) {
	for attempt := 0; attempt < 32; attempt++ {
		bytes := make([]byte, protocol.NativeMemberHandleBytes)
		if err := h.config.Random(bytes); err != nil {
			return "", fmt.Errorf("generate member handle: %w", err)
		}
		handle := base64.RawURLEncoding.EncodeToString(bytes)
		collision := false
		for _, existing := range h.rooms {
			if _, found := existing.usedHandles[handle]; found {
				collision = true
				break
			}
		}
		if !collision {
			if room != nil {
				room.usedHandles[handle] = struct{}{}
			}
			return handle, nil
		}
	}
	return "", errors.New("could not allocate unique member handle")
}

func (h *RoomHub) newReconnectCapabilityLocked() (string, [sha256.Size]byte, error) {
	bytes := make([]byte, protocol.NativeReconnectCapabilityBytes)
	if err := h.config.Random(bytes); err != nil {
		return "", [sha256.Size]byte{}, err
	}
	return base64.RawURLEncoding.EncodeToString(bytes), sha256.Sum256(bytes), nil
}

func (h *RoomHub) expireLocked(now time.Time, ended func([]Peer)) {
	for roomID, room := range h.rooms {
		creator := room.members[room.creatorHandle]
		deadline := room.initialDeadline
		if creator != nil && !creator.graceDeadline.IsZero() {
			deadline = creator.graceDeadline
		}
		if deadline.IsZero() || now.Before(deadline) {
			continue
		}
		delete(h.rooms, roomID)
		if ended != nil {
			ended(roomPeers(room))
		}
	}
}

func roomRosterSnapshot(room *roomEntry) protocol.RosterSnapshot {
	handles := make([]string, 0, len(room.members))
	for handle := range room.members {
		handles = append(handles, handle)
	}
	sort.Strings(handles)
	members := make([]protocol.RosterMember, 0, len(handles))
	for _, handle := range handles {
		member := room.members[handle]
		members = append(members, protocol.RosterMember{Handle: handle, Descriptor: member.descriptor, Connected: member.peer != nil})
	}
	return protocol.RosterSnapshot{Revision: room.revision, CreatorHandle: room.creatorHandle, Members: members}
}

func memberAdmitted(handle, capability string, snapshot protocol.RosterSnapshot) protocol.Message {
	return protocol.Message{Type: protocol.MessageMemberAdmitted, Version: protocol.NativeRoomMessageVersion, MemberHandle: handle, ReconnectCapability: capability, Roster: &snapshot}
}

func roomMemberPeers(room *roomEntry) []Peer {
	peers := make([]Peer, 0, len(room.members))
	for _, member := range room.members {
		if member.peer != nil {
			peers = append(peers, member.peer)
		}
	}
	return peers
}

func roomPeers(room *roomEntry) []Peer {
	peers := roomMemberPeers(room)
	for _, candidate := range room.pending {
		peers = append(peers, candidate.peer)
	}
	return peers
}

func endRoomPeers(peers []Peer, reason string) {
	message := protocol.Message{Type: protocol.MessageRoomEnded, Version: protocol.NativeRoomMessageVersion, Reason: boundedReason(reason)}
	for _, peer := range peers {
		_ = peer.Send(message)
		peer.Close(CloseGoingAway, reason)
	}
}

func sameRoomCapability(left, right [sha256.Size]byte) bool {
	return subtle.ConstantTimeCompare(left[:], right[:]) == 1
}
