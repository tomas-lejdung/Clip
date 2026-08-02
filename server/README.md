# Clip Native Room Server

This process coordinates Clip's native-v4 encrypted WebRTC mesh. It owns a
bounded opaque room roster and routes encrypted pair signaling; video, audio,
source metadata, cursor/annotation state, participant names, SDP, and ICE
candidates remain end-to-end encrypted and travel only over direct peer links.

A room contains at most four participants. The resulting topology is always a
complete P2P mesh: two participants have one pair, three have three pairs, and
four have six pairs. Adding or removing a participant does not replace any
unaffected pair.

The invite's URL fragment is client-only and must never appear in an HTTP or
WebSocket request. The server sees only the opaque 256-bit room ID in the path,
opaque ciphertext, random routing handles, connection timing, and roster
revision.

## Run locally

Go 1.25 or newer is required.

```bash
cd server
go run ./cmd/clip-live-share-server
```

The server listens on `:8080`. Useful checks:

```bash
curl http://localhost:8080/healthz
curl http://localhost:8080/version
curl http://localhost:8080/.well-known/clip-native-rendezvous
```

## Discovery

`GET /.well-known/clip-native-rendezvous` returns the v4 room contract,
resource bounds, server version, and validated ICE configuration:

```json
{
  "protocol": "clip-native-room",
  "apiVersion": 4,
  "messageVersion": 4,
  "serverVersion": "development",
  "roomPathTemplate": "/api/native/v4/rooms/{room}",
  "roomWebSocketPathTemplate": "/api/native/v4/rooms/{room}/socket",
  "maximumMessageBytes": 262144,
  "maximumDescriptorBytes": 16384,
  "maximumOpaquePayloadBytes": 196000,
  "maximumPendingCandidates": 8,
  "maximumRoomMembers": 4,
  "maximumRooms": 1024,
  "iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]
}
```

## HTTP and WebSocket contract

- `PUT /api/native/v4/rooms/{room}` creates a room from
  `{ownerToken, creatorHandle, descriptor}`. Retrying the byte-identical
  request is idempotent.
- `GET /api/native/v4/rooms/{room}` returns only opaque room state, roster
  revision, and member count.
- `DELETE /api/native/v4/rooms/{room}` ends the room. It requires
  `Authorization: Bearer <ownerToken>`.
- `GET /api/native/v4/rooms/{room}/socket` is the one participant WebSocket.
  The creator uses `Authorization: Bearer <ownerToken>`, a reconnecting member
  uses `Authorization: Reconnect <capability>` plus
  `X-Clip-Member-Handle`, and a fresh candidate sends no authorization.

Outer message types are `candidate-opened`, `join-knock`, `admit-candidate`,
`deny-candidate`, `member-admitted`, `roster-snapshot`, `pair-signal`,
`leave-room`, `remove-member`, `room-ended`, and `protocol-error`.

The canonical cross-language wire examples are checked in at
[`internal/protocol/testdata/native-room-v4-wire.json`](internal/protocol/testdata/native-room-v4-wire.json).

The creator controls admission and removal. An explicit creator leave ends the
room. An unexpected creator socket loss starts reconnect grace; existing P2P
media remains untouched, but new admissions are refused. Grace expiry ends the
room for everyone. There is deliberately no election, quorum, leaderless lock,
or compatibility endpoint for older protocols.

## Configuration

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Container-friendly listening port. |
| `CLIP_SERVER_ADDRESS` | `:8080` | Full listen address; takes precedence over `PORT`. |
| `CLIP_SERVER_LEASE_DURATION` | `5m` | Time a newly created room may wait for its creator socket. |
| `CLIP_SERVER_RECONNECT_GRACE` | `30s` | Reconnect grace for admitted members and the creator. |
| `CLIP_SERVER_ROUTE_IDLE_TIMEOUT` | `2m` | Maximum idle time for a pending candidate. |
| `CLIP_SERVER_MAXIMUM_RENDEZVOUS` | `1024` | In-memory room ceiling. |
| `CLIP_SERVER_MAXIMUM_CONNECTIONS` | `2048` | Total participant WebSocket ceiling. |
| `CLIP_SERVER_MAXIMUM_CONNECTIONS_PER_SOURCE` | `64` | Concurrent WebSocket ceiling per resolved source. |
| `CLIP_SERVER_RENDEZVOUS_LEASE_OPERATIONS_PER_MINUTE` | `60` | Per-source room-create retry limit. |
| `CLIP_SERVER_WEBSOCKET_UPGRADES_PER_MINUTE` | `240` | Per-source WebSocket upgrade-attempt limit. |
| `CLIP_SERVER_MAXIMUM_QUEUED_BYTES_PER_SOCKET` | `2097152` | Per-socket queued application-frame budget. |
| `CLIP_SERVER_MAXIMUM_QUEUED_BYTES_TOTAL` | `67108864` | Process-wide queued-frame budget. |
| `CLIP_SERVER_MAXIMUM_TRACKED_SOURCES` | `4096` | In-memory source-admission record ceiling. |
| `CLIP_SERVER_TRUSTED_PROXY_CIDRS` | empty | Proxies allowed to supply `X-Forwarded-For`. |
| `CLIP_SERVER_ALLOWED_ORIGINS` | same origin | Additional WebSocket origins. |
| `CLIP_SERVER_ICE_SERVERS_JSON` | Google STUN | STUN/TURN configuration returned by discovery. |

Only `stun`, `stuns`, `turn`, and `turns` URLs are accepted. Use short-lived
TURN credentials because every participant receives discovery configuration.

All state is memory-only and deployments use one replica. A process restart
ends signaling sessions; established P2P media may continue temporarily, but
clients must not invent a roster or elect a creator.

## Tests

```bash
cd server
go test ./...
go test -race ./...
```

Tests cover strict wire decoding, room and socket limits, full 2/3/4-member
rosters, all pair directions, stable room/handle retries, admission and denial,
pair-isolated sequence failures, reconnect grace, noncreator leave, creator
exit/expiry, shutdown, security headers, origin policy, and real localhost
HTTP/WebSocket flows.

## Docker

```bash
cd server
docker build --build-arg VERSION=development -t clip-live-share-server .
docker run --rm -p 8080:8080 clip-live-share-server
```

The runtime container is non-root and includes a `/healthz` health check.

Publish an immutable test or prerelease tag without changing the production
`latest` tag:

```bash
./scripts/publish-docker.sh 1.4.0-server.1
```

Only a coordinated stable server/client release should update `latest`:

```bash
./scripts/publish-docker.sh 1.4.0 --latest
```

The publisher refuses to overwrite an existing version, runs normal and race
tests, and fails on dirty server source by default. Set
`ALLOW_DIRTY_SERVER=1` only for an explicitly identified test image.
