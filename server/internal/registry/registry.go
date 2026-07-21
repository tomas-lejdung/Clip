package registry

import (
	"crypto/subtle"
	"errors"
	"sync"
	"time"
)

var (
	ErrRoomNotFound   = errors.New("room not found")
	ErrRoomConflict   = errors.New("room name is already owned")
	ErrUnauthorized   = errors.New("owner capability was rejected")
	ErrRoomLimit      = errors.New("room capacity reached")
	ErrHostGeneration = errors.New("host generation is invalid")
)

type Configuration struct {
	LeaseDuration  time.Duration
	ReconnectGrace time.Duration
	MaximumRooms   int
	Now            func() time.Time
}

type room struct {
	name           string
	ownerHash      [32]byte
	generation     uint64
	expiresAt      time.Time
	hostID         string
	hostGeneration uint64
	hostConnected  bool
}

type Snapshot struct {
	Name           string
	Generation     uint64
	ExpiresAt      time.Time
	HostConnected  bool
	HostID         string
	HostGeneration uint64
}

type HostAttachment struct {
	RoomGeneration     uint64
	HostGeneration     uint64
	ReplacedHostID     string
	ReplacedGeneration uint64
}

type ExpiredRoom struct {
	Name       string
	Generation uint64
}

type Advertisement struct {
	Created            bool
	Lease              time.Duration
	Generation         uint64
	ExpiredGenerations []ExpiredRoom
}

// Registry is an in-memory, single-replica room lease registry. It stores only
// an owner-token hash and routing lifecycle metadata.
type Registry struct {
	mu             sync.RWMutex
	rooms          map[string]*room
	nextGeneration uint64
	config         Configuration
}

func New(configuration Configuration) *Registry {
	if configuration.Now == nil {
		configuration.Now = time.Now
	}
	return &Registry{
		rooms:  make(map[string]*room),
		config: configuration,
	}
}

// Advertise atomically claims a room name. Repeating the operation with the
// same capability is idempotent and renews an unattached lease.
func (r *Registry) Advertise(name string, ownerHash [32]byte) (created bool, lease time.Duration, err error) {
	advertisement, err := r.AdvertiseGeneration(name, ownerHash)
	return advertisement.Created, advertisement.Lease, err
}

func (r *Registry) AdvertiseGeneration(name string, ownerHash [32]byte) (Advertisement, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	result := Advertisement{Lease: r.config.LeaseDuration}
	now := r.config.Now()
	if existing, found := r.rooms[name]; found {
		if r.expiredLocked(existing, now) {
			delete(r.rooms, name)
			result.ExpiredGenerations = append(result.ExpiredGenerations, ExpiredRoom{Name: name, Generation: existing.generation})
		} else {
			if !sameHash(existing.ownerHash, ownerHash) {
				return result, ErrRoomConflict
			}
			if !existing.hostConnected {
				existing.expiresAt = now.Add(r.config.LeaseDuration)
			}
			result.Generation = existing.generation
			return result, nil
		}
	}

	if len(r.rooms) >= r.config.MaximumRooms {
		result.ExpiredGenerations = append(result.ExpiredGenerations, r.purgeExpiredLocked(now)...)
	}
	if len(r.rooms) >= r.config.MaximumRooms {
		return result, ErrRoomLimit
	}
	generation := r.nextGenerationLocked()
	r.rooms[name] = &room{
		name:       name,
		ownerHash:  ownerHash,
		generation: generation,
		expiresAt:  now.Add(r.config.LeaseDuration),
	}
	result.Created = true
	result.Generation = generation
	return result, nil
}

func (r *Registry) Authenticate(name string, ownerHash [32]byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	current, found := r.liveRoomLocked(name, r.config.Now())
	if !found {
		return ErrRoomNotFound
	}
	if !sameHash(current.ownerHash, ownerHash) {
		return ErrUnauthorized
	}
	return nil
}

// AttachHost authenticates and records a new host generation. A later
// disconnect from a replaced socket cannot detach the replacement generation.
func (r *Registry) AttachHost(name string, ownerHash [32]byte, hostID string) (replacedHostID string, err error) {
	attachment, err := r.AttachHostGeneration(name, ownerHash, hostID)
	return attachment.ReplacedHostID, err
}

func (r *Registry) AttachHostGeneration(name string, ownerHash [32]byte, hostID string) (HostAttachment, error) {
	if hostID == "" {
		return HostAttachment{}, ErrHostGeneration
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	current, found := r.liveRoomLocked(name, r.config.Now())
	if !found {
		return HostAttachment{}, ErrRoomNotFound
	}
	if !sameHash(current.ownerHash, ownerHash) {
		return HostAttachment{}, ErrUnauthorized
	}
	attachment := HostAttachment{
		RoomGeneration:     current.generation,
		HostGeneration:     r.nextGenerationLocked(),
		ReplacedHostID:     current.hostID,
		ReplacedGeneration: current.hostGeneration,
	}
	current.hostID = hostID
	current.hostGeneration = attachment.HostGeneration
	current.hostConnected = true
	current.expiresAt = time.Time{}
	return attachment, nil
}

func (r *Registry) RenewHost(name, hostID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	current, found := r.rooms[name]
	return found && current.hostConnected && current.hostID == hostID
}

func (r *Registry) DetachHost(name, hostID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	current, found := r.rooms[name]
	if !found || !current.hostConnected || current.hostID != hostID {
		return false
	}
	current.hostConnected = false
	current.hostID = ""
	current.hostGeneration = 0
	current.expiresAt = r.config.Now().Add(r.config.ReconnectGrace)
	return true
}

func (r *Registry) Delete(name string, ownerHash [32]byte) error {
	_, err := r.DeleteGeneration(name, ownerHash)
	return err
}

func (r *Registry) DeleteGeneration(name string, ownerHash [32]byte) (uint64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	current, found := r.liveRoomLocked(name, r.config.Now())
	if !found {
		return 0, ErrRoomNotFound
	}
	if !sameHash(current.ownerHash, ownerHash) {
		return 0, ErrUnauthorized
	}
	generation := current.generation
	delete(r.rooms, name)
	return generation, nil
}

func (r *Registry) Exists(name string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, found := r.liveRoomLocked(name, r.config.Now())
	return found
}

func (r *Registry) Snapshot(name string) (Snapshot, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	current, found := r.liveRoomLocked(name, r.config.Now())
	if !found {
		return Snapshot{}, false
	}
	return Snapshot{
		Name:           current.name,
		Generation:     current.generation,
		ExpiresAt:      current.expiresAt,
		HostConnected:  current.hostConnected,
		HostID:         current.hostID,
		HostGeneration: current.hostGeneration,
	}, true
}

func (r *Registry) Generation(name string) (uint64, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	current, found := r.liveRoomLocked(name, r.config.Now())
	if !found {
		return 0, false
	}
	return current.generation, true
}

// CleanupExpired removes only disconnected room leases and returns their names
// so the signaling hub can independently close any stale routing state.
func (r *Registry) CleanupExpired() []string {
	expired := r.CleanupExpiredGenerations()
	removed := make([]string, 0, len(expired))
	for _, current := range expired {
		removed = append(removed, current.Name)
	}
	return removed
}

func (r *Registry) CleanupExpiredGenerations() []ExpiredRoom {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.config.Now()
	removed := make([]ExpiredRoom, 0)
	for name, current := range r.rooms {
		if r.expiredLocked(current, now) {
			delete(r.rooms, name)
			removed = append(removed, ExpiredRoom{Name: name, Generation: current.generation})
		}
	}
	return removed
}

func (r *Registry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.rooms)
}

func (r *Registry) Names() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.purgeExpiredLocked(r.config.Now())
	names := make([]string, 0, len(r.rooms))
	for name := range r.rooms {
		names = append(names, name)
	}
	return names
}

func (r *Registry) liveRoomLocked(name string, now time.Time) (*room, bool) {
	current, found := r.rooms[name]
	if !found {
		return nil, false
	}
	if r.expiredLocked(current, now) {
		return nil, false
	}
	return current, true
}

func (r *Registry) expiredLocked(current *room, now time.Time) bool {
	return !current.hostConnected && !current.expiresAt.IsZero() && !now.Before(current.expiresAt)
}

func (r *Registry) purgeExpiredLocked(now time.Time) []ExpiredRoom {
	removed := make([]ExpiredRoom, 0)
	for name, current := range r.rooms {
		if r.expiredLocked(current, now) {
			delete(r.rooms, name)
			removed = append(removed, ExpiredRoom{Name: name, Generation: current.generation})
		}
	}
	return removed
}

func (r *Registry) nextGenerationLocked() uint64 {
	r.nextGeneration++
	if r.nextGeneration == 0 {
		r.nextGeneration++
	}
	return r.nextGeneration
}

func sameHash(left, right [32]byte) bool {
	return subtle.ConstantTimeCompare(left[:], right[:]) == 1
}
