# Native participant mesh progress

Branch: `codex/native-participant-mesh`

Started: 2026-07-30

Existing native protocol: [NATIVE_V2.md](../Packages/ClipLiveShare/NATIVE_V2.md)

Existing Live Share architecture:
[live-share-architecture.md](live-share-architecture.md)

Existing native viewer progress:
[native-friends-viewer-progress.md](native-friends-viewer-progress.md)

## Goal

Native Clip participants should be able to join one room, receive every other
participant's shared sources, and publish their own sources at the same time.
There is no permanent media host/viewer distinction inside a native-v3 room.
The room creator remains the fixed admission and membership authority, but is
not a media relay: every admitted pair establishes its own encrypted WebRTC
link.

The first product milestone deliberately enables two participants. The wire and
state foundation is bounded for four so expanding the product limit does not
require replacing identities, source keys, revision domains, or topology.

## Status model

- `PENDING` — accepted scope with no complete production implementation yet.
- `IN_PROGRESS` — implementation or its named deterministic evidence is being
  built.
- `DONE` — production wiring and deterministic unattended evidence are
  complete.
- `EXTERNAL_GATE` — deterministic work is complete, but acceptance still
  requires independently launched signed apps, privacy-authorized capture,
  physical displays, or controlled remote networks.

## Architecture

```text
                         admission and membership
                    ┌──────────────────────────────┐
                    │ fixed room creator / leader  │
                    └──────────────────────────────┘
                         ╱          │          ╲
                        ╱           │           ╲
             participant A ── participant B ── participant C
                       ╲             │             ╱
                        ╲──────── participant D ──╱

             Every line between members is one direct WebRTC peer link.
             The creator coordinates membership, not participant media.
```

The coordination plane and media plane are intentionally different:

- The creator admits identities, signs short-lived membership credentials,
  publishes authoritative membership snapshots, and helps a joining
  participant establish its required peer links.
- Every participant publishes its own media and source state directly to every
  other participant. Clip does not forward another participant's media.
- Once a link exists, its renegotiation and source control use that link's
  ordered reliable DataChannel. The signaling service is not in the established
  media or control path.
- An intentional creator shutdown ends the room in the initial implementation.
  If the creator disappears unexpectedly, already-established links between
  remaining members continue in `leaderlessLocked` state. Membership is frozen:
  no join, reconnect, removal, or new credential can be authorized until a
  later explicit creator-transfer design exists. There is no hidden leader
  election or ambiguous split-brain recovery.

## Invariants

### Participant and trust identity

- `ClipLiveShareParticipantID` is random per room. It is not a route ID,
  negotiation ID, friend record, persistent identity fingerprint, or device
  name.
- Persistent P-256 identity proves which device signed a statement. It does not
  itself grant room membership.
- Friendship can make an approval decision easier, but it never silently grants
  membership. The creator remains the only admission authority.
- The creator identity and creator participant ID are fixed for the room
  lifetime. A correctly signed snapshot from a replacement creator is still
  rejected.
- A participant's source identity is the tuple of publisher participant ID and
  source-instance ID. Equal source-instance bytes from two publishers are
  distinct sources.

### Membership

- The creator signs a short-lived membership credential for every admitted
  participant, including itself.
- A leader-signed membership snapshot is the only authoritative member set.
  It contains unique participant IDs and unique persistent identities in a
  canonical order.
- Admission is bounded and transactional: candidate links are provisional
  until the creator commits a newer snapshot. A failed join must not expose a
  half-member or leave stale source state.
- Every participant validates the complete snapshot, its own membership,
  creator continuity, capability baseline, expiry, and all of its required
  local peer links before applying it.
- Removing a participant advances membership state and tears down exactly that
  participant's links, sources, audio, cursors, statistics, and presentation.

### Topology and transport

- Native-v3 uses a complete mesh. For `n` participants it requires
  `n × (n - 1) / 2` peer links: 0, 1, 3, and 6 links for one through four
  participants.
- There is one WebRTC peer connection and one reliable ordered native-v3
  control channel per participant pair.
- SDP, ICE, peer-link revisions, and candidates are scoped to the canonical
  unordered participant-pair key. One pair cannot supersede another pair's
  negotiation.
- Media is never routed through the creator, signaling service, browser viewer,
  or another participant.
- A participant encodes and sends each local source to its remote peers. The
  initial small participant cap is the explicit CPU and upstream-bandwidth
  guard for this mesh behavior.
- Each participant may publish one optional mixed system-audio track. A
  receiver plays that participant's audio once regardless of video-source
  changes or renegotiation.

### State and revisions

Native-v3 does not reuse native-v2's host-owned
`ClipLiveShareStateRevision`. It has three independent positive revision
domains:

- one room-global membership revision;
- one source-state revision per publishing participant; and
- one peer-link negotiation revision per canonical participant pair.

A stale update in one domain cannot block a newer update in another. Snapshot
and source application is transactional: failed validation leaves the previous
accepted state unchanged.

### Presentation and application lifecycle

- A native-v3 Clip process is one participant that can publish and receive
  concurrently.
- `RemoteParticipantPresentation` owns the windows, audio presentation, cursor,
  source reconciliation, and statistics for one remote participant. It does
  not own invite parsing, admission, membership, or WebRTC negotiation.
- Current Fit, Native, Follow, fullscreen, bring-to-front, identity color, and
  multi-window behavior remain per remote source.
- Recording remains mutually exclusive with Live Share. Symmetric sharing does
  not make the recording pipeline part of a room.
- Late callbacks carry session, participant, source, and link context and must
  not revive a departed participant or superseded room.

## Initial limits

| Resource | Protocol bound | Initial product gate |
| --- | ---: | ---: |
| Native-v3 participants, including creator | 4 | 2 |
| Active shared sources per participant | 4 | 2 |
| Reserved video sender slots per participant | 4 | 4 |
| System-audio tracks per participant | 1 | 1 |
| Peer links in one room | 6 | 1 |

The protocol bound is not a claim that three- or four-participant rooms are
ready for release. Increasing the product gate requires the multi-party
performance and real-network acceptance listed below.

## Milestones

| ID | Lane | Status | Evidence-based outcome |
| --- | --- | --- | --- |
| MESH-00 | Invite and admission baseline | `DONE` | Anonymous invites now require a route-, session-, viewer-key-, challenge-, and room-bound join-capability proof; an Access Word is an independent optional proof. Prepared routes retain the viewer key, limits are fail-closed, invites are redacted from descriptions, and server admission is bounded before peer allocation. |
| MESH-01 | Native-v3 protocol foundation | `IN_PROGRESS` | Additive v3 participant IDs, capabilities, source and link keys, leader-signed credentials and snapshots, independent revision domains, complete-mesh topology, strict codecs, and negative/golden-vector tests are being implemented without changing v1 or v2 decoding. |
| MESH-02 | Remote presentation extraction | `IN_PROGRESS` | Existing native-viewer windows, audio, sizing, cursor, focus, statistics, and reconciliation are being separated into `RemoteParticipantPresentation` so the same presentation path can be instantiated for every remote mesh member. |
| MESH-03 | Symmetric participant lifecycle | `PENDING` | Replace the app-level host-or-viewer assumption for native-v3 with one participant session that owns local publishing plus a set of remote participant presentations. Preserve recording exclusion and deterministic teardown. |
| MESH-04 | Creator membership coordinator | `PENDING` | Issue credentials, propose bounded membership, gather peer-link readiness, commit signed snapshots, remove members, expire provisional joins, end on intentional creator shutdown, and enter `leaderlessLocked` after unexpected creator loss without tearing down surviving established links. |
| MESH-05 | Peer-link mesh manager | `PENDING` | Establish and authenticate every required pair, route initial targeted negotiation without relaying media, move renegotiation to the direct control channel, isolate link failure, and reject stale/cross-pair revisions. |
| MESH-06 | Participant source publication | `PENDING` | Namespace local source manifests by participant, publish up to two active sources through reserved per-peer slots, preserve Auto Share and fullscreen exclusivity locally, and reconcile add/update/remove independently for each publisher. |
| MESH-07 | Symmetric media and audio | `PENDING` | Send local capture to every remote peer, receive every remote participant's video and optional audio once, retain per-link quality/statistics, and prevent one slow peer from backpressuring another. |
| MESH-08 | Room and participant UI | `PENDING` | Present one participant list, clear creator and connection state, each participant's source controls, local sharing controls while receiving, approval/removal/error states, and bounded resource summaries in the unified fluid popover design. |
| MESH-09 | Two-participant release gate | `PENDING` | Two signed Clip processes can both share, receive, resize, add/remove sources, publish audio, reconnect, and stop independently over direct and TURN paths without server-owned trust or media. |
| MESH-10 | Three/four-participant expansion | `PENDING` | Raise the product gate only after 3-link and 6-link rooms pass CPU, upstream bandwidth, independent adaptation, churn, audio-mixing, and real-network acceptance. |
| MESH-11 | Compatibility and migration | `PENDING` | Native-v3 negotiation remains additive; existing browser-v1 and native-v2 joins continue unchanged and fail closed rather than partially decoding v3 messages. |
| MESH-12 | Collaboration pointers and ink | `PENDING` | Add participant pointers, pings, and bounded vector annotations only after the media mesh and source-coordinate contract are stable. |

### Current checkpoint boundary

The first `MESH-01` checkpoint includes the isolated identities, capabilities,
signed membership resources, independent revision ledgers, source ownership,
bounded topology, and transactional local-link readiness. Its sorted-key JSON
helper is deliberately module-internal; it is not a public wire codec.

Native-v3 must not be selected by production negotiation until the remaining
security boundary is implemented and tested:

- a closed, versioned native-v3 envelope whose cases cannot encode or decode
  browser-v1 or native-v2 values;
- context-bound peer-link negotiation payloads for the canonical pair key and
  its independent negotiation revision;
- a participant-signed possession handshake binding the session, participant
  ID, membership-credential digest, peer-link key, and ephemeral transport;
- fixed canonical golden vectors and the complete negative/tamper matrix.

Source snapshots intentionally rely on the future authenticated peer-link
mapping for their `authenticatedParticipantID`; they are not safe to accept
from an unbound DataChannel or caller-supplied identity.

## Join and leave sequence

The intended bounded join is:

1. The candidate reaches the creator through the existing encrypted invite or
   Friend rendezvous and completes the current proof/approval boundary.
2. Native capability negotiation selects v3. A v1/v2 client remains on its
   existing path.
3. The creator assigns a random room-scoped participant ID and signs a
   short-lived membership credential.
4. Existing members receive the proposed member credential and establish the
   new canonical pair links. Initial targeted SDP/ICE may be coordinated by the
   creator, but media is never sent through it.
5. After bounded readiness acknowledgements, the creator signs the next
   membership snapshot.
6. Each member verifies and transactionally applies that snapshot only when
   all of its required local links are ready.
7. The new member publishes source state; each source remains owned and
   revisioned by that publisher.

Timeout, denial, invalid signature, missing capability, missing link, creator
change, or product-capacity failure aborts the proposal and removes provisional
resources. A normal participant departure is an authoritative newer snapshot
followed by exact link and presentation cleanup. Intentional creator shutdown
ends the room; unexpected creator loss freezes membership as
`leaderlessLocked` while surviving established peer links continue.

## Compatibility path

- Browser protocol v1, its URL fragment, encrypted codec, JavaScript viewer,
  admission flow, and four-track host behavior remain unchanged.
- Native-v2 Friends, one-way invite viewing, persistence, and current control
  label remain unchanged.
- Native-v3 uses a distinct control label, versioned codecs, canonical domains,
  capability hello, and state types. V1/v2 decoders reject v3 and the v3
  decoder rejects v1/v2.
- The existing invite and Friend routes are admission bootstraps, not v3
  membership statements. Upgrade occurs only after both native apps advertise
  the required v3 capability baseline.
- A legacy viewer may continue viewing the creator through the existing
  one-way peer. It is not a mesh member and cannot publish.
- The first compatibility release does not proxy another participant's media
  to a browser or v2 viewer. Such clients see only the sources supported by
  their existing creator-owned protocol.
- Unknown native identities may be manually admitted by the creator and receive
  a valid short-lived credential. They are not silently persisted as Friends.

## Later collaboration phases

Pointers and drawing use the already bidirectional DataChannels; they do not
need another media codec or server feature. They remain later phases so their
coordinate contract can be built on stable participant/source identity.

### Phase C1 — reveal pointer and ping

- Send participant ID, source key, normalized source coordinates, sequence,
  timestamp, visibility, and optional ping events.
- Render a colored, named pointer locally above the relevant source instead of
  burning it into video.
- Apply source-generation, revision, bounds, cadence, and stale-event checks.
- Let a participant reveal/hide its pointer explicitly; merely viewing never
  transmits pointer position.

### Phase C2 — temporary drawing

- Send bounded vector stroke begin/points/end events in source coordinates.
- Give every stroke an origin participant, source key, stable stroke ID,
  color, and expiry.
- Render the same resolution-independent overlay in native participants.
- Support host-visible clear, per-participant clear, and automatic expiry
  before persistent annotation or undo history.

### Phase C3 — persistent annotations and web

- Define bounded annotation snapshots/clear epochs and deterministic conflict
  behavior before persisting or replaying ink.
- Add browser rendering only through an explicit compatible protocol extension;
  v1 browsers must safely ignore unsupported collaboration state.
- Keep overlays outside captured source pixels to avoid feedback loops.

These phases never inject mouse or keyboard input into another Mac. Remote
control requires a separate permission, security, and product design.

## Acceptance gates

### Deterministic protocol and state

- Stable canonical vectors for v3 credentials, snapshots, participant source
  state, and peer-link negotiation.
- Tamper, replay, expiry, wrong-session, wrong-leader, self-link, duplicate
  participant, duplicate identity, capability-bound, zero/stale revision, and
  five-participant rejection.
- Transactional membership application and independent membership, publisher,
  and peer-link revision ledgers.
- Complete-mesh topology counts of 0, 1, 3, and 6 and rejection when a local
  required link is missing.
- Existing browser-v1 and native-v2 golden vectors remain byte-identical.

### Deterministic transport and application

- In-process two-participant loopback where both participants publish video,
  source lifecycle, cursor state, and audio while receiving the other.
- Three- and four-participant loopbacks before raising the product limit,
  proving 3 and 6 independent links without duplicate source/audio
  presentation.
- Peer-specific negotiation, congestion, disconnect, rejoin, and teardown do
  not corrupt another link or publisher's state.
- Remote presentation extraction preserves every current native-viewer sizing,
  fullscreen, visibility, focus, audio, statistics, and reconnection test.
- Strict Swift 6 build and tests remain pointer-free and permission-free.

### External real-device acceptance

- Two independently launched, stably signed Clip apps complete invite and
  Friend joins, both share two real sources, and both receive the other's
  sources and system audio.
- Add, remove, resize, focus, fullscreen, Auto Share, Fit, Native, Follow,
  hide/reopen, bring-to-front, and stop/restart work from either participant.
- Retina/non-Retina source and viewer combinations retain the established
  source-aware ScreenCaptureKit resolution and native cursor behavior.
- Direct ICE and configured TURN relay both pass; loss of the signaling service
  after establishment does not stop existing peer media/control.
- Denial, timeout, invalid credential, link failure, participant removal,
  intentional creator shutdown, app quit, and crash/relaunch leave no ghost
  windows, audio, capture, routes, or membership.
- Unexpected creator loss preserves already-established remaining peer links
  in `leaderlessLocked`, rejects joins and reconnects, and cannot mutate the
  last verified membership snapshot.
- Browser-v1 and native-v2 clients still complete their current one-way
  journeys against the same build.
- Three/four-party real-network, CPU, thermal, upstream, and audio-mix evidence
  is mandatory before increasing the initial two-participant gate.

## Non-goals for the initial mesh milestone

- An SFU, MCU, server-side media forwarding, recording bot, or server-owned
  participant graph.
- More than two enabled participants before the explicit expansion gate.
- Leader election, creator migration, split-brain recovery, or admitting and
  reconnecting members after the creator is unexpectedly lost. Existing
  authenticated links may continue in the locked membership state.
- Transcoding or forwarding another participant's source for legacy viewers.
- More than two active local sources per participant.
- Remote keyboard/mouse control, filesystem transfer, voice chat, messaging, or
  persistent whiteboards.
- Replacing WebRTC, ScreenCaptureKit, native-v2 Friends, or the browser-v1
  fallback.
- Treating friendship, a room name, a route ID, or possession of an incomplete
  invite as membership authorization.
