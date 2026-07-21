package httpapi

import (
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/config"
)

func TestSourceRateLimitsResetAfterWindow(t *testing.T) {
	configuration := config.Default("test")
	configuration.RoomAdvertisementsPerMinute = 2
	configuration.WebSocketUpgradesPerMinute = 2
	admission := newSourceAdmission(configuration)
	now := time.Unix(1_000, 0)
	admission.now = func() time.Time { return now }

	if !admission.allowAdvertisement("198.51.100.1") || !admission.allowAdvertisement("198.51.100.1") {
		t.Fatal("allowed advertisement burst was rejected")
	}
	if admission.allowAdvertisement("198.51.100.1") {
		t.Fatal("advertisement rate limit was not enforced")
	}
	if !admission.allowAdvertisement("198.51.100.2") {
		t.Fatal("one source consumed another source's rate limit")
	}
	now = now.Add(time.Minute)
	if !admission.allowAdvertisement("198.51.100.1") {
		t.Fatal("advertisement limit did not reset")
	}
}

func TestConnectionAdmissionReservesCapacityForHosts(t *testing.T) {
	configuration := config.Default("test")
	configuration.MaximumConnections = 5
	configuration.ReservedHostConnections = 2
	configuration.MaximumConnectionsPerSource = 5
	service := &Service{
		connections:       make(chan struct{}, configuration.MaximumConnections),
		viewerConnections: make(chan struct{}, configuration.MaximumConnections-configuration.ReservedHostConnections),
		viewerRooms:       make(map[string]int),
		admission:         newSourceAdmission(configuration),
	}

	for index := 0; index < 3; index++ {
		if !service.acquireViewerConnection("198.51.100.1", "ROOM") {
			t.Fatalf("viewer %d was rejected", index)
		}
	}
	if service.acquireViewerConnection("198.51.100.1", "ROOM") {
		t.Fatal("viewer consumed reserved host capacity")
	}
	if !service.acquireHostConnection("198.51.100.1") || !service.acquireHostConnection("198.51.100.1") {
		t.Fatal("reserved host capacity was unavailable")
	}
	if service.acquireHostConnection("198.51.100.1") {
		t.Fatal("host exceeded total connection capacity")
	}

	for index := 0; index < 3; index++ {
		service.releaseViewerConnection("198.51.100.1", "ROOM")
	}
	service.releaseHostConnection("198.51.100.1")
	service.releaseHostConnection("198.51.100.1")
}

func TestPerSourceConnectionCapacityIsIndependent(t *testing.T) {
	configuration := config.Default("test")
	configuration.MaximumConnections = 10
	configuration.ReservedHostConnections = 2
	configuration.MaximumConnectionsPerSource = 2
	service := &Service{
		connections:       make(chan struct{}, configuration.MaximumConnections),
		viewerConnections: make(chan struct{}, configuration.MaximumConnections-configuration.ReservedHostConnections),
		viewerRooms:       make(map[string]int),
		admission:         newSourceAdmission(configuration),
	}
	if !service.acquireHostConnection("198.51.100.1") || !service.acquireHostConnection("198.51.100.1") {
		t.Fatal("source could not use its connection allowance")
	}
	if service.acquireHostConnection("198.51.100.1") {
		t.Fatal("source exceeded its connection allowance")
	}
	if !service.acquireHostConnection("198.51.100.2") {
		t.Fatal("one source consumed another source's connection allowance")
	}
	service.releaseHostConnection("198.51.100.1")
	service.releaseHostConnection("198.51.100.1")
	service.releaseHostConnection("198.51.100.2")
}

func TestPerRoomPreHelloCapacityIsBounded(t *testing.T) {
	configuration := config.Default("test")
	configuration.MaximumConnections = 16
	configuration.ReservedHostConnections = 2
	configuration.MaximumConnectionsPerSource = 16
	service := &Service{
		connections:       make(chan struct{}, configuration.MaximumConnections),
		viewerConnections: make(chan struct{}, configuration.MaximumConnections-configuration.ReservedHostConnections),
		viewerRooms:       make(map[string]int),
		admission:         newSourceAdmission(configuration),
	}

	for index := 0; index < 8; index++ {
		if !service.acquireViewerConnection("203.0.113.1", "ROOM-ONE") {
			t.Fatalf("viewer %d was rejected", index)
		}
	}
	if service.acquireViewerConnection("203.0.113.1", "ROOM-ONE") {
		t.Fatal("ninth pre-hello viewer was accepted")
	}
	if !service.acquireViewerConnection("203.0.113.1", "ROOM-TWO") {
		t.Fatal("one room consumed another room's pre-hello capacity")
	}

	for index := 0; index < 8; index++ {
		service.releaseViewerConnection("203.0.113.1", "ROOM-ONE")
	}
	service.releaseViewerConnection("203.0.113.1", "ROOM-TWO")
}

func TestForwardedSourceRequiresExplicitTrustedProxy(t *testing.T) {
	untrusted := newSourceAdmission(config.Default("test"))
	request := &http.Request{
		RemoteAddr: "203.0.113.10:443",
		Header:     http.Header{"X-Forwarded-For": []string{"198.51.100.20"}},
	}
	if source := untrusted.source(request); source != "203.0.113.10" {
		t.Fatalf("untrusted forwarded source = %q", source)
	}

	configuration := config.Default("test")
	configuration.TrustedProxyCIDRs = []string{"10.0.0.0/8"}
	trusted := newSourceAdmission(configuration)
	request.RemoteAddr = "10.0.0.2:443"
	request.Header.Set("X-Forwarded-For", "198.51.100.20, 10.0.0.1")
	if source := trusted.source(request); source != "198.51.100.20" {
		t.Fatalf("trusted forwarded source = %q", source)
	}
}

func TestAdvertisementHandlerReturnsTooManyRequestsPerSource(t *testing.T) {
	configuration := testConfiguration()
	configuration.RoomAdvertisementsPerMinute = 2
	service, err := New(configuration, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	body := fmt.Sprintf(`{"ownerToken":%q}`, ownerToken(21))
	for attempt, expected := range []int{http.StatusCreated, http.StatusOK, http.StatusTooManyRequests} {
		request := httptest.NewRequest(http.MethodPut, "/api/v1/rooms/RATE-ROOM", strings.NewReader(body))
		request.RemoteAddr = "198.51.100.44:1234"
		recorder := httptest.NewRecorder()
		service.Handler().ServeHTTP(recorder, request)
		if recorder.Code != expected {
			t.Fatalf("attempt %d status = %d; want %d", attempt+1, recorder.Code, expected)
		}
	}
}
