# Clip Native Rendezvous API v1

## Scope

This surface lets two native Clip clients find a currently active friend share
and exchange the bounded messages needed to establish a peer-to-peer
connection. It complements, and does not replace or alter, the browser viewer
and signaling API in `clip-live-share-protocol-v1.md`.

The HTTP API version is `1`. Its WebSocket outer-message version is `2`, keeping
native friend messages disjoint from browser protocol v1 messages.

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
including public keys and the persistent rendezvous-to-identity link. It grants
no admission. The service has no indexed fields for friend names, passwords,
access codes, media metadata, or established viewer count. Friend labels and
trust decisions remain local to Clip. Friend proof, admission, SDP/ICE, and
application data are end-to-end encrypted inside relay payloads.

Here, **opaque descriptor** means the service implementation treats the bytes
as an uninterpreted bounded value; it does not mean the signed descriptor is
ciphertext. A service operator could base64-decode its public/random routing
metadata (server endpoint, browser room, rendezvous identifier, public host and
ephemeral keys, random session identifier, validity times, and revision). It
contains no password, friendship label, trust decision, viewer identity, or
admission capability. All messages that could admit a viewer or establish the
peer connection remain encrypted end to end, so inspecting or replacing the
descriptor cannot let the service join or impersonate a saved friend.

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
not the identifier or the server's owner lease, establish which friend is on
the other side.

## Discovery

`GET /.well-known/clip-native-rendezvous` returns API/message versions, path
templates, and bounds. The existing `/.well-known/clip-live-share` response is
unchanged.

## Ownership and lifecycle HTTP API

### Advertise or renew

`PUT /api/native/v1/rendezvous/{rendezvous}`

```json
{ "ownerToken": "<canonical base64url 32 bytes>" }
```

The first claim returns `201 Created`. A claim by the same owner is idempotent,
renews a disconnected lease, and returns `200 OK`. A different owner receives
`409 Conflict`. This lease is operational ownership only; native clients still
verify persistent identity signatures end-to-end.

### Observe coarse state

`GET /api/native/v1/rendezvous/{rendezvous}`

```json
{ "rendezvousId": "...", "state": "offline|preparing|active" }
```

- `offline`: advertised, but no host WebSocket is attached.
- `preparing`: an authenticated host is attached but has not published an
  active signed session descriptor.
- `active`: the host explicitly published the current signed descriptor.

An unknown or expired identifier returns `404`. The endpoint returns no
descriptor, friend metadata, or viewer state.

### Start or rotate a native session

`PUT /api/native/v1/rendezvous/{rendezvous}/session` with an owner Bearer token:

```json
{ "descriptor": "<canonical base64url signed descriptor>" }
```

Activation requires an attached host. Replacing a descriptor atomically closes
all temporary routes created from the earlier descriptor before the new active
state is visible.

### Stop a native session

`DELETE /api/native/v1/rendezvous/{rendezvous}/session` with an owner Bearer
token. The operation atomically clears the descriptor, changes the state to
`preparing` (or `offline` without a host), and closes all pending routes. After
it returns, no viewer can request admission using the stopped session.

### Remove ownership

`DELETE /api/native/v1/rendezvous/{rendezvous}` with an owner Bearer token.
Removal atomically deletes the advertisement and closes its host and routes.

## WebSocket routing

The host connects to
`/api/native/v1/rendezvous/{rendezvous}/host` with its owner Bearer token. A
viewer may connect to `/viewer` only while the rendezvous is `active`. Requests
made while `offline` or `preparing` are rejected before WebSocket upgrade, so a
friend cannot request host admission before sharing starts.

Opening a viewer route sends the host:

```json
{ "type": "native-route-opened", "version": 2, "routeId": "..." }
```

and the viewer:

```json
{
  "type": "native-route-opened",
  "version": 2,
  "routeId": "...",
  "payload": "<unchanged signed session descriptor>"
}
```

The service implementation does not inspect the descriptor to make policy
decisions, but the descriptor is not encrypted from the server operator. The
viewer verifies its signature, freshness, identity binding, endpoint, session,
and revision before using it.

Either endpoint then sends opaque messages:

```json
{
  "type": "native-relay",
  "version": 2,
  "routeId": "<host only; viewer route is implicit>",
  "sequence": 1,
  "payload": "<canonical base64url signed/encrypted bytes>"
}
```

The server validates only type/version, canonical encoding, bounds, route
ownership, and strictly monotonic outer sequence. It forwards payload bytes
unchanged and never interprets the inner message. `native-close-route`,
`native-route-closed`, `native-host-unavailable`, and bounded `native-error`
messages control only the temporary transport.

Once native WebRTC/DataChannel connectivity is established, the client closes
the temporary route. As with browser sharing, the service cannot observe the
later peer-to-peer connection or maintain an authoritative viewer count.

## Reconnect and restart

A host disconnect immediately clears active state and pending routes, then
reserves the owner lease for the configured reconnect grace. Reconnecting with
the same owner returns to `preparing`; the host must publish a fresh signed
descriptor before viewers can connect.

State is intentionally memory-only and single-replica. A service restart clears
all advertisements. Clip re-advertises its locally persisted opaque ID and
owner capability. Friends authenticate the new descriptor against the locally
stored identity, so reclaiming an ID at the rendezvous service cannot
impersonate its original owner.
