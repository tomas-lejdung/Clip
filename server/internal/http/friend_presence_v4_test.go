package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

func friendPresenceRoutingID(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat(
		[]byte{value},
		protocol.NativeFriendPresenceRoutingIDBytes,
	))
}

func friendPresencePayload(value byte, count int) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, count))
}

func TestFriendPresenceStoreIsBoundedMonotonicAndExpires(t *testing.T) {
	now := time.Unix(2_000_000_000, 0)
	store := newFriendPresenceStore(1)
	store.now = func() time.Time { return now }
	route := friendPresenceRoutingID(1)
	first := protocol.NativeFriendPresence{
		Revision: 1, ExpiresAtMilliseconds: now.Add(4 * time.Minute).UnixMilli(),
		Payload: friendPresencePayload(2, 128),
	}
	created, err := store.put(route, first)
	if err != nil || !created {
		t.Fatalf("first put = created %t, %v", created, err)
	}
	created, err = store.put(route, first)
	if err != nil || created {
		t.Fatalf("idempotent retry = created %t, %v", created, err)
	}

	conflict := first
	conflict.Payload = friendPresencePayload(3, 128)
	if _, err = store.put(route, conflict); !errors.Is(err, errFriendPresenceRevision) {
		t.Fatalf("same revision replacement error = %v", err)
	}
	stale := first
	stale.Revision = 0
	if _, err = store.put(route, stale); !errors.Is(err, protocol.ErrInvalidNativeFriendPresence) {
		t.Fatalf("zero revision error = %v", err)
	}
	second := first
	second.Revision = 2
	second.ExpiresAtMilliseconds = now.Add(time.Minute).UnixMilli()
	second.Payload = friendPresencePayload(4, 128)
	if _, err = store.put(route, second); err != nil {
		t.Fatalf("second revision error = %v", err)
	}
	if _, err = store.put(route, first); !errors.Is(err, errFriendPresenceRevision) {
		t.Fatalf("stale revision error = %v", err)
	}
	if got, err := store.get(route); err != nil || got != second {
		t.Fatalf("current record = %#v, %v", got, err)
	}

	other := first
	if _, err = store.put(friendPresenceRoutingID(9), other); !errors.Is(err, errFriendPresenceCapacity) {
		t.Fatalf("capacity error = %v", err)
	}
	tooLong := second
	tooLong.Revision = 3
	tooLong.ExpiresAtMilliseconds = now.Add(
		((protocol.MaximumNativeFriendPresenceLifetimeSeconds +
			protocol.MaximumNativeFriendPresenceClockSkewSeconds) * time.Second) + time.Millisecond,
	).UnixMilli()
	if _, err = store.put(route, tooLong); !errors.Is(err, protocol.ErrInvalidNativeFriendPresence) {
		t.Fatalf("lifetime error = %v", err)
	}

	now = time.UnixMilli(second.ExpiresAtMilliseconds)
	if _, err = store.get(route); !errors.Is(err, errFriendPresenceExpired) {
		t.Fatalf("expired get error = %v", err)
	}
	if _, err = store.put(route, first); !errors.Is(err, errFriendPresenceRevision) {
		t.Fatalf("post-expiry stale revision error = %v", err)
	}
	if removed := store.cleanup(); removed != 0 {
		t.Fatalf("revision tombstone was removed early; cleanup removed %d", removed)
	}
	now = time.UnixMilli(second.ExpiresAtMilliseconds).Add(
		(protocol.MaximumNativeFriendPresenceLifetimeSeconds +
			protocol.MaximumNativeFriendPresenceClockSkewSeconds) * time.Second,
	)
	if removed := store.cleanup(); removed != 1 {
		t.Fatalf("expired tombstone cleanup removed %d", removed)
	}
}

func TestFriendPresenceHTTPPublishesOnlyOpaqueState(t *testing.T) {
	service, server := newHTTPTestServer(t)
	now := time.Unix(2_000_000_000, 0)
	service.friendPresence.now = func() time.Time { return now }
	route := friendPresenceRoutingID(5)
	record := protocol.NativeFriendPresence{
		Revision: 7, ExpiresAtMilliseconds: now.Add(2 * time.Minute).UnixMilli(),
		Payload: friendPresencePayload(6, 512),
	}
	endpoint := server.URL + "/api/native/v4/friends/" + route + "/presence"

	put := func(value protocol.NativeFriendPresence) *http.Response {
		t.Helper()
		body, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		request, err := http.NewRequest(http.MethodPut, endpoint, bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("Content-Type", "application/json")
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		return response
	}

	response := put(record)
	response.Body.Close()
	if response.StatusCode != http.StatusCreated ||
		response.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("initial publish = %d, %#v", response.StatusCode, response.Header)
	}
	response = put(record)
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("idempotent publish = %d", response.StatusCode)
	}

	response, err := http.Get(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	var fetched protocol.NativeFriendPresence
	if err := json.NewDecoder(response.Body).Decode(&fetched); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK || fetched != record ||
		response.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("fetched = %d, %#v", response.StatusCode, fetched)
	}

	conflict := record
	conflict.Payload = friendPresencePayload(7, 512)
	response = put(conflict)
	response.Body.Close()
	if response.StatusCode != http.StatusConflict {
		t.Fatalf("conflicting replay = %d", response.StatusCode)
	}

	now = time.UnixMilli(record.ExpiresAtMilliseconds)
	response, err = http.Get(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("expired fetch = %d", response.StatusCode)
	}
}

func TestFriendPresenceHTTPRejectsMalformedRoutesBodiesAndBounds(t *testing.T) {
	service, server := newHTTPTestServer(t)
	now := time.Unix(2_000_000_000, 0)
	service.friendPresence.now = func() time.Time { return now }
	validRoute := friendPresenceRoutingID(8)
	endpoint := server.URL + "/api/native/v4/friends/" + validRoute + "/presence"

	tests := []struct {
		name string
		path string
		body any
	}{
		{"route", "/api/native/v4/friends/not-canonical/presence", protocol.NativeFriendPresence{
			Revision: 1, ExpiresAtMilliseconds: now.Add(time.Minute).UnixMilli(),
			Payload: friendPresencePayload(1, 64),
		}},
		{"unknown field", endpoint, map[string]any{
			"revision": 1, "expiresAtMilliseconds": now.Add(time.Minute).UnixMilli(),
			"payload": friendPresencePayload(1, 64), "identity": "must-not-exist",
		}},
		{"payload size", endpoint, protocol.NativeFriendPresence{
			Revision: 1, ExpiresAtMilliseconds: now.Add(time.Minute).UnixMilli(),
			Payload: friendPresencePayload(
				1,
				protocol.MaximumNativeFriendPresencePayloadBytes+1,
			),
		}},
		{"expiry", endpoint, protocol.NativeFriendPresence{
			Revision: 1,
			ExpiresAtMilliseconds: now.Add(
				(protocol.MaximumNativeFriendPresenceLifetimeSeconds +
					protocol.MaximumNativeFriendPresenceClockSkewSeconds + 1) * time.Second,
			).UnixMilli(),
			Payload: friendPresencePayload(1, 64),
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			body, err := json.Marshal(test.body)
			if err != nil {
				t.Fatal(err)
			}
			path := test.path
			if path[0] == '/' {
				path = server.URL + path
			}
			request, err := http.NewRequest(http.MethodPut, path, bytes.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			response.Body.Close()
			if response.StatusCode != http.StatusBadRequest {
				t.Fatalf("status = %d", response.StatusCode)
			}
		})
	}
}
