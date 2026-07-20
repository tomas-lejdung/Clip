package registry

import (
	"errors"
	"sync"
	"testing"
	"time"
)

type manualClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *manualClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *manualClock) Advance(duration time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(duration)
	c.mu.Unlock()
}

func ownerHash(value byte) [32]byte {
	var hash [32]byte
	for index := range hash {
		hash[index] = value
	}
	return hash
}

func newTestRegistry(clock *manualClock, maximumRooms int) *Registry {
	return New(Configuration{
		LeaseDuration:  time.Minute,
		ReconnectGrace: 10 * time.Second,
		MaximumRooms:   maximumRooms,
		Now:            clock.Now,
	})
}

func TestAdvertiseIsIdempotentOnlyForOwner(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(100, 0)}
	rooms := newTestRegistry(clock, 10)
	created, lease, err := rooms.Advertise("ROOM-ONE", ownerHash(1))
	if !created || lease != time.Minute || err != nil {
		t.Fatalf("first Advertise() = %v, %v, %v", created, lease, err)
	}
	clock.Advance(20 * time.Second)
	created, _, err = rooms.Advertise("ROOM-ONE", ownerHash(1))
	if created || err != nil {
		t.Fatalf("idempotent Advertise() = %v, %v", created, err)
	}
	if _, _, err := rooms.Advertise("ROOM-ONE", ownerHash(2)); !errors.Is(err, ErrRoomConflict) {
		t.Fatalf("conflicting Advertise() = %v", err)
	}
	snapshot, found := rooms.Snapshot("ROOM-ONE")
	if !found || !snapshot.ExpiresAt.Equal(clock.Now().Add(time.Minute)) {
		t.Fatalf("renewed snapshot = %#v, %v", snapshot, found)
	}
}

func TestHostGenerationProtectsReplacementFromStaleDisconnect(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(200, 0)}
	rooms := newTestRegistry(clock, 10)
	hash := ownerHash(3)
	_, _, _ = rooms.Advertise("ROOM-TWO", hash)
	if replaced, err := rooms.AttachHost("ROOM-TWO", hash, "host-1"); err != nil || replaced != "" {
		t.Fatalf("AttachHost(host-1) = %q, %v", replaced, err)
	}
	if replaced, err := rooms.AttachHost("ROOM-TWO", hash, "host-2"); err != nil || replaced != "host-1" {
		t.Fatalf("AttachHost(host-2) = %q, %v", replaced, err)
	}
	if rooms.DetachHost("ROOM-TWO", "host-1") {
		t.Fatal("stale host detached replacement")
	}
	snapshot, found := rooms.Snapshot("ROOM-TWO")
	if !found || !snapshot.HostConnected || snapshot.HostID != "host-2" {
		t.Fatalf("replacement snapshot = %#v, %v", snapshot, found)
	}
	if !rooms.DetachHost("ROOM-TWO", "host-2") {
		t.Fatal("current host did not detach")
	}
	snapshot, found = rooms.Snapshot("ROOM-TWO")
	if !found || snapshot.HostConnected || !snapshot.ExpiresAt.Equal(clock.Now().Add(10*time.Second)) {
		t.Fatalf("grace snapshot = %#v, %v", snapshot, found)
	}
}

func TestLeaseLifecycleAndCleanup(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(300, 0)}
	rooms := newTestRegistry(clock, 10)
	hash := ownerHash(4)
	_, _, _ = rooms.Advertise("ROOM-THREE", hash)
	clock.Advance(time.Minute)
	if rooms.Exists("ROOM-THREE") {
		t.Fatal("unattached room survived its lease")
	}

	_, _, _ = rooms.Advertise("ROOM-THREE", hash)
	_, _ = rooms.AttachHost("ROOM-THREE", hash, "host")
	clock.Advance(24 * time.Hour)
	if !rooms.Exists("ROOM-THREE") {
		t.Fatal("connected host room expired")
	}
	rooms.DetachHost("ROOM-THREE", "host")
	clock.Advance(9 * time.Second)
	if removed := rooms.CleanupExpired(); len(removed) != 0 {
		t.Fatalf("room removed before reconnect grace: %v", removed)
	}
	clock.Advance(time.Second)
	removed := rooms.CleanupExpired()
	if len(removed) != 1 || removed[0] != "ROOM-THREE" {
		t.Fatalf("CleanupExpired() = %v", removed)
	}
}

func TestCapacityPurgesExpiredRooms(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(400, 0)}
	rooms := newTestRegistry(clock, 1)
	_, _, _ = rooms.Advertise("ROOM-OLD", ownerHash(5))
	clock.Advance(time.Minute)
	created, _, err := rooms.Advertise("ROOM-NEW", ownerHash(6))
	if !created || err != nil {
		t.Fatalf("Advertise after expiry = %v, %v", created, err)
	}
	if rooms.Exists("ROOM-OLD") || !rooms.Exists("ROOM-NEW") {
		t.Fatal("capacity purge retained the wrong room")
	}
}

func TestDeleteAuthenticatesOwner(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(500, 0)}
	rooms := newTestRegistry(clock, 10)
	_, _, _ = rooms.Advertise("ROOM-FOUR", ownerHash(7))
	if err := rooms.Delete("ROOM-FOUR", ownerHash(8)); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("Delete(wrong owner) = %v", err)
	}
	if err := rooms.Delete("ROOM-FOUR", ownerHash(7)); err != nil {
		t.Fatalf("Delete(owner) = %v", err)
	}
	if rooms.Exists("ROOM-FOUR") {
		t.Fatal("deleted room still exists")
	}
}

func TestConcurrentIdempotentAdvertisementIsRaceSafe(t *testing.T) {
	clock := &manualClock{now: time.Unix(600, 0)}
	rooms := newTestRegistry(clock, 10)
	hash := ownerHash(9)
	var wait sync.WaitGroup
	errorsChannel := make(chan error, 64)
	for index := 0; index < 64; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, _, err := rooms.Advertise("ROOM-FIVE", hash)
			errorsChannel <- err
		}()
	}
	wait.Wait()
	close(errorsChannel)
	for err := range errorsChannel {
		if err != nil {
			t.Fatalf("concurrent Advertise() = %v", err)
		}
	}
	if rooms.Count() != 1 {
		t.Fatalf("room count = %d; want 1", rooms.Count())
	}
}

func TestRoomAndHostGenerationsAreMonotonicAcrossReuse(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(700, 0)}
	rooms := newTestRegistry(clock, 10)
	hash := ownerHash(10)
	first, err := rooms.AdvertiseGeneration("ROOM-SIX", hash)
	if err != nil || !first.Created || first.Generation == 0 {
		t.Fatalf("first advertisement = %#v, %v", first, err)
	}
	firstHost, err := rooms.AttachHostGeneration("ROOM-SIX", hash, "host-1")
	if err != nil {
		t.Fatal(err)
	}
	secondHost, err := rooms.AttachHostGeneration("ROOM-SIX", hash, "host-2")
	if err != nil {
		t.Fatal(err)
	}
	if firstHost.RoomGeneration != first.Generation || secondHost.RoomGeneration != first.Generation || secondHost.HostGeneration <= firstHost.HostGeneration {
		t.Fatalf("host generations = first:%#v second:%#v", firstHost, secondHost)
	}
	removedGeneration, err := rooms.DeleteGeneration("ROOM-SIX", hash)
	if err != nil || removedGeneration != first.Generation {
		t.Fatalf("DeleteGeneration() = %d, %v", removedGeneration, err)
	}
	second, err := rooms.AdvertiseGeneration("ROOM-SIX", ownerHash(11))
	if err != nil || !second.Created || second.Generation <= first.Generation {
		t.Fatalf("reused advertisement = %#v, %v", second, err)
	}
}

func TestExpiredAdvertisementReportsRemovedGeneration(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(800, 0)}
	rooms := newTestRegistry(clock, 1)
	first, err := rooms.AdvertiseGeneration("ROOM-SEVEN", ownerHash(12))
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(time.Minute)
	if rooms.Exists("ROOM-SEVEN") {
		t.Fatal("expired room remained live")
	}
	second, err := rooms.AdvertiseGeneration("ROOM-EIGHT", ownerHash(13))
	if err != nil {
		t.Fatal(err)
	}
	if len(second.ExpiredGenerations) != 1 || second.ExpiredGenerations[0] != (ExpiredRoom{Name: "ROOM-SEVEN", Generation: first.Generation}) {
		t.Fatalf("expired generations = %#v", second.ExpiredGenerations)
	}
}
