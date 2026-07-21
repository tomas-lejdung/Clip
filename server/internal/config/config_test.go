package config

import (
	"strings"
	"testing"
	"time"
)

var environmentNames = []string{
	"PORT",
	"CLIP_SERVER_ADDRESS",
	"CLIP_SERVER_LEASE_DURATION",
	"CLIP_SERVER_RECONNECT_GRACE",
	"CLIP_SERVER_ROUTE_IDLE_TIMEOUT",
	"CLIP_SERVER_MAXIMUM_ROOMS",
	"CLIP_SERVER_MAXIMUM_CONNECTIONS",
	"CLIP_SERVER_RESERVED_HOST_CONNECTIONS",
	"CLIP_SERVER_MAXIMUM_CONNECTIONS_PER_SOURCE",
	"CLIP_SERVER_ROOM_ADVERTISEMENTS_PER_MINUTE",
	"CLIP_SERVER_WEBSOCKET_UPGRADES_PER_MINUTE",
	"CLIP_SERVER_MAXIMUM_QUEUED_BYTES_PER_SOCKET",
	"CLIP_SERVER_MAXIMUM_QUEUED_BYTES_TOTAL",
	"CLIP_SERVER_MAXIMUM_TRACKED_SOURCES",
	"CLIP_SERVER_TRUSTED_PROXY_CIDRS",
	"CLIP_SERVER_ALLOWED_ORIGINS",
	"CLIP_SERVER_ICE_SERVERS_JSON",
}

func clearEnvironment(t *testing.T) {
	t.Helper()
	for _, name := range environmentNames {
		t.Setenv(name, "")
	}
}

func TestDefaultConfigurationMatchesPublicDeploymentContract(t *testing.T) {
	clearEnvironment(t)
	configuration, err := FromEnvironment("1.2.3")
	if err != nil {
		t.Fatal(err)
	}
	if configuration.Address != ":8080" || configuration.ServerVersion != "1.2.3" {
		t.Fatalf("default identity = %q, %q", configuration.Address, configuration.ServerVersion)
	}
	if configuration.LeaseDuration != 5*time.Minute || configuration.ReconnectGrace != 30*time.Second {
		t.Fatalf("default leases = %v, %v", configuration.LeaseDuration, configuration.ReconnectGrace)
	}
	if len(configuration.ICEServers) != 1 || configuration.ICEServers[0].URLs[0] != "stun:stun.l.google.com:19302" {
		t.Fatalf("default ICE servers = %#v", configuration.ICEServers)
	}
}

func TestEnvironmentOverridesAreStrictlyParsed(t *testing.T) {
	clearEnvironment(t)
	t.Setenv("PORT", "9090")
	t.Setenv("CLIP_SERVER_LEASE_DURATION", "10m")
	t.Setenv("CLIP_SERVER_RECONNECT_GRACE", "45s")
	t.Setenv("CLIP_SERVER_ROUTE_IDLE_TIMEOUT", "90s")
	t.Setenv("CLIP_SERVER_MAXIMUM_ROOMS", "50")
	t.Setenv("CLIP_SERVER_MAXIMUM_CONNECTIONS", "75")
	t.Setenv("CLIP_SERVER_RESERVED_HOST_CONNECTIONS", "10")
	t.Setenv("CLIP_SERVER_MAXIMUM_CONNECTIONS_PER_SOURCE", "20")
	t.Setenv("CLIP_SERVER_ROOM_ADVERTISEMENTS_PER_MINUTE", "30")
	t.Setenv("CLIP_SERVER_WEBSOCKET_UPGRADES_PER_MINUTE", "120")
	t.Setenv("CLIP_SERVER_MAXIMUM_QUEUED_BYTES_PER_SOCKET", "1048576")
	t.Setenv("CLIP_SERVER_MAXIMUM_QUEUED_BYTES_TOTAL", "8388608")
	t.Setenv("CLIP_SERVER_MAXIMUM_TRACKED_SOURCES", "1000")
	t.Setenv("CLIP_SERVER_TRUSTED_PROXY_CIDRS", "10.0.0.0/8, 2001:db8::/32")
	t.Setenv("CLIP_SERVER_ALLOWED_ORIGINS", "https://viewer.example, http://localhost:3000")
	t.Setenv("CLIP_SERVER_ICE_SERVERS_JSON", `[{"urls":["turns:turn.example:5349"],"username":"viewer","credential":"temporary"}]`)

	configuration, err := FromEnvironment("test")
	if err != nil {
		t.Fatal(err)
	}
	if configuration.Address != ":9090" || configuration.LeaseDuration != 10*time.Minute || configuration.MaximumRooms != 50 || configuration.MaximumConnections != 75 || configuration.ReservedHostConnections != 10 {
		t.Fatalf("environment configuration = %#v", configuration)
	}
	if len(configuration.AllowedOrigins) != 2 || configuration.ICEServers[0].Credential != "temporary" || len(configuration.TrustedProxyCIDRs) != 2 || configuration.MaximumQueuedBytesTotal != 8_388_608 {
		t.Fatalf("origin/ICE configuration = %#v, %#v", configuration.AllowedOrigins, configuration.ICEServers)
	}
}

func TestInvalidEnvironmentIsRejected(t *testing.T) {
	tests := map[string]struct {
		name  string
		value string
	}{
		"zero port":            {name: "PORT", value: "0"},
		"invalid duration":     {name: "CLIP_SERVER_LEASE_DURATION", value: "later"},
		"negative room limit":  {name: "CLIP_SERVER_MAXIMUM_ROOMS", value: "-1"},
		"trailing ICE JSON":    {name: "CLIP_SERVER_ICE_SERVERS_JSON", value: `[{"urls":["stun:example"]}] {}`},
		"HTTP ICE URL":         {name: "CLIP_SERVER_ICE_SERVERS_JSON", value: `[{"urls":["https://example"]}]`},
		"origin with path":     {name: "CLIP_SERVER_ALLOWED_ORIGINS", value: "https://example.com/viewer"},
		"invalid proxy CIDR":   {name: "CLIP_SERVER_TRUSTED_PROXY_CIDRS", value: "10.0.0.1"},
		"too many connections": {name: "CLIP_SERVER_MAXIMUM_CONNECTIONS", value: "100000"},
	}
	for description, test := range tests {
		description, test := description, test
		t.Run(description, func(t *testing.T) {
			clearEnvironment(t)
			t.Setenv(test.name, test.value)
			if _, err := FromEnvironment("test"); err == nil {
				t.Fatalf("%s=%q was accepted", test.name, test.value)
			}
		})
	}
}

func TestValidateRejectsUnsafeTimingAndMetadata(t *testing.T) {
	configuration := Default("test")
	configuration.PingInterval = configuration.ReadTimeout
	if err := configuration.Validate(); err == nil || !strings.Contains(err.Error(), "ping interval") {
		t.Fatalf("unsafe ping timing error = %v", err)
	}
	configuration = Default(strings.Repeat("v", 129))
	if err := configuration.Validate(); err == nil || !strings.Contains(err.Error(), "server version") {
		t.Fatalf("oversized version error = %v", err)
	}
}
