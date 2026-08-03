# Server-Coordinated Participant Mesh

Status: implementation contract for the clean-slate mesh replacement.

This design replaces client-side membership consensus and creator succession.
The service coordinates an opaque room roster and encrypted pair signaling;
all media, audio, durable room control, source state, cursors, and annotations
remain on direct WebRTC peer connections.

## Product contract

- A room supports at most four participants across Native and Web profiles.
- Every unordered participant pair owns exactly one direct WebRTC connection.
- For participants A, B, and C, the only media topology is A-B, A-C, and B-C.
- Adding or removing one participant never renegotiates an unaffected pair.
- Every Native participant can publish windows, fullscreen video, and system
  audio. A Web participant is a first-class, receive-only mesh member that
  publishes an authenticated empty source snapshot and no media.
- Native and Web use the same room session, pair identity, encrypted signaling,
  concrete peer-link contract, fixed transceivers, and ordered DataChannel. The
  authenticated profile controls capabilities and presentation only.
- The Native creator controls admission, Access Word, Ask Before Joining, invite
  rotation, participant removal, and End Room.
- A noncreator may leave without affecting the remaining pairs.
- If the creator explicitly leaves, the room ends for everyone.
- If the creator's signaling socket disappears, existing P2P media continues
  during a bounded reconnect grace. The room ends if that grace expires.
- There is no creator election, leadership term, quorum, authority chain,
  membership certificate chain, or leaderless-locked phase.
- No legacy protocol or backwards compatibility is required.

The creator-certified descriptor carries exactly one closed, versioned client
profile: `nativeApp/nativeV1` or `webViewer/webViewerV1`. The Web profile may
receive all compatible Native sources and per-participant audio, leave, and
reconnect its tab. It cannot create/administer a room, publish media, create a
friendship, send/render collaboration, or control native viewer windows.

## Privacy boundary

The canonical native/web invite has a presentation path and two independent
client-only fragment fields:

```text
https://service.example/ROOMCODE#v=4&key=<sealed-client-payload>&join=<admission-capability>
```

`ROOMCODE` is random presentation material, not the service API room ID. The
unmodified client never sends the URL fragment in HTTP or WebSocket requests.
`key` is an AES-GCM payload containing the opaque 256-bit API room ID, session
binding, creator identity, room agreement secret, and admission capability.
`join` derives the payload key and proves permission to knock. Authenticated
data binds the sealed payload to the exact room-code path. After decrypting the
invite, a client uses the opaque API room ID as service-visible routing
material.

The service may observe the non-authorizing presentation code when it serves a
web page, room/member routing handles, IP addresses, connection timing, roster
revision, and ciphertext sizes. It must not receive plaintext
participant identities or names, Access Words, SDP, ICE candidates, source or
window metadata, codec settings, cursor/annotation values, audio, or video.

Member descriptors, admission requests, and pair-signaling payloads are opaque
authenticated ciphertext. A descriptor contains the participant identity
(device-persistent for Native or tab-scoped for Web), ephemeral pair-signaling
public key, and closed Native/Web profile.
The creator signs each admitted opaque descriptor together with its
server-assigned member handle. Clients reject roster entries without that
creator admission signature. The service cannot read or route differently on
the profile.

The profile is a creator-certified declaration, not proof that a participant
is running Apple's signed Clip binary. Capability checks constrain peers that
declare `webViewerV1`, but a custom malicious client could claim
`nativeApp/nativeV1` unless a future protocol adds Native application
attestation. Creator admission and the bounded room membership remain part of
the threat model.

The service is trusted for availability, roster ordering, and removal. It is
not trusted with room contents or admission secrets. It can deny service, as
any rendezvous server can, but the unmodified binary cannot decrypt or silently
fabricate a valid participant admission. For the Web surface, its serving
origin is additionally a trusted client-distribution boundary: a malicious or
compromised deployment could serve JavaScript that reads and exfiltrates the
fragment. The protocol does not claim protection from that origin.

## Service-owned state

Each room contains:

- opaque 256-bit room ID;
- hash of the creator owner capability;
- creator routing handle and attached socket;
- monotonically increasing nonzero roster revision;
- at most four member records;
- per-member random routing handle, opaque creator-certified descriptor,
  socket presence, reconnect-capability hash, and grace deadline;
- bounded per-direction opaque signaling sequence state.

The service always sends complete roster snapshots. With a four-member bound,
full snapshots are simpler and safer than deltas.

## Admission and stable invite

1. The creator claims the opaque room ID and attaches its authenticated socket.
2. A joiner opens the room socket using only the opaque room ID.
3. The service allocates a candidate routing handle and forwards the joiner's
   opaque encrypted knock to the creator.
4. The creator decrypts and validates the invite capability, possession proof,
   optional Access Word, capacity, and local Ask Before Joining policy.
5. On admission, the creator returns a signed opaque admission record bound to
   the server-assigned handle.
6. The service atomically installs the member, increments roster revision, and
   broadcasts one complete snapshot to every member.

The invite URL is byte-stable across joins, leaves, reconnects, descriptor
refreshes, and roster revisions. Only the explicit New Invite action rotates
the admission capability and changes the copied URL. Rotation does not replace
the room ID or disturb admitted participants.

## Receive-only web session

`GET /ROOMCODE` serves one same-origin repository-owned viewer shell. The room
code is presentation material only; JavaScript reads and decrypts the canonical
`#v=4&key=...&join=...` fragment locally before contacting the opaque API room.
Viewer HTML and assets use a restrictive Content Security Policy and no
third-party scripts, styles, fonts, analytics, or CDNs. With those unmodified
assets, the fragment never enters a request, cookie, WebSocket outer envelope,
or service log. Non-loopback browser invites require HTTPS; HTTP is accepted
only for exact loopback development hosts.

One browser tab owns one ephemeral P-256 participant identity and reconnect
capability in tab-scoped storage. A refresh preserves that member; explicit
Leave removes it; another tab is a distinct candidate. Browsers cannot attach
the Native reconnect Authorization header to a WebSocket. A same-origin POST
therefore exchanges the capability for a short-lived, single-use, source-bound
opaque ticket, which is supplied in the WebSocket subprotocol header. The room
hub still validates and consumes the underlying reconnect credential while
attaching the socket. Native Authorization behavior is unchanged.

Web-v1 supports current desktop Safari and Chromium. It presents Focus and Row
layouts (not Grid), with Native size as the default, Fit/Fill, browser
fullscreen, drag-to-pan plus a viewport minimap for oversized Native sources,
an auto-hiding source filmstrip HUD, Follow Off/manual selection, and
per-publisher Follow. Master and per-publisher audio controls remain available.
Firefox and mobile browsers are not release claims.

## Friends and private presence

Friendship is a signed four-step handshake over an already authenticated pair
DataChannel: request, acceptance, acknowledgement, and commit receipt. Durable
state and recovery evidence are written before each message is sent, so a
crash or retransmission cannot create a one-sided trusted relationship.

Each friendship owns two directional, per-friend presence mailboxes. A mailbox
is a random routing ID plus a random symmetric read secret exchanged only in
the encrypted peer channel. While hosting, a participant publishes the current
canonical v4 invite as a short-lived identity-signed AES-GCM ciphertext to each
friend's distinct mailbox. The service stores only routing ID, monotonic
revision, expiry, and bounded ciphertext. It cannot read the invite or identity
and cannot correlate one publisher's friend graph through a reused mailbox.

A saved-friend join uses the same v4 admission protocol and always requests
explicit creator approval. It does not add a legacy route or separate media
role. Friendship controls are restricted to authenticated Native profiles.

## Roster wire state

The clean-slate service protocol uses one participant WebSocket per process.
Outer JSON is strictly decoded and bounded. Conceptual messages are:

- `candidate-opened(candidateHandle, currentOpaqueRoomDescriptor)`
- `join-knock(candidateHandle, sequence, ciphertext)`
- `admit-candidate(candidateHandle, opaqueAdmissionRecord)`
- `deny-candidate(candidateHandle, reason)`
- `member-admitted(memberHandle, reconnectCapability, rosterSnapshot)`
- `roster-snapshot(revision, creatorHandle, members[])`
- `pair-signal(from, to, pairID, sequence, ciphertext)`
- `leave-room`
- `remove-member(memberHandle)`
- `room-ended(reason)`
- `protocol-error(code)`

The service validates only versions, bounds, room membership, routing handles,
strict per-direction sequences, and creator-only operations. It never decodes
opaque admission or pair-signaling payloads.

## Pair identity and negotiation

Roster revision and pair negotiation revision are deliberately independent.

For two admitted routing handles, clients derive a stable pair ID from the
room ID and the lexicographically sorted handles. The lower handle is the only
initial offerer. Each local pair state owns its own monotonically increasing
negotiation revision, ICE restart state, retry budget, and encrypted signaling
sequence.

Applying a roster snapshot is a pure set reconciliation:

```text
desired peers = snapshot members - local member
remove        = existing peers - desired peers
add           = desired peers - existing peers
retain        = existing peers intersect desired peers
```

Retained pairs are not recreated, renegotiated, or rebound to the new roster
revision. A new C therefore creates A-C and B-C while A-B remains byte-for-byte
the same live pair. A failure on A-C can retry or fail independently and must
not change A-B, B-C, roster membership, or room phase.

SDP and ICE signaling is signed, context-bound, pairwise encrypted, and routed
through the service. Source snapshots, participant audio, collaboration state,
and media continue over the established direct pair's authenticated WebRTC
tracks and DataChannel.

The remote profile does not select a native transport implementation. For A
and B as Native and W as Web, Native reconciles A-B, A-W, and B-W through the
same normal pair manager; W implements that pair contract with the platform
`RTCPeerConnection` API. Web-Web edges remain authenticated data-only edges.

Every Native-Web video transceiver offers only the publishing participant's
selected codec. There is no browser-specific second encode, transcoding, or
codec fallback. If a Web runtime cannot decode it, the incompatible peer
remains in the authoritative roster and the UI reports
`Unsupported Encoding: <codec>` when the codec is observable. An edge that
fails before exposing the codec may instead remain unavailable or black.
Current libwebrtc may reject that complete peer edge rather than only its video
m-lines, so web-v1 does not promise audio or DataChannel availability on that
one incompatible edge. Every unrelated pair and the publisher's single encoder
remain unchanged.

Native-Native edges keep the pre-Web SDP preference ladder: AV1 prefers AV1,
VP9, then VP8; VP9 prefers VP9 then VP8; H.264 and VP8 are exact. The ladder
still selects one active codec and one encoder; it never authorizes parallel
per-peer encodings. A Web join or leave must not renegotiate an unaffected
Native-Native edge.

## Disconnect behavior

- Explicit noncreator leave: remove immediately, increment roster revision,
  broadcast the complete snapshot, and close only that member's pairs.
- Unexpected noncreator socket loss: retain the member during reconnect grace;
  existing P2P media is not interrupted. Reattach with the reconnect
  capability and same handle. On expiry, remove it as an ordinary leave.
- Explicit creator leave or End Room: broadcast room-ended and close the room.
- Unexpected creator socket loss: reject admissions and roster mutations but
  retain existing P2P media during reconnect grace. Reattach with the owner
  capability and same handle. On expiry, broadcast room-ended and close.
- Service restart: all signaling sessions end cleanly. Existing P2P media may
  continue temporarily, but the UI reports signaling unavailable and the room
  ends locally after a bounded timeout; it never elects a creator or invents a
  roster.

## Implementation deletion boundary

Remove client-side leadership, authority-chain, election, quorum, and
provisional-member promotion code. Retire leader forwarding and peer-negotiation
handoffs. Keep the concrete WebRTC transport, capture publisher, local capture
controller, source/audio/collaboration control, remote viewer presentation,
and source-aware ScreenCaptureKit resolution policy unchanged.

The mesh manager remains the owner of one concrete transport per pair, but its
desired peers and signaling now come directly from the server room session.
The receive-only browser conforms to this contract; it does not introduce a
browser-specific Native transport or signaling path.

## Mandatory gates

- The unmodified client never places the invite fragment in an HTTP path,
  query, header, server log, or outer WebSocket message. The Web serving origin
  remains a trusted client-distribution boundary.
- Invite remains identical across repeated joins; only New Invite changes it.
- Two participants form exactly one ready bidirectional pair.
- Adding a third forms exactly three pairs without changing A-B transport ID,
  negotiation revision, track IDs, or media continuity.
- Adding a fourth forms exactly six pairs without replacing the first three.
- Every Native participant publishes and receives every other Native
  participant's video and optional system audio. Every Web participant receives
  every compatible Native publisher and publishes no media.
- A + B + Web forms exactly three ready links without changing A-B's transport
  ID, negotiation revision, tracks, codec, or media continuity.
- A + B + C + Web forms exactly six links. Native/Web presentation badges and
  Web capability restrictions derive only from the signed profile.
- Unsupported selected codec on a Native-Web edge proves no fallback, second
  encoder, or transcoding; the Web UI reports the codec and unrelated pairs
  remain live. Native-Native edges retain the pre-Web compatibility preference
  ladder with one active codec and one encoder.
- One pair's injected signaling, ICE, transport, or backpressure failure does
  not change any other pair.
- Simultaneous full-roster delivery in different orders converges to the same
  pair set with one offerer per pair.
- Duplicate/stale/future roster snapshots and pair signals are inert or
  rejected without tearing down valid pairs.
- Noncreator leave removes only its incident pairs.
- Noncreator reconnect within grace preserves its handle and unaffected pairs.
- Creator reconnect within grace preserves the room and invite.
- Explicit creator leave and creator grace expiry end every participant cleanly
  with no election, locked state, or retry button.
- Real signed 2-, 3-, and 4-process acceptance verifies 1, 3, and 6 ready links,
  symmetric media/audio, join/leave churn, creator exit, and a soak run.
