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

func TestAllocationIsOwnerIdempotentAndRenewalRequiresOwner(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(100, 0)}
	rooms := newTestRegistry(clock, 10)
	allocated, err := rooms.AllocateGeneration("ROOM-ONE", ownerHash(1))
	if allocated.Lease != time.Minute || allocated.Generation == 0 || err != nil {
		t.Fatalf("first AllocateGeneration() = %#v, %v", allocated, err)
	}
	clock.Advance(20 * time.Second)
	repeated, err := rooms.AllocateGeneration("IGNORED-NAME", ownerHash(1))
	if err != nil || !repeated.Existing || repeated.Name != "ROOM-ONE" ||
		repeated.Generation != allocated.Generation {
		t.Fatalf("same-owner AllocateGeneration() = %#v, %v", repeated, err)
	}
	snapshot, found := rooms.Snapshot("ROOM-ONE")
	if !found || !snapshot.ExpiresAt.Equal(clock.Now().Add(time.Minute)) {
		t.Fatalf("idempotent allocation did not refresh lease: %#v, %v", snapshot, found)
	}
	if _, err := rooms.RenewGeneration("ROOM-ONE", ownerHash(2)); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("wrong-owner RenewGeneration() = %v", err)
	}
	renewed, err := rooms.RenewGeneration("ROOM-ONE", ownerHash(1))
	if err != nil || renewed.Generation != allocated.Generation {
		t.Fatalf("owner RenewGeneration() = %#v, %v", renewed, err)
	}
	snapshot, found = rooms.Snapshot("ROOM-ONE")
	if !found || !snapshot.ExpiresAt.Equal(clock.Now().Add(time.Minute)) {
		t.Fatalf("renewed snapshot = %#v, %v", snapshot, found)
	}
}

func TestHostGenerationProtectsReplacementFromStaleDisconnect(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(200, 0)}
	rooms := newTestRegistry(clock, 10)
	hash := ownerHash(3)
	_, _ = rooms.AllocateGeneration("ROOM-TWO", hash)
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
	_, _ = rooms.AllocateGeneration("ROOM-THREE", hash)
	clock.Advance(time.Minute)
	if rooms.Exists("ROOM-THREE") {
		t.Fatal("unattached room survived its lease")
	}

	_, _ = rooms.AllocateGeneration("ROOM-THREE", hash)
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
	_, _ = rooms.AllocateGeneration("ROOM-OLD", ownerHash(5))
	clock.Advance(time.Minute)
	allocated, err := rooms.AllocateGeneration("ROOM-NEW", ownerHash(6))
	if allocated.Generation == 0 || err != nil {
		t.Fatalf("AllocateGeneration after expiry = %#v, %v", allocated, err)
	}
	if rooms.Exists("ROOM-OLD") || !rooms.Exists("ROOM-NEW") {
		t.Fatal("capacity purge retained the wrong room")
	}
}

func TestDeleteAuthenticatesOwner(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(500, 0)}
	rooms := newTestRegistry(clock, 10)
	_, _ = rooms.AllocateGeneration("ROOM-FOUR", ownerHash(7))
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

func TestConcurrentAllocationAllowsExactlyOneClaim(t *testing.T) {
	clock := &manualClock{now: time.Unix(600, 0)}
	rooms := newTestRegistry(clock, 10)
	hash := ownerHash(9)
	var wait sync.WaitGroup
	results := make(chan struct {
		lease Lease
		err   error
	}, 64)
	for index := 0; index < 64; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			lease, err := rooms.AllocateGeneration("ROOM-FIVE", hash)
			results <- struct {
				lease Lease
				err   error
			}{lease: lease, err: err}
		}()
	}
	wait.Wait()
	close(results)
	var generation uint64
	newAllocations := 0
	for result := range results {
		if result.err != nil {
			t.Fatalf("concurrent AllocateGeneration() = %v", result.err)
		}
		if result.lease.Name != "ROOM-FIVE" {
			t.Fatalf("concurrent lease name = %q", result.lease.Name)
		}
		if generation == 0 {
			generation = result.lease.Generation
		} else if result.lease.Generation != generation {
			t.Fatalf(
				"concurrent generation = %d; want %d",
				result.lease.Generation,
				generation,
			)
		}
		if !result.lease.Existing {
			newAllocations++
		}
	}
	if newAllocations != 1 || rooms.Count() != 1 {
		t.Fatalf(
			"new allocations = %d, room count = %d; want 1, 1",
			newAllocations,
			rooms.Count(),
		)
	}
}

func TestRoomAndHostGenerationsAreMonotonicAcrossReuse(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(700, 0)}
	rooms := newTestRegistry(clock, 10)
	hash := ownerHash(10)
	first, err := rooms.AllocateGeneration("ROOM-SIX", hash)
	if err != nil || first.Generation == 0 {
		t.Fatalf("first allocation = %#v, %v", first, err)
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
	second, err := rooms.AllocateGeneration("ROOM-SIX", ownerHash(11))
	if err != nil || second.Generation <= first.Generation {
		t.Fatalf("reused allocation = %#v, %v", second, err)
	}
}

func TestExpiredAllocationReportsRemovedGeneration(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(800, 0)}
	rooms := newTestRegistry(clock, 1)
	first, err := rooms.AllocateGeneration("ROOM-SEVEN", ownerHash(12))
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(time.Minute)
	if rooms.Exists("ROOM-SEVEN") {
		t.Fatal("expired room remained live")
	}
	second, err := rooms.AllocateGeneration("ROOM-EIGHT", ownerHash(13))
	if err != nil {
		t.Fatal(err)
	}
	if len(second.ExpiredGenerations) != 1 || second.ExpiredGenerations[0] != (ExpiredRoom{Name: "ROOM-SEVEN", Generation: first.Generation}) {
		t.Fatalf("expired generations = %#v", second.ExpiredGenerations)
	}
}

func TestRenewalNeverCreatesOrRevivesExpiredRoom(t *testing.T) {
	t.Parallel()
	clock := &manualClock{now: time.Unix(900, 0)}
	rooms := newTestRegistry(clock, 10)
	if _, err := rooms.RenewGeneration("ROOM-MISSING", ownerHash(14)); !errors.Is(err, ErrRoomNotFound) {
		t.Fatalf("missing RenewGeneration() = %v", err)
	}

	first, err := rooms.AllocateGeneration("ROOM-EXPIRED", ownerHash(14))
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(time.Minute)
	renewal, err := rooms.RenewGeneration("ROOM-EXPIRED", ownerHash(14))
	if !errors.Is(err, ErrRoomNotFound) {
		t.Fatalf("expired RenewGeneration() = %#v, %v", renewal, err)
	}
	if len(renewal.ExpiredGenerations) != 1 ||
		renewal.ExpiredGenerations[0] != (ExpiredRoom{Name: "ROOM-EXPIRED", Generation: first.Generation}) {
		t.Fatalf("expired renewal generations = %#v", renewal.ExpiredGenerations)
	}
	if rooms.Exists("ROOM-EXPIRED") {
		t.Fatal("renewal revived an expired room")
	}
}
