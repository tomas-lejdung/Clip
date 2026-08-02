package httpapi

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
	"github.com/tomas-lejdung/Clip/server/internal/signaling"
)

const maximumNativeRoomRequestBytes = 24 * 1_024

func (s *Service) nativeCapabilities(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, protocol.NativeRoomCapabilities{
		Protocol:                  protocol.Identifier,
		APIVersion:                protocol.NativeRoomAPIVersion,
		MessageVersion:            protocol.NativeRoomMessageVersion,
		ServerVersion:             s.config.ServerVersion,
		RoomPathTemplate:          "/api/native/v4/rooms/{room}",
		RoomWebSocketPathTemplate: "/api/native/v4/rooms/{room}/socket",
		MaximumMessageBytes:       protocol.MaximumMessageBytes,
		MaximumDescriptorBytes:    protocol.MaximumNativeDescriptorBytes,
		MaximumOpaquePayloadBytes: protocol.MaximumNativeOpaquePayloadBytes,
		MaximumPendingCandidates:  protocol.MaximumPendingCandidates,
		MaximumRoomMembers:        protocol.MaximumNativeRoomMembers,
		MaximumRooms:              s.config.MaximumRendezvous,
		ICEServers:                append([]protocol.ICEServer(nil), s.config.ICEServers...),
	})
}

func (s *Service) createNativeRoom(writer http.ResponseWriter, request *http.Request) {
	roomID, ok := nativeRoomID(writer, request)
	if !ok {
		return
	}
	if !s.admission.allowRendezvousLeaseOperation(s.admission.source(request)) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	var body protocol.NativeRoomRequest
	if err := protocol.DecodeStrictJSON(request.Body, maximumNativeRoomRequestBytes, &body); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	ownerHash, err := protocol.HashOwnerToken(body.OwnerToken)
	if err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_owner_token")
		return
	}
	result, err := s.roomHub.CreateRoom(roomID, ownerHash, body.CreatorHandle, body.Descriptor)
	if err != nil {
		switch {
		case errors.Is(err, signaling.ErrRoomConflict):
			writeError(writer, http.StatusConflict, "room_unavailable")
		case errors.Is(err, signaling.ErrRoomCapacity):
			writeError(writer, http.StatusServiceUnavailable, "room_capacity_reached")
		case errors.Is(err, protocol.ErrInvalidNativeDescriptor):
			writeError(writer, http.StatusBadRequest, "invalid_descriptor")
		case errors.Is(err, protocol.ErrInvalidMessage), errors.Is(err, protocol.ErrInvalidNativeRoomID):
			writeError(writer, http.StatusBadRequest, "invalid_request")
		default:
			writeError(writer, http.StatusInternalServerError, "server_error")
		}
		return
	}
	status := http.StatusOK
	if result.Created {
		status = http.StatusCreated
	}
	writeJSON(writer, status, protocol.NativeRoomResponse{
		RoomID: roomID, CreatorHandle: result.CreatorHandle,
		LeaseDurationSeconds: int64(result.Lease / time.Second),
	})
}

func (s *Service) nativeRoomStatus(writer http.ResponseWriter, request *http.Request) {
	roomID, ok := nativeRoomID(writer, request)
	if !ok {
		return
	}
	snapshot, found := s.roomHub.Snapshot(roomID)
	if !found {
		writeError(writer, http.StatusNotFound, "room_not_found")
		return
	}
	writeJSON(writer, http.StatusOK, protocol.NativeRoomStatus{
		RoomID: roomID, State: snapshot.State,
		RosterRevision: snapshot.RosterRevision, MemberCount: snapshot.MemberCount,
	})
}

func (s *Service) removeNativeRoom(writer http.ResponseWriter, request *http.Request) {
	roomID, ok := nativeRoomID(writer, request)
	if !ok {
		return
	}
	ownerHash, err := ownerHashFromAuthorization(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
		return
	}
	if err := s.roomHub.EndRoomByOwner(roomID, ownerHash, "creator-ended"); err != nil {
		writeRoomHTTPError(writer, err)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (s *Service) nativeRoomWebSocket(writer http.ResponseWriter, request *http.Request) {
	roomID, ok := nativeRoomID(writer, request)
	if !ok {
		return
	}
	source := s.admission.source(request)
	if !s.admission.allowWebSocket(source) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	if _, found := s.roomHub.Snapshot(roomID); !found {
		writeError(writer, http.StatusNotFound, "room_not_found")
		return
	}
	if !s.acquireCoordinatorConnection(source) {
		writeError(writer, http.StatusServiceUnavailable, "connection_capacity_reached")
		return
	}
	defer s.releaseCoordinatorConnection(source)

	connection, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	connectionID, err := randomIdentifier(16)
	if err != nil {
		_ = connection.Close()
		return
	}
	socket := signaling.NewSocket(connection, s.socketConfiguration(nil))
	if !s.trackSocket(socket) {
		socket.Start()
		socket.Close(signaling.CloseGoingAway, "server shutting down")
		socket.Wait()
		return
	}
	defer s.untrackSocket(socket)
	socket.Start()
	defer socket.Wait()
	defer socket.Close(signaling.CloseNormal, "room socket disconnected")

	session, err := s.attachNativeRoomSocket(roomID, connectionID, socket, request)
	if err != nil {
		_ = socket.Send(roomErrorMessage(err))
		socket.Close(signaling.ClosePolicyViolation, "room authentication rejected")
		return
	}
	defer func() { s.roomHub.Detach(session) }()
	_ = socket.ResetReadDeadline()

	for {
		message, readErr := socket.Read()
		if readErr != nil {
			s.rejectRoomReadError(socket, readErr)
			return
		}
		session = s.roomHub.ResolveSession(session)
		handleErr := s.handleNativeRoomMessage(session, message)
		if handleErr == nil {
			if message.Type == protocol.MessageLeaveRoom {
				return
			}
			continue
		}
		_ = socket.Send(roomMessageError(message, handleErr))
		switch {
		case errors.Is(handleErr, signaling.ErrRoomSequence),
			errors.Is(handleErr, signaling.ErrRoomMemberNotFound),
			errors.Is(handleErr, signaling.ErrRoomCandidateNotFound),
			errors.Is(handleErr, signaling.ErrRouteBackpressure):
			// A stale or unavailable pair is isolated to that pair. Keep the
			// participant socket and every unrelated P2P connection alive.
			continue
		default:
			socket.Close(signaling.CloseProtocolError, "room protocol error")
			return
		}
	}
}

func (s *Service) attachNativeRoomSocket(roomID, connectionID string, socket *signaling.Socket, request *http.Request) (signaling.RoomSession, error) {
	fields := strings.Fields(request.Header.Get("Authorization"))
	if len(fields) == 0 {
		return s.roomHub.OpenCandidate(roomID, connectionID, socket)
	}
	if len(fields) != 2 {
		return signaling.RoomSession{}, signaling.ErrRoomUnauthorized
	}
	switch {
	case strings.EqualFold(fields[0], "Bearer"):
		ownerHash, err := protocol.HashOwnerToken(fields[1])
		if err != nil {
			return signaling.RoomSession{}, signaling.ErrRoomUnauthorized
		}
		return s.roomHub.AttachCreator(roomID, ownerHash, connectionID, socket)
	case strings.EqualFold(fields[0], "Reconnect"):
		handle := strings.TrimSpace(request.Header.Get("X-Clip-Member-Handle"))
		hash, err := protocol.HashNativeReconnectCapability(fields[1])
		if err != nil || protocol.ValidateNativeMemberHandle(handle) != nil {
			return signaling.RoomSession{}, signaling.ErrRoomUnauthorized
		}
		return s.roomHub.ReconnectMember(roomID, handle, hash, connectionID, socket)
	default:
		return signaling.RoomSession{}, signaling.ErrRoomUnauthorized
	}
}

func (s *Service) handleNativeRoomMessage(session signaling.RoomSession, message protocol.Message) error {
	switch message.Type {
	case protocol.MessageJoinKnock:
		return s.roomHub.JoinKnock(session, message)
	case protocol.MessageAdmitCandidate:
		return s.roomHub.AdmitCandidate(session, message)
	case protocol.MessageDenyCandidate:
		return s.roomHub.DenyCandidate(session, message)
	case protocol.MessagePairSignal:
		return s.roomHub.PairSignal(session, message)
	case protocol.MessageLeaveRoom:
		if err := protocol.ValidateNativeRoomClientMessage(message); err != nil {
			return err
		}
		return s.roomHub.Leave(session)
	case protocol.MessageRemoveMember:
		if err := protocol.ValidateNativeRoomClientMessage(message); err != nil {
			return err
		}
		return s.roomHub.RemoveMember(session, message.To)
	default:
		return protocol.ErrInvalidMessage
	}
}

func (s *Service) rejectRoomReadError(socket *signaling.Socket, err error) {
	switch {
	case errors.Is(err, websocket.ErrReadLimit):
		socket.Close(signaling.CloseMessageTooBig, "message too large")
	case errors.Is(err, protocol.ErrInvalidMessage), errors.Is(err, signaling.ErrNonTextMessage):
		_ = socket.Send(protocol.RoomProtocolError("protocol_error", "The room message was rejected."))
		socket.Close(signaling.CloseProtocolError, "protocol error")
	}
}

func roomErrorMessage(err error) protocol.Message {
	switch {
	case errors.Is(err, signaling.ErrRoomCapacity):
		return protocol.RoomProtocolError("room_full", "The room already has four participants.")
	case errors.Is(err, signaling.ErrRoomCreatorOffline):
		return protocol.RoomProtocolError("creator_offline", "The room creator is reconnecting.")
	case errors.Is(err, signaling.ErrRoomSequence):
		return protocol.RoomProtocolError("sequence_rejected", "The opaque signaling sequence was rejected.")
	case errors.Is(err, signaling.ErrRoomMemberNotFound):
		return protocol.RoomProtocolError("member_unavailable", "The target room member is unavailable.")
	case errors.Is(err, signaling.ErrRoomCandidateNotFound):
		return protocol.RoomProtocolError("candidate_unavailable", "The room candidate is unavailable.")
	case errors.Is(err, signaling.ErrRoomNotCreator):
		return protocol.RoomProtocolError("creator_required", "Only the room creator can perform this operation.")
	case errors.Is(err, signaling.ErrRoomUnauthorized):
		return protocol.RoomProtocolError("room_unauthorized", "The room capability was rejected.")
	case errors.Is(err, signaling.ErrRouteBackpressure):
		return protocol.RoomProtocolError("route_backpressure", "The direct signaling route is temporarily busy.")
	default:
		return protocol.RoomProtocolError("protocol_error", "The room message was rejected.")
	}
}

func roomMessageError(message protocol.Message, err error) protocol.Message {
	response := roomErrorMessage(err)
	if message.Type != protocol.MessagePairSignal {
		return response
	}
	switch response.Code {
	case "sequence_rejected", "member_unavailable", "route_backpressure":
		return protocol.RoomPairProtocolError(response.Code, response.Text, message)
	default:
		return response
	}
}

func nativeRoomID(writer http.ResponseWriter, request *http.Request) (string, bool) {
	roomID := request.PathValue("room")
	if err := protocol.ValidateNativeRoomID(roomID); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_room")
		return "", false
	}
	return roomID, true
}

func writeRoomHTTPError(writer http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, signaling.ErrRoomNotFound):
		writeError(writer, http.StatusNotFound, "room_not_found")
	case errors.Is(err, signaling.ErrRoomUnauthorized):
		writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
	default:
		writeError(writer, http.StatusInternalServerError, "server_error")
	}
}
