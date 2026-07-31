package httpapi

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/config"
)

func TestSourceRateLimitsResetAfterWindow(t *testing.T) {
	configuration := config.Default("test")
	configuration.RendezvousLeaseOperationsPerMinute = 2
	configuration.WebSocketUpgradesPerMinute = 2
	admission := newSourceAdmission(configuration)
	now := time.Unix(1_000, 0)
	admission.now = func() time.Time { return now }

	if !admission.allowRendezvousLeaseOperation("198.51.100.1") ||
		!admission.allowRendezvousLeaseOperation("198.51.100.1") {
		t.Fatal("allowed rendezvous-lease operation burst was rejected")
	}
	if admission.allowRendezvousLeaseOperation("198.51.100.1") {
		t.Fatal("rendezvous-lease operation rate limit was not enforced")
	}
	if !admission.allowRendezvousLeaseOperation("198.51.100.2") {
		t.Fatal("one source consumed another source's rate limit")
	}
	now = now.Add(time.Minute)
	if !admission.allowRendezvousLeaseOperation("198.51.100.1") {
		t.Fatal("rendezvous-lease operation limit did not reset")
	}
}

func admissionTestService(configuration config.Config) *Service {
	return &Service{
		connections: make(chan struct{}, configuration.MaximumConnections),
		candidateConnections: make(
			chan struct{},
			configuration.MaximumConnections-
				configuration.ReservedCoordinatorConnections,
		),
		candidateRoutes: make(map[string]int),
		admission:       newSourceAdmission(configuration),
	}
}

func TestConnectionAdmissionReservesCapacityForCoordinator(t *testing.T) {
	configuration := config.Default("test")
	configuration.MaximumConnections = 5
	configuration.ReservedCoordinatorConnections = 2
	configuration.MaximumConnectionsPerSource = 5
	service := admissionTestService(configuration)

	for index := 0; index < 3; index++ {
		if !service.acquireCandidateConnection("198.51.100.1", "RENDEZVOUS") {
			t.Fatalf("candidate %d was rejected", index)
		}
	}
	if service.acquireCandidateConnection("198.51.100.1", "RENDEZVOUS") {
		t.Fatal("candidate consumed reserved coordinator capacity")
	}
	if !service.acquireCoordinatorConnection("198.51.100.1") ||
		!service.acquireCoordinatorConnection("198.51.100.1") {
		t.Fatal("reserved coordinator capacity was unavailable")
	}
	if service.acquireCoordinatorConnection("198.51.100.1") {
		t.Fatal("coordinator exceeded total connection capacity")
	}

	for range 3 {
		service.releaseCandidateConnection("198.51.100.1", "RENDEZVOUS")
	}
	service.releaseCoordinatorConnection("198.51.100.1")
	service.releaseCoordinatorConnection("198.51.100.1")
}

func TestPerSourceConnectionCapacityIsIndependent(t *testing.T) {
	configuration := config.Default("test")
	configuration.MaximumConnections = 10
	configuration.ReservedCoordinatorConnections = 2
	configuration.MaximumConnectionsPerSource = 2
	service := admissionTestService(configuration)

	if !service.acquireCoordinatorConnection("198.51.100.1") ||
		!service.acquireCoordinatorConnection("198.51.100.1") {
		t.Fatal("source could not use its connection allowance")
	}
	if service.acquireCoordinatorConnection("198.51.100.1") {
		t.Fatal("source exceeded its connection allowance")
	}
	if !service.acquireCoordinatorConnection("198.51.100.2") {
		t.Fatal("one source consumed another source's connection allowance")
	}
	service.releaseCoordinatorConnection("198.51.100.1")
	service.releaseCoordinatorConnection("198.51.100.1")
	service.releaseCoordinatorConnection("198.51.100.2")
}

func TestPerRendezvousCandidateCapacityIsBounded(t *testing.T) {
	configuration := config.Default("test")
	configuration.MaximumConnections = 16
	configuration.ReservedCoordinatorConnections = 2
	configuration.MaximumConnectionsPerSource = 16
	service := admissionTestService(configuration)

	for index := 0; index < 8; index++ {
		if !service.acquireCandidateConnection("203.0.113.1", "ONE") {
			t.Fatalf("candidate %d was rejected", index)
		}
	}
	if service.acquireCandidateConnection("203.0.113.1", "ONE") {
		t.Fatal("ninth candidate route was accepted")
	}
	if !service.acquireCandidateConnection("203.0.113.1", "TWO") {
		t.Fatal("one rendezvous consumed another rendezvous's route capacity")
	}

	for range 8 {
		service.releaseCandidateConnection("203.0.113.1", "ONE")
	}
	service.releaseCandidateConnection("203.0.113.1", "TWO")
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

func TestRendezvousLeaseHandlerReturnsTooManyRequestsPerSource(
	t *testing.T,
) {
	configuration := testConfiguration()
	configuration.RendezvousLeaseOperationsPerMinute = 2
	service, err := New(configuration)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	body := fmt.Sprintf(`{"ownerToken":%q}`, ownerToken(21))
	rendezvousID := testNativeRendezvousID(22)
	for attempt, expected := range []int{
		http.StatusCreated,
		http.StatusOK,
		http.StatusTooManyRequests,
	} {
		request := httptest.NewRequest(
			http.MethodPut,
			"/api/native/v3/rendezvous/"+rendezvousID,
			strings.NewReader(body),
		)
		request.RemoteAddr = "198.51.100.44:1234"
		recorder := httptest.NewRecorder()
		service.Handler().ServeHTTP(recorder, request)
		if recorder.Code != expected {
			t.Fatalf(
				"attempt %d status = %d; want %d",
				attempt+1,
				recorder.Code,
				expected,
			)
		}
	}
}
