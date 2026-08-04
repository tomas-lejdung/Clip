package httpapi

import (
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

const (
	maximumNativeFriendPresenceRequestBytes = 24 * 1_024
	// Account for the map entry, strings, timestamps, and struct metadata in
	// addition to the exact key and opaque payload bytes. This is deliberately
	// conservative: the budget is a memory-safety boundary, not wire metadata.
	friendPresenceRecordOverheadBytes = 128
)

var (
	errFriendPresenceCapacity = errors.New("friend presence capacity reached")
	errFriendPresenceExpired  = errors.New("friend presence expired")
	errFriendPresenceNotFound = errors.New("friend presence not found")
	errFriendPresenceRevision = errors.New("friend presence revision conflict")
)

type friendPresenceStore struct {
	mu             sync.Mutex
	records        map[string]storedFriendPresence
	maximumRecords int
	maximumBytes   int
	totalBytes     int
	now            func() time.Time
}

type storedFriendPresence struct {
	record      protocol.NativeFriendPresence
	retainUntil time.Time
	byteSize    int
}

func newFriendPresenceStore(maximumRecords, maximumBytes int) *friendPresenceStore {
	if maximumRecords < 1 {
		maximumRecords = 1
	}
	if maximumBytes < 1 {
		maximumBytes = maximumNativeFriendPresenceRequestBytes
	}
	return &friendPresenceStore{
		records:        make(map[string]storedFriendPresence),
		maximumRecords: maximumRecords,
		maximumBytes:   maximumBytes,
		now:            time.Now,
	}
}

func friendPresenceStoredBytes(
	routingID string,
	record protocol.NativeFriendPresence,
) int {
	return friendPresenceRecordOverheadBytes + len(routingID) + len(record.Payload)
}

func (s *friendPresenceStore) put(
	routingID string,
	record protocol.NativeFriendPresence,
) (bool, error) {
	if protocol.ValidateNativeFriendPresenceRoutingID(routingID) != nil ||
		protocol.ValidateNativeFriendPresence(record) != nil {
		return false, protocol.ErrInvalidNativeFriendPresence
	}
	now := s.now()
	expiresAt := time.UnixMilli(record.ExpiresAtMilliseconds)
	if !expiresAt.After(now) ||
		expiresAt.After(now.Add(
			(protocol.MaximumNativeFriendPresenceLifetimeSeconds+
				protocol.MaximumNativeFriendPresenceClockSkewSeconds)*time.Second,
		)) {
		return false, protocol.ErrInvalidNativeFriendPresence
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.cleanupLocked(now)
	current, found := s.records[routingID]
	if found {
		switch {
		case record.Revision < current.record.Revision:
			return false, errFriendPresenceRevision
		case record.Revision == current.record.Revision:
			if record != current.record {
				return false, errFriendPresenceRevision
			}
			return false, nil
		}
	} else if len(s.records) >= s.maximumRecords {
		return false, errFriendPresenceCapacity
	}
	byteSize := friendPresenceStoredBytes(routingID, record)
	projectedBytes := s.totalBytes + byteSize
	if found {
		projectedBytes -= current.byteSize
	}
	// Reject instead of evicting a live record. Routing IDs are opaque and the
	// server cannot determine which friendship would be safest to discard.
	if projectedBytes > s.maximumBytes {
		return false, errFriendPresenceCapacity
	}
	s.records[routingID] = storedFriendPresence{
		record: record,
		retainUntil: expiresAt.Add(
			(protocol.MaximumNativeFriendPresenceLifetimeSeconds +
				protocol.MaximumNativeFriendPresenceClockSkewSeconds) * time.Second,
		),
		byteSize: byteSize,
	}
	s.totalBytes = projectedBytes
	return !found, nil
}

func (s *friendPresenceStore) get(
	routingID string,
) (protocol.NativeFriendPresence, error) {
	if protocol.ValidateNativeFriendPresenceRoutingID(routingID) != nil {
		return protocol.NativeFriendPresence{}, protocol.ErrInvalidNativeFriendPresence
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	stored, found := s.records[routingID]
	if !found {
		return protocol.NativeFriendPresence{}, errFriendPresenceNotFound
	}
	if !time.UnixMilli(stored.record.ExpiresAtMilliseconds).After(s.now()) {
		return protocol.NativeFriendPresence{}, errFriendPresenceExpired
	}
	return stored.record, nil
}

func (s *friendPresenceStore) cleanup() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cleanupLocked(s.now())
}

func (s *friendPresenceStore) cleanupLocked(now time.Time) int {
	removed := 0
	for routingID, stored := range s.records {
		if !stored.retainUntil.After(now) {
			delete(s.records, routingID)
			s.totalBytes -= stored.byteSize
			removed++
		}
	}
	return removed
}

func (s *Service) putNativeFriendPresence(
	writer http.ResponseWriter,
	request *http.Request,
) {
	routingID := request.PathValue("routing")
	if protocol.ValidateNativeFriendPresenceRoutingID(routingID) != nil {
		writeError(writer, http.StatusBadRequest, "invalid_presence_route")
		return
	}
	if !s.admission.allowRendezvousLeaseOperation(s.admission.source(request)) {
		writer.Header().Set("Retry-After", "60")
		writeError(writer, http.StatusTooManyRequests, "source_rate_limited")
		return
	}
	var record protocol.NativeFriendPresence
	if err := protocol.DecodeStrictJSON(
		request.Body,
		maximumNativeFriendPresenceRequestBytes,
		&record,
	); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_presence")
		return
	}
	created, err := s.friendPresence.put(routingID, record)
	if err != nil {
		switch {
		case errors.Is(err, errFriendPresenceRevision):
			writeError(writer, http.StatusConflict, "presence_revision_conflict")
		case errors.Is(err, errFriendPresenceCapacity):
			writeError(writer, http.StatusServiceUnavailable, "presence_capacity_reached")
		default:
			writeError(writer, http.StatusBadRequest, "invalid_presence")
		}
		return
	}
	writer.Header().Set("Cache-Control", "no-store")
	if created {
		writer.WriteHeader(http.StatusCreated)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (s *Service) getNativeFriendPresence(
	writer http.ResponseWriter,
	request *http.Request,
) {
	record, err := s.friendPresence.get(request.PathValue("routing"))
	if err != nil {
		switch {
		case errors.Is(err, errFriendPresenceNotFound),
			errors.Is(err, errFriendPresenceExpired):
			writeError(writer, http.StatusNotFound, "presence_not_found")
		default:
			writeError(writer, http.StatusBadRequest, "invalid_presence_route")
		}
		return
	}
	writer.Header().Set("Cache-Control", "no-store")
	writeJSON(writer, http.StatusOK, record)
}
