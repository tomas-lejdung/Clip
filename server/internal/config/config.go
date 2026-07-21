package config

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

const (
	defaultAddress                     = ":8080"
	defaultMaximumRooms                = 1_024
	defaultMaximumConnections          = 2_048
	defaultReservedHostConnections     = 64
	defaultMaximumConnectionsPerSource = 64
	defaultRoomAdvertisementsPerMinute = 60
	defaultWebSocketUpgradesPerMinute  = 240
	defaultMaximumTrackedSources       = 4_096
	defaultMaximumQueuedBytesPerSocket = 2 << 20
	defaultMaximumQueuedBytesTotal     = 64 << 20
	maximumConfiguredRooms             = 16_384
	maximumConfiguredConnections       = 8_192
	maximumConfiguredTrackedSources    = 65_536
	maximumConfiguredQueuedBytes       = 512 << 20
)

type Config struct {
	Address                     string
	ServerVersion               string
	LeaseDuration               time.Duration
	ReconnectGrace              time.Duration
	CleanupInterval             time.Duration
	HelloTimeout                time.Duration
	ReadTimeout                 time.Duration
	WriteTimeout                time.Duration
	PingInterval                time.Duration
	RouteIdleTimeout            time.Duration
	ShutdownTimeout             time.Duration
	MaximumRooms                int
	MaximumConnections          int
	ReservedHostConnections     int
	MaximumConnectionsPerSource int
	RoomAdvertisementsPerMinute int
	WebSocketUpgradesPerMinute  int
	MaximumTrackedSources       int
	MaximumQueuedBytesPerSocket int
	MaximumQueuedBytesTotal     int
	TrustedProxyCIDRs           []string
	AllowedOrigins              []string
	ICEServers                  []protocol.ICEServer
}

func Default(serverVersion string) Config {
	if strings.TrimSpace(serverVersion) == "" {
		serverVersion = "development"
	}
	return Config{
		Address:                     defaultAddress,
		ServerVersion:               serverVersion,
		LeaseDuration:               5 * time.Minute,
		ReconnectGrace:              30 * time.Second,
		CleanupInterval:             5 * time.Second,
		HelloTimeout:                protocol.InitialAnswerTimeoutSeconds * time.Second,
		ReadTimeout:                 45 * time.Second,
		WriteTimeout:                10 * time.Second,
		PingInterval:                15 * time.Second,
		RouteIdleTimeout:            2 * time.Minute,
		ShutdownTimeout:             10 * time.Second,
		MaximumRooms:                defaultMaximumRooms,
		MaximumConnections:          defaultMaximumConnections,
		ReservedHostConnections:     defaultReservedHostConnections,
		MaximumConnectionsPerSource: defaultMaximumConnectionsPerSource,
		RoomAdvertisementsPerMinute: defaultRoomAdvertisementsPerMinute,
		WebSocketUpgradesPerMinute:  defaultWebSocketUpgradesPerMinute,
		MaximumTrackedSources:       defaultMaximumTrackedSources,
		MaximumQueuedBytesPerSocket: defaultMaximumQueuedBytesPerSocket,
		MaximumQueuedBytesTotal:     defaultMaximumQueuedBytesTotal,
		ICEServers: []protocol.ICEServer{
			{URLs: []string{"stun:stun.l.google.com:19302"}},
		},
	}
}

func FromEnvironment(serverVersion string) (Config, error) {
	configuration := Default(serverVersion)

	if address := strings.TrimSpace(os.Getenv("CLIP_SERVER_ADDRESS")); address != "" {
		configuration.Address = address
	} else if port := strings.TrimSpace(os.Getenv("PORT")); port != "" {
		parsedPort, err := strconv.ParseUint(port, 10, 16)
		if err != nil {
			return Config{}, fmt.Errorf("PORT: %w", err)
		}
		if parsedPort == 0 {
			return Config{}, errors.New("PORT must be between 1 and 65535")
		}
		configuration.Address = ":" + port
	}

	var err error
	if configuration.LeaseDuration, err = durationEnvironment("CLIP_SERVER_LEASE_DURATION", configuration.LeaseDuration); err != nil {
		return Config{}, err
	}
	if configuration.ReconnectGrace, err = durationEnvironment("CLIP_SERVER_RECONNECT_GRACE", configuration.ReconnectGrace); err != nil {
		return Config{}, err
	}
	if configuration.RouteIdleTimeout, err = durationEnvironment("CLIP_SERVER_ROUTE_IDLE_TIMEOUT", configuration.RouteIdleTimeout); err != nil {
		return Config{}, err
	}
	if configuration.MaximumRooms, err = positiveIntegerEnvironment("CLIP_SERVER_MAXIMUM_ROOMS", configuration.MaximumRooms); err != nil {
		return Config{}, err
	}
	if configuration.MaximumConnections, err = positiveIntegerEnvironment("CLIP_SERVER_MAXIMUM_CONNECTIONS", configuration.MaximumConnections); err != nil {
		return Config{}, err
	}
	if configuration.ReservedHostConnections, err = positiveIntegerEnvironment("CLIP_SERVER_RESERVED_HOST_CONNECTIONS", min(configuration.ReservedHostConnections, max(1, configuration.MaximumConnections/8))); err != nil {
		return Config{}, err
	}
	if configuration.MaximumConnectionsPerSource, err = positiveIntegerEnvironment("CLIP_SERVER_MAXIMUM_CONNECTIONS_PER_SOURCE", min(configuration.MaximumConnectionsPerSource, configuration.MaximumConnections)); err != nil {
		return Config{}, err
	}
	if configuration.RoomAdvertisementsPerMinute, err = positiveIntegerEnvironment("CLIP_SERVER_ROOM_ADVERTISEMENTS_PER_MINUTE", configuration.RoomAdvertisementsPerMinute); err != nil {
		return Config{}, err
	}
	if configuration.WebSocketUpgradesPerMinute, err = positiveIntegerEnvironment("CLIP_SERVER_WEBSOCKET_UPGRADES_PER_MINUTE", configuration.WebSocketUpgradesPerMinute); err != nil {
		return Config{}, err
	}
	if configuration.MaximumQueuedBytesPerSocket, err = positiveIntegerEnvironment("CLIP_SERVER_MAXIMUM_QUEUED_BYTES_PER_SOCKET", configuration.MaximumQueuedBytesPerSocket); err != nil {
		return Config{}, err
	}
	if configuration.MaximumQueuedBytesTotal, err = positiveIntegerEnvironment("CLIP_SERVER_MAXIMUM_QUEUED_BYTES_TOTAL", configuration.MaximumQueuedBytesTotal); err != nil {
		return Config{}, err
	}
	if configuration.MaximumTrackedSources, err = positiveIntegerEnvironment("CLIP_SERVER_MAXIMUM_TRACKED_SOURCES", configuration.MaximumTrackedSources); err != nil {
		return Config{}, err
	}

	if proxies := strings.TrimSpace(os.Getenv("CLIP_SERVER_TRUSTED_PROXY_CIDRS")); proxies != "" {
		for _, proxy := range strings.Split(proxies, ",") {
			proxy = strings.TrimSpace(proxy)
			if proxy != "" {
				configuration.TrustedProxyCIDRs = append(configuration.TrustedProxyCIDRs, proxy)
			}
		}
	}

	if origins := strings.TrimSpace(os.Getenv("CLIP_SERVER_ALLOWED_ORIGINS")); origins != "" {
		for _, origin := range strings.Split(origins, ",") {
			origin = strings.TrimSpace(origin)
			if origin != "" {
				configuration.AllowedOrigins = append(configuration.AllowedOrigins, origin)
			}
		}
	}

	if raw := strings.TrimSpace(os.Getenv("CLIP_SERVER_ICE_SERVERS_JSON")); raw != "" {
		var servers []protocol.ICEServer
		if err := protocol.DecodeStrictJSON(strings.NewReader(raw), 64*1_024, &servers); err != nil {
			return Config{}, fmt.Errorf("CLIP_SERVER_ICE_SERVERS_JSON: %w", err)
		}
		if len(servers) == 0 {
			return Config{}, errors.New("CLIP_SERVER_ICE_SERVERS_JSON must contain at least one ICE server")
		}
		for _, server := range servers {
			if len(server.URLs) == 0 {
				return Config{}, errors.New("every ICE server must contain at least one URL")
			}
		}
		configuration.ICEServers = servers
	}

	return configuration, configuration.Validate()
}

func (c Config) Validate() error {
	if strings.TrimSpace(c.Address) == "" {
		return errors.New("server address cannot be empty")
	}
	for name, duration := range map[string]time.Duration{
		"lease duration":     c.LeaseDuration,
		"reconnect grace":    c.ReconnectGrace,
		"cleanup interval":   c.CleanupInterval,
		"hello timeout":      c.HelloTimeout,
		"read timeout":       c.ReadTimeout,
		"write timeout":      c.WriteTimeout,
		"ping interval":      c.PingInterval,
		"route idle timeout": c.RouteIdleTimeout,
		"shutdown timeout":   c.ShutdownTimeout,
	} {
		if duration <= 0 {
			return fmt.Errorf("%s must be positive", name)
		}
	}
	if c.MaximumRooms <= 0 || c.MaximumConnections <= 0 || c.MaximumTrackedSources <= 0 {
		return errors.New("resource limits must be positive")
	}
	if c.MaximumRooms > maximumConfiguredRooms || c.MaximumConnections > maximumConfiguredConnections {
		return fmt.Errorf("resource limits exceed safe maxima (%d rooms, %d connections)", maximumConfiguredRooms, maximumConfiguredConnections)
	}
	if c.MaximumTrackedSources > maximumConfiguredTrackedSources {
		return fmt.Errorf("tracked source limit exceeds safe maximum %d", maximumConfiguredTrackedSources)
	}
	if c.ReservedHostConnections <= 0 || c.ReservedHostConnections >= c.MaximumConnections {
		return errors.New("reserved host connections must be smaller than maximum connections")
	}
	if c.MaximumConnectionsPerSource <= 0 || c.MaximumConnectionsPerSource > c.MaximumConnections {
		return errors.New("connections per source must be between 1 and maximum connections")
	}
	if c.RoomAdvertisementsPerMinute <= 0 || c.WebSocketUpgradesPerMinute <= 0 {
		return errors.New("source request rates must be positive")
	}
	if c.MaximumQueuedBytesPerSocket < protocol.MaximumMessageBytes || c.MaximumQueuedBytesPerSocket > maximumConfiguredQueuedBytes {
		return fmt.Errorf("per-socket queued bytes must be between %d and %d", protocol.MaximumMessageBytes, maximumConfiguredQueuedBytes)
	}
	if c.MaximumQueuedBytesTotal < c.MaximumQueuedBytesPerSocket || c.MaximumQueuedBytesTotal > maximumConfiguredQueuedBytes {
		return fmt.Errorf("total queued bytes must be between the per-socket limit and %d", maximumConfiguredQueuedBytes)
	}
	if len(c.ICEServers) == 0 {
		return errors.New("at least one ICE server is required")
	}
	if len(c.ServerVersion) == 0 || len(c.ServerVersion) > 128 {
		return errors.New("server version must contain 1...128 bytes")
	}
	if c.LeaseDuration < time.Second {
		return errors.New("lease duration must be at least one second")
	}
	if c.PingInterval >= c.ReadTimeout {
		return errors.New("ping interval must be shorter than read timeout")
	}
	if len(c.ICEServers) > 32 {
		return errors.New("at most 32 ICE servers are supported")
	}
	for _, server := range c.ICEServers {
		if len(server.URLs) == 0 || len(server.URLs) > 16 {
			return errors.New("every ICE server must contain 1...16 URLs")
		}
		for _, value := range server.URLs {
			parsed, err := url.Parse(value)
			if err != nil || len(value) > 2_048 || parsed.Scheme == "" {
				return fmt.Errorf("invalid ICE server URL %q", value)
			}
			switch strings.ToLower(parsed.Scheme) {
			case "stun", "stuns", "turn", "turns":
			default:
				return fmt.Errorf("invalid ICE server URL scheme %q", parsed.Scheme)
			}
		}
		if len(server.Username) > 1_024 || len(server.Credential) > 4_096 {
			return errors.New("ICE server credential exceeds protocol bounds")
		}
	}
	for _, origin := range c.AllowedOrigins {
		parsed, err := url.Parse(origin)
		if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") {
			return fmt.Errorf("invalid allowed origin %q", origin)
		}
	}
	for _, cidr := range c.TrustedProxyCIDRs {
		if _, _, err := net.ParseCIDR(cidr); err != nil {
			return fmt.Errorf("invalid trusted proxy CIDR %q", cidr)
		}
	}
	return nil
}

func durationEnvironment(name string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	duration, err := time.ParseDuration(value)
	if err != nil || duration <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration", name)
	}
	return duration, nil
}

func positiveIntegerEnvironment(name string, fallback int) (int, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	integer, err := strconv.Atoi(value)
	if err != nil || integer <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	return integer, nil
}
