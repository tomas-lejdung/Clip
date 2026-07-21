# Native Clip-to-Clip protocol core (v2)

This package contains an additive native protocol core. It does not change the
browser-facing `clip-live-share` v1 message codec, URL fragment, encrypted
channel, or resource limits. Native messages carry version `2` and use the
`clip-live-share-native` protocol identifier.

The package intentionally does not persist private keys or contacts. The app
will provide a Keychain or Secure Enclave adapter conforming to
`ClipLiveShareIdentitySigner` and will persist only the public contact records
and app-owned secrets it needs.

## Identities and rendezvous

- `ClipLiveShareIdentityPublicKey` is a validated P-256 ECDSA public key in
  X9.63 representation.
- `ClipLiveShareIdentityFingerprint` is SHA-256 of that exact representation.
- `ClipLiveShareIdentitySigner` is the private-key boundary. The package ships
  `ClipLiveShareSoftwareIdentitySigner` for tests and callers that manage their
  own secure persistence.
- `ClipLiveShareRendezvousID` contains 32 random bytes. It is a high-entropy
  locator, not a password or an identity.
- `ClipLiveShareSourceInstanceID` contains 16 random bytes and identifies one
  capture-source generation independently of reusable WebRTC sender slots.

## Signed session establishment

`ClipLiveShareNativeSessionDescriptor` binds all of the following in one host
identity signature:

1. normalized server endpoint;
2. server room;
3. persistent rendezvous identifier;
4. persistent host identity;
5. fresh ephemeral P-256 room key;
6. session identifier;
7. issue and expiry timestamps; and
8. state revision.

The maximum descriptor lifetime is five minutes. A native viewer must pass its
locally expected `ClipLiveShareNativeRendezvousContext` and pinned host identity
to verification before using the ephemeral room key. A valid descriptor signed
by the same host for another endpoint, room, or contact is therefore rejected.
`ClipLiveShareNativeReplayGuard` gives the consumer a bounded, one-time admission
guard after cryptographic verification.

The host then sends `ClipLiveShareNativeViewerChallenge` through the encrypted
route. A challenge binds the signed descriptor digest, session, route, viewer
ephemeral key, 32 random challenge bytes, validity window, and state revision.
`ClipLiveShareSignedNativeViewerProof` adds the persistent viewer identity and
signs the entire context. Verification therefore rejects a proof moved to a
different host session, route, ephemeral viewer key, revision, or identity.

## Native control negotiation

After the control DataChannel opens, a native viewer sends
`ClipLiveShareSignedNativeControlHello` before the host emits any v2 lifecycle
messages. Its top-level wire discriminator is version `2` plus type
`native-control-hello`; browser viewers continue to receive only their existing
v1 control messages.

The signed hello binds the current session ID, persistent viewer identity,
bounded device name, supported capabilities, and a validity window of at most
one minute. Current capability values are `stream-lifecycle` and `friends`, and
their canonical order is independent of `Set` iteration order. A host can
verify a previously unknown self-signed identity with
`verify(expectedSessionID:at:)`, or additionally pin an existing contact with
`verify(expectedSessionID:expectedIdentity:at:)`. It must then admit the hello
through `ClipLiveShareNativeReplayGuard` before marking the channel as native or
sending v2 stream state. The self-signature proves continuity and session
ownership; deciding whether to trust or save a new identity remains app policy.

## Friend messages

`ClipLiveShareNativeFriendMessage` has five signed variants:

- `add-friend-request` binds the active descriptor, target host fingerprint,
  requester identity, normalized requester endpoint, requester-owned 256-bit
  rendezvous identifier, device name, and a ten-minute maximum validity
  window;
- `add-friend-accepted` binds the exact request digest and grants the accepter's
  normalized endpoint and 256-bit rendezvous identifier;
- `add-friend-acceptance-acknowledged` is requester-signed and binds the exact
  acceptance digest, request and session, both persistent identities, both
  normalized endpoints and rendezvous identifiers, the accepted state
  revision, acknowledgement time, and the original request expiry;
- `add-friend-commit-receipt` is accepter-signed and binds the request,
  acceptance and acknowledgement digests plus both persistent return routes;
- `add-friend-declined` binds the exact request and an optional bounded reason;
- `friend-revoked` binds issuer, revoked fingerprint, rendezvous identifier,
  revision, timestamp, and optional reason.

The request therefore gives the accepter a complete persistent return route,
and the acceptance gives the requester the accepter's complete persistent
route. Both endpoint values decode through `ClipLiveShareServerEndpoint`, so
alternate URL spelling is normalized before it reaches signature or contact
state. Acceptance validation additionally requires its endpoint and identity to
match the signed active session descriptor; a correctly signed acceptance
cannot substitute an unrelated server route.

The accepter sends its signed acceptance before persisting the requester. The
requester validates the acceptance, locally persists a hidden pending contact
and exact signed evidence in one file replacement, and sends the signed
acknowledgement. Only after validating that acknowledgement does the accepter
locally persist the requester and its evidence, then persist and send a signed
commit receipt. The requester exposes the contact only after receipt validation
and a local durable promotion. An interrupted delivery is recoverable: either
side may retransmit its exact persisted statement over a fresh peer session
authenticated by the same persistent identities. The acknowledgement's
canonical digest is stable across retransmission, and
`acceptAcknowledgementIdempotently` reports `.firstSeen` or `.duplicate` so a
duplicate never causes a second persistence mutation. The protocol remains
idempotent and eventually convergent within the app's bounded recovery window;
it does not claim an impossible cross-device atomic transaction. Protocol
validity is checked at each signed event time, while the app separately caps
the signed journal at 16 entries and retains it for seven days.

`ClipLiveShareSignedNativeFriendMessage.verifySignature` verifies only the
cryptographic signer. Consumers must additionally call the request validator
(`validate(expectedSessionDescriptor:expectedHostIdentity:at:)`), acceptance
validator (`validate(for:expectedSessionDescriptor:at:)`), decline validator
(`validate(for:at:)`), or revocation validator as appropriate. They must then
call `acceptSignatureOnce` and use the revision guard before mutating persisted
contact state. Keeping signature and policy validation explicit prevents the
package from assuming an app-specific trust or confirmation policy.

For an acceptance acknowledgement, call
`validate(for:request:expectedSessionDescriptor:at:)` before
`acceptAcknowledgementIdempotently`. A `.firstSeen` result commits the host's
contact; `.duplicate` confirms an already completed commit without writing it
again. A context-invalid or expired acknowledgement must not enter the replay
guard or contact repository.

## Stream lifecycle

`ClipLiveShareNativeStreamLifecycleMessage` is separate from the v1 encrypted
inner-message enum. Every native update carries a session ID and positive,
strictly increasing `ClipLiveShareStateRevision`. Events cover full snapshots,
source upsert/removal, focus, sharing, and system-audio state.

Each stream descriptor contains both the existing opaque stream/track IDs and a
`sourceInstanceId`. It also carries an authenticated `presentationMode`:
`manual` means the source owns its own viewer window, while
`follows-focused-window` means successive Auto-share sources reuse one stable
viewer window as focus moves. The mode participates in the descriptor's
canonical representation, so changing it changes the authenticated lifecycle
statement rather than acting as unauthenticated UI metadata.

A delayed removal for a previous source cannot remove a new source that reused
the same negotiated sender slot. The package reducer,
`ClipLiveShareNativeStreamLifecycleState`, applies updates transactionally and
rejects stale revisions, cross-session updates, duplicate instances, and live
sender-slot collisions.

## Canonical signature encoding

Wire JSON is emitted with sorted keys for stable fixtures, but signatures never
depend on JSON formatting. Every signed value has a domain-separated canonical
binary representation:

- strings and byte strings are prefixed by an unsigned 32-bit big-endian byte
  length;
- integers are unsigned 64-bit big-endian values (timestamps use their
  non-negative signed-bit representation);
- booleans are one byte (`0` or `1`);
- fields appear in the exact order used by their model's
  `canonicalRepresentation` implementation;
- the first field is the operation-specific ASCII domain, followed by the
  unsigned 64-bit native protocol version (`2`).

Separate domains are used for session descriptors, viewer challenges/proofs,
native control hellos, each friend decision, stream descriptors, and stream
lifecycle updates. A golden session vector in `ClipLiveShareNativeV2Tests`
prevents accidental encoding drift.

Replay identifiers hash the canonical signed statement, not the ECDSA signature
bytes. This prevents alternate encodings of an otherwise valid signature from
creating a new replay identity.

## Required consumer order

For any signed native input, the app must:

1. decode through `ClipLiveShareNativeV2MessageCodec` with an appropriate byte
   limit;
2. compare the supplied route/session/contact context with the expected local
   context;
3. verify expiry and the pinned identity signature;
4. admit the statement through its replay and state-revision guards; and only
5. then mutate peer, contact, or stream state.

The signaling server may relay or replay these bytes but cannot substitute a
host/session key, move a viewer proof to another route, accept a friend request,
or revoke a contact without the appropriate persistent private key.

The signed session descriptor authenticates public routing metadata but does
not encrypt it. “Opaque” in the rendezvous API means the Go service validates
only its byte bound and never parses it; a service operator can still inspect
that public/random descriptor metadata. Admission proofs and the subsequent
SDP, ICE, and control exchange are encrypted and are the confidentiality and
authorization boundary.
