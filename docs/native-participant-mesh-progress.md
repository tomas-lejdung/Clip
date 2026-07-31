# Native participant mesh progress

Branch: `codex/native-participant-mesh`

Started: 2026-07-30

The older Live Share architecture and native-viewer progress documents are
historical implementation references only. They do not define compatibility
requirements or a supported connection path for this milestone.

## Goal

Native Clip participants should be able to join one room, receive every other
participant's shared sources, and publish their own sources at the same time.
There is no permanent media host/viewer distinction inside a native-v3 room.
The room creator is the initial admission and membership leader, but is not a
media relay: every admitted pair establishes its own encrypted WebRTC link.

Leadership can move without changing participant or source identity. A graceful
leader departure transfers authority before disconnecting. After an unexpected
loss, a strict majority of the last committed membership can certify one
deterministic successor; a minority partition cannot elect a competing leader.

The release gate enables four participants. That proves both a real
three-participant, three-link mesh and the complete six-link topology at the
product's current participant bound.

This is a clean-slate native room architecture. New rooms start directly as
native-v3 rooms, and every creator or joiner runs the same participant session.
There is no v1/v2 negotiation, in-place upgrade, legacy media mirror, or
backward-compatibility requirement. Existing implementation may be reused only
when it is a protocol-neutral building block required by v3; convenience alone
does not justify retaining an old connection path, wire type, role model,
entry point, UI, server route, browser asset, or compatibility test. The
shipped native room entry, session, admission, signaling, membership, media
publication, presentation, and teardown paths are v3-only.

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
                    │ current membership leader    │
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

- The current leader admits identities, signs short-lived membership
  credentials, publishes authoritative membership snapshots, and helps a
  joining participant establish its required peer links.
- Every participant publishes its own media and source state directly to every
  other participant. Clip does not forward another participant's media.
- Once a link exists, its renegotiation and source control use that link's
  ordered reliable DataChannel. The signaling service is not in the established
  media or control path.
- `End Room for Everyone` remains an explicit terminal action. An ordinary
  leader departure first commits a successor. If the leader disappears
  unexpectedly, established links continue while survivors attempt a
  term-scoped quorum election. Without a strict majority the room enters
  `leaderlessLocked`: media between surviving links may continue, but joins,
  reconnects and membership mutation remain unavailable.

## Invariants

### Participant and trust identity

- `ClipLiveShareParticipantID` is random per room. It is not a route ID,
  negotiation ID, saved contact, persistent identity fingerprint, or device
  name.
- Persistent P-256 identity proves which device signed a statement. It does not
  itself grant room membership.
- Persistent identity labels may make an approval decision easier, but they
  never silently grant membership. The current certified leader remains the
  only admission authority.
- The founding creator identity is retained as room provenance, while the
  current leader is identified by a positive leadership term and participant
  ID. A replacement leader is accepted only through a valid graceful-transfer
  certificate or a strict-majority election certificate rooted in the last
  committed membership digest.
- A participant's source identity is the tuple of publisher participant ID and
  source-instance ID. Equal source-instance bytes from two publishers are
  distinct sources.

### Membership

- The current leader signs a short-lived membership credential for every
  admitted participant, including itself.
- A current-leader-signed membership snapshot is the only authoritative member
  set.
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
- Votes are signed, term-scoped and bound to the last committed membership
  digest. A participant signs at most one candidate per term. A leadership
  transition requires more than half of the last committed members, preventing
  two network partitions from both acquiring authority.

### Topology and transport

- Native-v3 uses a complete mesh. For `n` participants it requires
  `n × (n - 1) / 2` peer links: 0, 1, 3, and 6 links for one through four
  participants.
- There is one WebRTC peer connection and one reliable ordered native-v3
  control channel per participant pair.
- SDP, ICE, peer-link revisions, and candidates are scoped to the canonical
  unordered participant-pair key. One pair cannot supersede another pair's
  negotiation.
- Media is never routed through the creator, signaling service, or another
  participant.
- A participant encodes and sends each local source to its remote peers. The
  initial small participant cap is the explicit CPU and upstream-bandwidth
  guard for this mesh behavior.
- Each participant may publish one optional mixed system-audio track. A
  receiver plays that participant's audio once regardless of video-source
  changes or renegotiation.

### State and revisions

Native-v3 has three independent positive revision
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
- Every active native-v3 participant uses the same room popover. `Your Share`
  contains local publication controls; every remote participant owns its own
  received windows, audio playback/volume and directional diagnostics. Creator
  authority changes available room actions, not the media layout.

## Initial limits

| Resource | Protocol bound | Initial product gate |
| --- | ---: | ---: |
| Native-v3 participants, including creator | 4 | 4 |
| Active shared sources per participant | 4 | 4 |
| Reserved video sender slots per participant | 4 | 4 |
| System-audio tracks per participant | 1 | 1 |
| Peer links in one room | 6 | 6 |

The product must remain fail-closed at this bound. Raising it later requires a
new CPU, upstream-bandwidth, thermal, audio-mixing, churn, and real-network
acceptance pass.

## Milestones

| ID | Lane | Status | Evidence-based outcome |
| --- | --- | --- | --- |
| MESH-00 | Invite and admission baseline | `DONE` | Production Create and Join use opaque encrypted rendezvous, route/session/candidate-bound possession proof, explicit approval, independent optional Access Word proof, bounded provisional admission, and exact failure cleanup. |
| MESH-01 | Native-v3 protocol foundation | `DONE` | V3 participant/source/link identity, signed membership and authority chains, independent revisions, strict closed codecs, complete-mesh bounds, canonical vectors, and tamper/replay/expiry/capacity rejection are implemented and covered by the native-v3 package gates. |
| MESH-02 | Remote presentation extraction | `DONE` | `RemoteParticipantPresentation` and participant-scoped window coordinators own remote windows, audio, sizing, cursor, focus, statistics, and reconciliation. Hosted presentation regressions cover Fit, Native, Follow, fullscreen, hide/reopen, geometry, and cleanup. |
| MESH-03 | Symmetric participant lifecycle | `DONE` | Create and Join construct the same participant session, which publishes locally while receiving every remote participant. Recording exclusion, cancellation tokens, session teardown, and late-callback isolation are production-wired and deterministically tested. |
| MESH-04 | Membership leadership | `DONE` | Admission/removal, graceful transfer, strict-majority crash election, terminal room end, full authority-chain catch-up, fork rejection, and quorum loss are implemented. A local leader locks authority below quorum and restores only after an exact-chain-confirmed quorum; its rendezvous and membership mutations remain closed while locked. |
| MESH-05 | Peer-link mesh manager | `DONE` | Every canonical pair has one authenticated WebRTC link and ordered v3 control channel. Initial targeting, direct renegotiation, stale/cross-pair rejection, independent failure/reconnect, low-water replay, and teardown pass manager and real loopback package gates. |
| MESH-06 | Participant source publication | `DONE` | Each participant publishes up to four namespaced sources through reserved per-peer slots. Deterministic three/four-participant integration covers independent manifests, add/update/remove, fullscreen and focused-window policy, and exact participant cleanup. |
| MESH-07 | Symmetric media and audio | `DONE` | Production transport wiring sends each local source and optional system-audio track to every peer and receives each remote participant independently. Deterministic manager, real WebRTC loopback, statistics, codec, isolation, and audio-track tests pass; real ScreenCaptureKit/audio hardware remains an external gate. |
| MESH-08 | Room and participant UI | `DONE` | The common room popover exposes `Your Share`, grouped remote participants, per-participant audio/volume and diagnostics, admission/removal/leadership actions, collaboration controls, and locked-authority state. Closing the room-global last remote video window prompts to stay or leave only when remote audio remains. |
| MESH-09 | Three-participant release gate | `EXTERNAL_GATE` | Deterministic three-participant topology and state pass. Release still requires three independently launched signed Clip apps sharing real ScreenCaptureKit video/system audio across all three links, including controlled direct Internet and TURN, leadership, multi-display behavior, churn, and soak. |
| MESH-10 | Four-participant release gate | `EXTERNAL_GATE` | Deterministic four-participant/six-link topology, publication, removal, failure isolation, and leadership pass. Release still requires four signed GUI processes plus real CPU, upstream, thermal, audio-mix, Internet/TURN, multi-display, churn, and soak evidence. |
| MESH-11 | Direct v3 application entry | `DONE` | Shipped Create Room and Join Invite enter the same v3 coordinator directly. Static clean-slate acceptance proves no production v1/v2 negotiation, upgrade, role handoff, mirroring, fallback, or browser participant path remains. |
| MESH-12 | Collaboration pointers and ink | `DONE` | Authenticated participant/source-bound pointer reveal, pings, bounded expiring vector strokes, clear semantics, coordinate mapping, overlays, and stale/wrong-source rejection are implemented and deterministically tested. |

### Completed deterministic boundary

Production Create Room and Join Invite are enabled through the direct-v3 path.
The security boundary that previously blocked production entry is complete:

- the closed, versioned native-v3 envelope has no legacy protocol cases;
- peer-link negotiation is context-bound to the canonical pair and its
  independent revision;
- participant possession proof binds the session, participant ID, membership
  credential digest, pair, ephemeral transport nonce, and lifetime; and
- canonical golden vectors plus negative tamper, replay, expiry, transplant,
  wrong-sender, stale, and capacity tests pass.

Source snapshots rely on the authenticated v3 peer-link mapping for their
`authenticatedParticipantID`; they are not safe to accept from an unbound
DataChannel or caller-supplied identity.

The frozen-tree local acceptance passed on 2026-07-31:

- `scripts/run-live-share-acceptance.sh` passed server tests, 72 focused
  protocol/security/lifecycle tests, 8 rendezvous tests, WebRTC mesh-manager
  and real-loopback package gates, and the hosted native-v3 mesh suites.
- The complete stable-signed hosted app suite passed 364 of 365 tests with
  zero failures; the one deliberate skip is an external acceptance lane.
- Strict package totals passed: ClipCore 81, ClipMedia 74, ClipCapture 37,
  ClipLiveShare 97, and ClipLiveShareWebRTC 66.
- `go test -race ./...` and `go vet ./...` passed for the opaque rendezvous
  service.

This evidence is deterministic/local. It does not replace the `EXTERNAL_GATE`
work for independently launched signed GUI processes, privacy-authorized real
ScreenCaptureKit video and system audio, direct Internet/TURN traversal,
physical multi-display behavior, thermal/resource observation, repeated churn,
or the required soak.

## Join and leave sequence

The production bounded join is:

1. The current leader publishes an encrypted, authenticated v3 room invitation
   over a rendezvous route. The route is transport only and conveys no
   membership.
2. The candidate proves possession of the invitation secret and its persistent
   identity; the current leader performs the explicit approval boundary.
3. The leader assigns a random room-scoped participant ID and signs a
   short-lived membership credential.
4. Existing members receive the proposed member credential and establish the
   new canonical pair links. Initial targeted SDP/ICE may be coordinated by the
   creator, but media is never sent through it.
5. After bounded readiness acknowledgements, the current leader signs the next
   membership snapshot.
6. Each member verifies and transactionally applies that snapshot only when
   all of its required local links are ready.
7. The new member publishes source state; each source remains owned and
   revisioned by that publisher.

Timeout, denial, invalid signature, missing capability, missing link,
uncertified leader change, or product-capacity failure aborts the proposal and
removes provisional resources. A normal participant departure is an
authoritative newer snapshot followed by exact link and presentation cleanup.

The leader has two explicit exits:

- `End Room for Everyone` signs terminal room state and closes every link.
- `Leave Room` selects the deterministic eligible successor, commits the next
  leadership term and membership without the departing leader, then closes its
  own links.

After an unexpected leader loss, survivors retain their established media and
exchange one signed vote per next term. A strict majority of the last committed
membership can certify a successor and resume membership operations. Without
that quorum the room remains `leaderlessLocked`. A replacement leader may need
to advertise a new invite/room route; keeping the same server lease across a
crashed owner is not required for the first implementation.

## Clean-slate boundary

- Create Room and Join Invite enter native-v3 directly.
- There is no supported browser-v1 or native-v2 participant in a v3 room.
- There is no protocol upgrade, dual session, host/viewer handoff, or mirrored
  media path.
- The server rendezvous, encryption, identity, WebRTC, ScreenCaptureKit, source
  selection, remote-window and settings implementations may be reused only as
  protocol-neutral internal components. Reuse does not preserve their old wire
  roles, entry points, session ownership, or lifecycle.
- Obsolete v1/v2 connection, negotiation, upgrade, mirroring, handoff, and
  fallback code has been removed rather than retained for compatibility.
- Static acceptance fails if the shipped Create Room or Join Invite route
  references a legacy host/viewer coordinator or emits a legacy wire message.
- Unknown native identities may be manually admitted by the leader and receive
  a valid short-lived credential. Admission does not silently create a saved
  contact or future trust decision.

## Collaboration in the current mesh milestone

Pointer reveal, ping, and temporary drawing are implemented in this milestone.
They use the existing bidirectional DataChannels and stable
participant/source coordinate contract; they do not need another media codec
or server feature.

### Implemented — reveal pointer and ping

- Send participant ID, source key, normalized source coordinates, sequence,
  timestamp, visibility, and optional ping events.
- Render a colored, named pointer locally above the relevant source instead of
  burning it into video.
- Bind collaboration to each publication's random source-instance ID and apply
  revision, bounds, cadence, and stale-event checks. Removing a publication
  removes its overlay and sequence ledgers; a republished window gets a new
  source-instance ID.
- Let a participant reveal/hide its pointer explicitly; merely viewing never
  transmits pointer position.

### Implemented — temporary drawing

- Send bounded vector stroke begin/points/end events in source coordinates.
- Give every stroke an origin participant, source key, stable stroke ID,
  color, and expiry.
- Render the same resolution-independent overlay in native participants.
- Support source-publisher clear, per-participant clear, and automatic expiry.

### Deferred — persistent annotations

- Define bounded annotation snapshots/clear epochs and deterministic conflict
  behavior before persisting or replaying ink.
- Keep overlays outside captured source pixels to avoid feedback loops.

These phases never inject mouse or keyboard input into another Mac. Remote
control requires a separate permission, security, and product design.

## Acceptance gates

### Deterministic protocol and state — `DONE`

- Stable canonical vectors pass for v3 credentials, snapshots, participant
  source state, authority history, and peer-link negotiation.
- Tests reject tamper, replay, expiry, wrong-session, wrong-leader, self-link,
  duplicate participant, duplicate identity, capability mismatch, zero/stale
  revision, fork/rollback, and five-participant input.
- Membership and complete authority-chain application are transactional, with
  independent membership, publisher, and peer-link revision ledgers.
- Complete-mesh topology counts of 0, 1, 3, and 6 pass, including rejection
  when a required local link is missing.
- Static clean-slate acceptance proves direct-v3 room creation and joining
  cannot emit or require a legacy host/viewer message.

### Deterministic transport and application — `DONE`

- The real WebRTC in-process two-participant loopback passes with both
  participants publishing video, source lifecycle, cursor state, and audio
  while receiving the other.
- Deterministic three- and four-participant integration passes with 3 and 6
  independent links, four local source slots per participant, and no duplicate
  source/audio presentation.
- Peer-specific negotiation, congestion, disconnect, rejoin, catch-up, and
  teardown are isolated from other links and publishers.
- Remote presentation regressions preserve Fit, Native, Follow, fullscreen,
  visibility, focus, audio, statistics, last-window audio behavior, and
  reconnection.
- The strict Swift 6, package, server-race/vet, and stable-signed hosted app
  gates pass without pointer or privacy permission use.

### External real-device acceptance — `EXTERNAL_GATE`

- Independently launched, stably signed Clip apps must complete direct-v3
  invite joins with optional Access Word and explicit approval; all
  participants must share privacy-authorized real ScreenCaptureKit sources and
  system audio while receiving every other participant.
- Add, remove, resize, focus, fullscreen, Auto Share, Fit, Native, Follow,
  hide/reopen, bring-to-front, and stop/restart work from either participant.
- Retina/non-Retina source and receiver combinations retain the established
  source-aware ScreenCaptureKit resolution and native cursor behavior.
- Physical multi-display combinations, display disconnect/reconnect, Spaces,
  window ordering, overlay exclusion, and Retina/non-Retina combinations must
  be exercised.
- Direct Internet ICE and configured TURN relay must both pass; loss of the
  signaling service after establishment must not stop existing peer
  media/control.
- Denial, timeout, invalid credential, link failure, participant removal,
  intentional room end, leadership transfer, app quit, and crash/relaunch
  leave no ghost windows, audio, capture, routes, or membership.
- Graceful leader departure commits a successor without interrupting surviving
  media. Unexpected leader loss with quorum elects exactly one successor and
  permits a replacement invite; without quorum it preserves established media
  in `leaderlessLocked` and rejects membership mutation.
- Three-party real-network, CPU, thermal, upstream, audio-mix and leadership
  transfer evidence is mandatory. Equivalent six-link evidence is mandatory
  for the four-participant release gate. Repeated churn and the required soak
  must pass at both release topologies.

## Non-goals for the initial mesh milestone

- An SFU, MCU, server-side media forwarding, recording bot, or server-owned
  participant graph.
- More than four enabled participants.
- Preserving the same server room lease after an ungraceful leader crash.
- Unsafe minority election or admitting/reconnecting members while no
  leadership quorum exists.
- More than four active local sources per participant.
- Remote keyboard/mouse control, filesystem transfer, voice chat, messaging, or
  persistent whiteboards.
- Replacing WebRTC or ScreenCaptureKit.
- Treating a saved identity label, room name, route ID, or possession of an
  incomplete invite as membership authorization.
