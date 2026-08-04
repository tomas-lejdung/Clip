# Clip Native Rendezvous API v3

> **Historical, retired design.** This document describes the superseded v3
> opaque-rendezvous experiment. It is not a supported connection path or a
> compatibility contract. Current Live Share uses the clean-slate
> server-coordinated v4 room protocol documented in
> `docs/server-coordinated-mesh-design.md` and `server/README.md`.

## Scope

This surface let native-v3 Clip participants locate a current room invitation
and exchange bounded opaque messages needed to establish their direct
peer-to-peer links. It was the only supported Live Share rendezvous service for
that experiment.
There is no browser participant, legacy signaling API, saved-Friend protocol,
or compatibility route.

The HTTP API and opaque WebSocket routing-envelope version are both `3`. These
numbers version this small service boundary. Native-v3 admission, membership,
peer-link negotiation, source state, collaboration, and media remain encrypted
inside the routed payload.

## Trust boundary

The service may observe a random rendezvous identifier, connection addresses
and times, coarse lifecycle state, temporary route identifiers, and envelope
sizes. It stores only:

- the SHA-256 hash of a random owner capability;
- a 32-byte opaque rendezvous identifier;
- `offline`, `preparing`, or `active` lifecycle state;
- one bounded, unparsed signed session descriptor while active; and
- bounded temporary WebSocket routes.

The service implementation treats the descriptor and relay payloads as
unparsed bytes. The signed descriptor is not confidential from the server
operator: it contains public/random routing and authentication metadata,
including public keys. It grants no admission. The service has no indexed
fields for participant names, Access Words, membership, media metadata, source
state, or established participant count. Admission, SDP/ICE, membership, and
application data are end-to-end encrypted inside relay payloads.

Here, **opaque descriptor** means the service implementation treats the bytes
as an uninterpreted bounded value; it does not mean the signed descriptor is
ciphertext. A service operator could base64-decode its public/random routing
metadata (server endpoint, rendezvous identifier, public leader and ephemeral
keys, random session identifier, validity times, and revision). It contains no
Access Word, approval decision, membership credential, or admission
capability. All messages that could admit a participant or establish a peer
connection remain encrypted end to end, so inspecting or replacing the
descriptor cannot grant room membership.

## Identifiers and limits

- Rendezvous ID: exactly 32 random bytes, canonical base64url without padding.
- Owner capability: exactly 32 random bytes, canonical base64url without
  padding. Only its SHA-256 hash is stored.
- Route ID: 16 random bytes, canonical base64url without padding.
- Signed session descriptor: 1...16,384 unparsed bytes, transported as canonical
  base64url.
- Native relay payload: 1...196,000 opaque bytes, transported as canonical
  base64url.
- WebSocket frame: at most 262,144 bytes.
- Pending routes per rendezvous: at most 8.
- Advertised native rendezvous entries: bounded by the deployment's
  `maximumRendezvous` discovery value (1,024 by default).

High entropy prevents public enumeration; cryptographic identity signatures,
not the identifier or the server's owner lease, establish which participant is
on the other side.

## Discovery

`GET /.well-known/clip-native-rendezvous` returns API/message versions, path
templates, bounds, and validated STUN/TURN configuration. Its routing fields
are:

```json
{
  "apiVersion": 3,
  "messageVersion": 3,
  "rendezvousPathTemplate": "/api/native/v3/rendezvous/{rendezvous}",
  "ownerWebSocketPathTemplate": "/api/native/v3/rendezvous/{rendezvous}/owner",
  "candidateWebSocketPathTemplate": "/api/native/v3/rendezvous/{rendezvous}/candidate"
}
```

No legacy capability document is served.

## Ownership and lifecycle HTTP API

### Advertise or renew

`PUT /api/native/v3/rendezvous/{rendezvous}`

```json
{ "ownerToken": "<canonical base64url 32 bytes>" }
```

The first claim returns `201 Created`. A claim by the same owner is idempotent,
renews a disconnected lease, and returns `200 OK`. A different owner receives
`409 Conflict`. This lease is operational ownership only; native clients still
verify persistent identity signatures end-to-end.

### Observe coarse state

`GET /api/native/v3/rendezvous/{rendezvous}`

```json
{ "rendezvousId": "...", "state": "offline|preparing|active" }
```

- `offline`: advertised, but no owner WebSocket is attached.
- `preparing`: an authenticated owner is attached but has not published an
  active signed session descriptor.
- `active`: the owner explicitly published the current signed descriptor.

An unknown or expired identifier returns `404`. The endpoint returns no
descriptor, participant metadata, or candidate state.

### Start or rotate a native session

`PUT /api/native/v3/rendezvous/{rendezvous}/session` with an owner Bearer token:

```json
{ "descriptor": "<canonical base64url signed descriptor>" }
```

Activation requires an attached owner. Replacing a descriptor atomically closes
all temporary routes created from the earlier descriptor before the new active
state is visible.

### Stop a native session

`DELETE /api/native/v3/rendezvous/{rendezvous}/session` with an owner Bearer
token. The operation atomically clears the descriptor, changes the state to
`preparing` (or `offline` without an owner), and closes all pending routes.
After it returns, no candidate can request admission using the stopped session.

### Remove ownership

`DELETE /api/native/v3/rendezvous/{rendezvous}` with an owner Bearer token.
Removal atomically deletes the advertisement and closes its owner and routes.

## WebSocket routing

The current invitation owner connects to
`/api/native/v3/rendezvous/{rendezvous}/owner` with its owner Bearer token. A
joining candidate connects to
`/api/native/v3/rendezvous/{rendezvous}/candidate` only while the rendezvous is
`active`. These path names describe the two ends of this low-level bootstrap
route; they do not create permanent product roles. Requests made while
`offline` or `preparing` are rejected before WebSocket upgrade.

Opening a candidate route sends the invitation owner:

```json
{ "type": "native-route-opened", "version": 3, "routeId": "..." }
```

and the candidate:

```json
{
  "type": "native-route-opened",
  "version": 3,
  "routeId": "...",
  "payload": "<unchanged signed session descriptor>"
}
```

The service implementation does not inspect the descriptor to make policy
decisions, but the descriptor is not encrypted from the server operator. The
candidate verifies its signature, freshness, identity binding, endpoint, session,
and revision before using it.

Either endpoint then sends opaque messages:

```json
{
  "type": "native-relay",
  "version": 3,
  "routeId": "<owner only; candidate route is implicit>",
  "sequence": 1,
  "payload": "<canonical base64url signed/encrypted bytes>"
}
```

The server validates only type/version, canonical encoding, bounds, route
ownership, and strictly monotonic outer sequence. It forwards payload bytes
unchanged and never interprets the inner native-v3 message. `native-close-route`,
`native-route-closed`, `native-owner-unavailable`, and bounded `native-error`
messages control only the temporary transport.

Once native WebRTC/DataChannel connectivity is established, the client closes
the temporary route. The service cannot observe the later peer-to-peer
connection or maintain an authoritative participant count.

## Reconnect and restart

An invitation owner's disconnect immediately clears active state and pending
routes, then reserves the owner lease for the configured reconnect grace.
Reconnecting with the same owner returns to `preparing`; the owner must publish
a fresh signed descriptor before candidates can connect.

State is intentionally memory-only and single-replica. A service restart clears
all advertisements. A room leader advertises a fresh random route and signed
descriptor. Native-v3 participants authenticate the descriptor and membership
authority end-to-end, so claiming a service identifier cannot grant room
membership or impersonate a certified leader.
