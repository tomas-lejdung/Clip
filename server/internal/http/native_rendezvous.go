package httpapi

import (
	"errors"
	"net/http"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
	"github.com/tomas-lejdung/Clip/server/internal/signaling"
)

const maximumNativeSessionRequestBytes = 24 * 1_024

func (s *Service) nativeCapabilities(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, protocol.NativeRendezvousCapabilities{
		Protocol:                    "clip-native-rendezvous",
		APIVersion:                  protocol.NativeRendezvousAPIVersion,
		MessageVersion:              protocol.NativeMessageVersion,
		ServerVersion:               s.config.ServerVersion,
		RendezvousPathTemplate:      "/api/native/v1/rendezvous/{rendezvous}",
		HostWebSocketPathTemplate:   "/api/native/v1/rendezvous/{rendezvous}/host",
		ViewerWebSocketPathTemplate: "/api/native/v1/rendezvous/{rendezvous}/viewer",
		MaximumMessageBytes:         protocol.MaximumMessageBytes,
		MaximumDescriptorBytes:      protocol.MaximumNativeDescriptorBytes,
		MaximumOpaquePayloadBytes:   protocol.MaximumNativeOpaquePayloadBytes,
		MaximumPendingRoutes:        protocol.MaximumPendingViewersPerRoom,
		MaximumRendezvous:           s.config.MaximumRooms,
	})
}

func (s *Service) advertiseNativeRendezvous(writer http.ResponseWriter, request *http.Request) {
	rendezvousID, ok := nativeRendezvousID(writer, request)
	if !ok {
		return
	}
	if !s.admission.allowAdvertisement(s.admission.source(request)) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	var body protocol.NativeRendezvousRequest
	if err := protocol.DecodeStrictJSON(request.Body, maximumOwnerRequestBytes, &body); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	ownerHash, err := protocol.HashOwnerToken(body.OwnerToken)
	if err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_owner_token")
		return
	}
	advertisement, err := s.nativeRendezvous.Advertise(rendezvousID, ownerHash)
	if err != nil {
		switch {
		case errors.Is(err, signaling.ErrNativeRendezvousConflict):
			writeError(writer, http.StatusConflict, "rendezvous_unavailable")
		case errors.Is(err, signaling.ErrNativeCapacity):
			writeError(writer, http.StatusServiceUnavailable, "rendezvous_capacity_reached")
		default:
			writeError(writer, http.StatusInternalServerError, "server_error")
		}
		return
	}
	status := http.StatusOK
	if advertisement.Created {
		status = http.StatusCreated
	}
	writeJSON(writer, status, protocol.NativeRendezvousResponse{
		RendezvousID:         rendezvousID,
		LeaseDurationSeconds: int64(advertisement.Lease / time.Second),
	})
}

func (s *Service) nativeRendezvousStatus(writer http.ResponseWriter, request *http.Request) {
	rendezvousID, ok := nativeRendezvousID(writer, request)
	if !ok {
		return
	}
	snapshot, found := s.nativeRendezvous.Snapshot(rendezvousID)
	if !found {
		writeError(writer, http.StatusNotFound, "rendezvous_not_found")
		return
	}
	writeJSON(writer, http.StatusOK, protocol.NativeRendezvousStatus{
		RendezvousID: rendezvousID,
		State:        string(snapshot.State),
	})
}

func (s *Service) removeNativeRendezvous(writer http.ResponseWriter, request *http.Request) {
	rendezvousID, ok := nativeRendezvousID(writer, request)
	if !ok {
		return
	}
	ownerHash, err := ownerHashFromAuthorization(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
		return
	}
	if err := s.nativeRendezvous.Remove(rendezvousID, ownerHash); err != nil {
		writeNativeOwnerError(writer, err)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (s *Service) activateNativeSession(writer http.ResponseWriter, request *http.Request) {
	rendezvousID, ok := nativeRendezvousID(writer, request)
	if !ok {
		return
	}
	ownerHash, err := ownerHashFromAuthorization(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
		return
	}
	var body protocol.NativeSessionRequest
	if err := protocol.DecodeStrictJSON(request.Body, maximumNativeSessionRequestBytes, &body); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if err := protocol.ValidateNativeDescriptor(body.Descriptor); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_descriptor")
		return
	}
	if err := s.nativeRendezvous.Activate(rendezvousID, ownerHash, body.Descriptor); err != nil {
		switch {
		case errors.Is(err, signaling.ErrNativeHostUnavailable):
			writeError(writer, http.StatusConflict, "host_offline")
		default:
			writeNativeOwnerError(writer, err)
		}
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (s *Service) deactivateNativeSession(writer http.ResponseWriter, request *http.Request) {
	rendezvousID, ok := nativeRendezvousID(writer, request)
	if !ok {
		return
	}
	ownerHash, err := ownerHashFromAuthorization(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
		return
	}
	if err := s.nativeRendezvous.Deactivate(rendezvousID, ownerHash); err != nil {
		writeNativeOwnerError(writer, err)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (s *Service) nativeHostWebSocket(writer http.ResponseWriter, request *http.Request) {
	rendezvousID, ok := nativeRendezvousID(writer, request)
	if !ok {
		return
	}
	source := s.admission.source(request)
	if !s.admission.allowWebSocket(source) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	ownerHash, err := ownerHashFromAuthorization(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
		return
	}
	if err := s.nativeRendezvous.Authenticate(rendezvousID, ownerHash); err != nil {
		writeNativeOwnerError(writer, err)
		return
	}
	if !s.acquireHostConnection(source) {
		writeError(writer, http.StatusServiceUnavailable, "connection_capacity_reached")
		return
	}
	defer s.releaseHostConnection(source)

	connection, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	hostID, err := randomIdentifier(16)
	if err != nil {
		_ = connection.Close()
		return
	}
	socket := signaling.NewSocket(connection, s.socketConfiguration(func() {
		if !s.nativeRendezvous.RenewHost(rendezvousID, hostID) {
			_ = connection.Close()
		}
	}))
	if !s.trackSocket(socket) {
		socket.Start()
		socket.Close(signaling.CloseGoingAway, "server shutting down")
		socket.Wait()
		return
	}
	defer s.untrackSocket(socket)
	socket.Start()
	defer socket.Wait()
	defer socket.Close(signaling.CloseNormal, "native host disconnected")

	if err := s.nativeRendezvous.AttachHost(rendezvousID, ownerHash, hostID, socket); err != nil {
		_ = socket.Send(protocol.NativeErrorMessage("owner_unauthorized", "The rendezvous owner capability was rejected."))
		socket.Close(signaling.ClosePolicyViolation, "owner unauthorized")
		return
	}
	defer s.nativeRendezvous.DetachHost(rendezvousID, hostID)
	_ = socket.ResetReadDeadline()

	for {
		message, err := socket.Read()
		if err != nil {
			s.rejectNativeReadError(socket, err)
			return
		}
		switch message.Type {
		case protocol.MessageNativeRelay:
			err = s.nativeRendezvous.RelayFromHost(rendezvousID, hostID, message)
		case protocol.MessageNativeCloseRoute:
			if validateErr := protocol.ValidateNativeCloseRoute(message, true); validateErr != nil {
				err = validateErr
			} else {
				err = s.nativeRendezvous.CloseRouteFromHost(rendezvousID, hostID, message.RouteID, message.Reason)
			}
		default:
			err = protocol.ErrInvalidMessage
		}
		if err == nil {
			continue
		}
		if errors.Is(err, signaling.ErrRouteNotFound) || errors.Is(err, signaling.ErrStaleViewer) {
			_ = socket.Send(protocol.NativeErrorMessage("route_unavailable", "The native rendezvous route is no longer available."))
			continue
		}
		if errors.Is(err, signaling.ErrRouteBackpressure) {
			_ = socket.Send(protocol.NativeErrorMessage("route_backpressure", "The native rendezvous route exceeded its capacity."))
			continue
		}
		if errors.Is(err, signaling.ErrSequence) {
			_ = s.nativeRendezvous.CloseRouteFromHost(rendezvousID, hostID, message.RouteID, "relay sequence rejected")
			_ = socket.Send(protocol.NativeErrorMessage("route_sequence_rejected", "The native rendezvous route sequence was rejected."))
			continue
		}
		_ = socket.Send(protocol.NativeErrorMessage("protocol_error", "The native rendezvous message was rejected."))
		socket.Close(signaling.CloseProtocolError, "protocol error")
		return
	}
}

func (s *Service) nativeViewerWebSocket(writer http.ResponseWriter, request *http.Request) {
	rendezvousID, ok := nativeRendezvousID(writer, request)
	if !ok {
		return
	}
	source := s.admission.source(request)
	if !s.admission.allowWebSocket(source) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	snapshot, found := s.nativeRendezvous.Snapshot(rendezvousID)
	if !found {
		writeError(writer, http.StatusNotFound, "rendezvous_not_found")
		return
	}
	if snapshot.State != signaling.NativeRendezvousActive {
		writeError(writer, http.StatusConflict, "rendezvous_not_live")
		return
	}
	roomKey := "native:" + rendezvousID
	if !s.acquireViewerConnection(source, roomKey) {
		writeError(writer, http.StatusServiceUnavailable, "connection_capacity_reached")
		return
	}
	defer s.releaseViewerConnection(source, roomKey)

	connection, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
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
	defer socket.Close(signaling.CloseNormal, "native viewer disconnected")

	routeID, err := s.nativeRendezvous.OpenRoute(rendezvousID, socket)
	if err != nil {
		switch {
		case errors.Is(err, signaling.ErrRouteLimit):
			_ = socket.Send(protocol.NativeErrorMessage("route_capacity_reached", "The rendezvous has too many pending native viewers."))
		case errors.Is(err, signaling.ErrNativeNotLive):
			_ = socket.Send(protocol.NativeErrorMessage("rendezvous_not_live", "The host is not sharing."))
		default:
			_ = socket.Send(protocol.Message{Type: protocol.MessageNativeHostUnavailable, Version: protocol.NativeMessageVersion})
		}
		socket.Close(signaling.CloseTryAgainLater, "native route unavailable")
		return
	}
	defer s.nativeRendezvous.CloseViewerRoute(rendezvousID, routeID, socket, "native viewer disconnected")
	_ = socket.ResetReadDeadline()

	for {
		message, err := socket.Read()
		if err != nil {
			s.rejectNativeReadError(socket, err)
			return
		}
		switch message.Type {
		case protocol.MessageNativeRelay:
			err = s.nativeRendezvous.RelayFromViewer(rendezvousID, routeID, socket, message)
		case protocol.MessageNativeCloseRoute:
			if validateErr := protocol.ValidateNativeCloseRoute(message, false); validateErr != nil {
				err = validateErr
			} else {
				s.nativeRendezvous.CloseViewerRoute(rendezvousID, routeID, socket, "native viewer completed signaling")
				return
			}
		default:
			err = protocol.ErrInvalidMessage
		}
		if err == nil {
			continue
		}
		if errors.Is(err, signaling.ErrRouteBackpressure) || errors.Is(err, signaling.ErrNativeHostUnavailable) || errors.Is(err, signaling.ErrStaleViewer) {
			return
		}
		_ = socket.Send(protocol.NativeErrorMessage("protocol_error", "The native rendezvous message was rejected."))
		socket.Close(signaling.CloseProtocolError, "protocol error")
		return
	}
}

func (s *Service) rejectNativeReadError(socket *signaling.Socket, err error) {
	switch {
	case errors.Is(err, websocket.ErrReadLimit):
		socket.Close(signaling.CloseMessageTooBig, "message too large")
	case errors.Is(err, protocol.ErrInvalidMessage), errors.Is(err, signaling.ErrNonTextMessage):
		_ = socket.Send(protocol.NativeErrorMessage("protocol_error", "The native rendezvous message was rejected."))
		socket.Close(signaling.CloseProtocolError, "protocol error")
	}
}

func nativeRendezvousID(writer http.ResponseWriter, request *http.Request) (string, bool) {
	rendezvousID := request.PathValue("rendezvous")
	if err := protocol.ValidateNativeRendezvousID(rendezvousID); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_rendezvous")
		return "", false
	}
	return rendezvousID, true
}

func writeNativeOwnerError(writer http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, signaling.ErrNativeRendezvousNotFound):
		writeError(writer, http.StatusNotFound, "rendezvous_not_found")
	case errors.Is(err, signaling.ErrNativeUnauthorized):
		writeError(writer, http.StatusUnauthorized, "owner_unauthorized")
	default:
		writeError(writer, http.StatusInternalServerError, "server_error")
	}
}
