# Clip Native-v3 Rendezvous Server

This process is the privacy-minimal bootstrap service for Clip's native-v3
participant mesh. It:

- leases a high-entropy rendezvous identifier to its bearer-token owner;
- stores one bounded, opaque, signed session descriptor;
- opens short-lived owner/candidate WebSocket routes;
- relays bounded opaque payloads until the peers establish their direct
  WebRTC link; and
- advertises validated STUN/TURN configuration.

It does **not** serve a browser viewer or own a Live Share room. Participant
identity, admission, membership, leadership, publication state, collaboration,
media, SDP, and ICE candidates remain end-to-end encrypted and client-owned.
Established peer links do not pass through this service.

## Run locally

Go 1.25 or newer is required.

```bash
cd server
go run ./cmd/clip-live-share-server
```

The server listens on `:8080`. Configure Clip's endpoint as
`http://localhost:8080` while developing.

Useful checks:

```bash
curl http://localhost:8080/healthz
curl http://localhost:8080/version
curl http://localhost:8080/.well-known/clip-native-rendezvous
```

## Native service capabilities

`GET /.well-known/clip-native-rendezvous` returns only the native rendezvous
wire contract, resource bounds, server version, and validated ICE servers:

```json
{
  "protocol": "clip-native-rendezvous",
  "apiVersion": 3,
  "messageVersion": 3,
  "serverVersion": "development",
  "rendezvousPathTemplate": "/api/native/v3/rendezvous/{rendezvous}",
  "ownerWebSocketPathTemplate": "/api/native/v3/rendezvous/{rendezvous}/owner",
  "candidateWebSocketPathTemplate": "/api/native/v3/rendezvous/{rendezvous}/candidate",
  "maximumMessageBytes": 262144,
  "maximumDescriptorBytes": 16384,
  "maximumOpaquePayloadBytes": 196000,
  "maximumPendingRoutes": 8,
  "maximumRendezvous": 1024,
  "iceServers": [
    {"urls": ["stun:stun.l.google.com:19302"]}
  ]
}
```

The `apiVersion: 3`, `messageVersion: 3`, and `/api/native/v3` names version
this small opaque routing transport. Native-v3 is the only product protocol
inside the opaque descriptor and relay payload. The `owner` and `candidate`
path labels describe only the invitation owner and joining candidate during
bootstrap; every admitted Clip instance becomes an equal mesh participant
afterward.

The complete opaque boundary is documented in
[`docs/clip-native-rendezvous-v3.md`](../docs/clip-native-rendezvous-v3.md).

## Configuration

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Container-friendly listening port. |
| `CLIP_SERVER_ADDRESS` | `:8080` | Full listen address; takes precedence over `PORT`. |
| `CLIP_SERVER_LEASE_DURATION` | `5m` | Lifetime of an unconnected rendezvous advertisement. |
| `CLIP_SERVER_RECONNECT_GRACE` | `30s` | Time the authenticated owner has to reclaim a disconnected rendezvous. |
| `CLIP_SERVER_ROUTE_IDLE_TIMEOUT` | `2m` | Maximum idle time for a bootstrap route. |
| `CLIP_SERVER_MAXIMUM_RENDEZVOUS` | `1024` | In-memory advertisement ceiling. |
| `CLIP_SERVER_MAXIMUM_CONNECTIONS` | `2048` | Total rendezvous WebSocket ceiling. |
| `CLIP_SERVER_RESERVED_COORDINATOR_CONNECTIONS` | `64` | Slots joining candidates cannot consume. |
| `CLIP_SERVER_MAXIMUM_CONNECTIONS_PER_SOURCE` | `64` | Concurrent WebSocket ceiling per resolved client source. |
| `CLIP_SERVER_RENDEZVOUS_LEASE_OPERATIONS_PER_MINUTE` | `60` | Per-source rendezvous claim/renew rate. |
| `CLIP_SERVER_WEBSOCKET_UPGRADES_PER_MINUTE` | `240` | Per-source WebSocket upgrade-attempt rate. |
| `CLIP_SERVER_MAXIMUM_QUEUED_BYTES_PER_SOCKET` | `2097152` | Per-socket queued application-frame byte budget. |
| `CLIP_SERVER_MAXIMUM_QUEUED_BYTES_TOTAL` | `67108864` | Process-wide queued application-frame byte budget. |
| `CLIP_SERVER_MAXIMUM_TRACKED_SOURCES` | `4096` | Ceiling for in-memory source-admission records. |
| `CLIP_SERVER_TRUSTED_PROXY_CIDRS` | empty | Proxy networks allowed to supply `X-Forwarded-For`. |
| `CLIP_SERVER_ALLOWED_ORIGINS` | same origin | Optional additional WebSocket origins. |
| `CLIP_SERVER_ICE_SERVERS_JSON` | Google STUN | Native-v3 STUN/TURN configuration returned by capabilities. |

Example:

```bash
export CLIP_SERVER_ICE_SERVERS_JSON='[
  {"urls":["stun:stun.example.com:3478"]},
  {
    "urls":["turns:turn.example.com:5349"],
    "username":"temporary-user",
    "credential":"temporary-credential"
  }
]'
```

The server accepts at most 32 ICE servers and 16 URLs per server; only
`stun`, `stuns`, `turn`, and `turns` URLs are accepted. Credentials are
bounded. Use short-lived TURN credentials because every native participant
receives this capabilities response.

Source throttles use the direct TCP peer by default and ignore forwarded
headers. Behind a TLS reverse proxy, either enforce client limits there or set
`CLIP_SERVER_TRUSTED_PROXY_CIDRS` to the proxy network.

## HTTP surface

- `GET /.well-known/clip-native-rendezvous` — native service discovery,
  bounds, and ICE servers.
- `PUT /api/native/v3/rendezvous/{id}` — claim or renew a high-entropy ID.
- `GET /api/native/v3/rendezvous/{id}` — read `offline`, `preparing`, or
  `active`.
- `PUT /api/native/v3/rendezvous/{id}/session` — install an opaque signed
  native-v3 descriptor.
- `DELETE /api/native/v3/rendezvous/{id}/session` — stop admission and retire
  every pending bootstrap route atomically.
- `DELETE /api/native/v3/rendezvous/{id}` — remove the rendezvous.
- `GET /api/native/v3/rendezvous/{id}/owner` — owner-authenticated invitation
  WebSocket.
- `GET /api/native/v3/rendezvous/{id}/candidate` — active-only candidate
  WebSocket.
- `GET /healthz` and `GET /version` — process status without participant or
  rendezvous metrics.

There are no browser viewer, room-allocation, legacy signaling, friendship, or
protocol-negotiation endpoints.

All state is memory-only and deployments use one replica. A process restart
clears rendezvous leases but does not affect already-established P2P mesh
links. TLS should terminate at a reverse proxy for Internet deployments.

## Tests

```bash
cd server
go test ./...
go test -race ./...

cd ..
scripts/run-live-share-acceptance.sh
```

The Go tests cover ownership, active-state gating, reconnect/replacement,
atomic stop/removal, route isolation and bounds, monotonic opaque relays,
strict payload limits, validated ICE configuration, security headers, origin
policy, and real localhost WebSocket routing. The repository acceptance script
also runs only the Swift native-v3 bootstrap, mesh, rendezvous, collaboration,
and succession gates.

## Docker

```bash
cd server
docker build --build-arg VERSION=development -t clip-live-share-server .
docker run --rm -p 8080:8080 clip-live-share-server
```

The runtime container is non-root and includes a `/healthz` health check.
