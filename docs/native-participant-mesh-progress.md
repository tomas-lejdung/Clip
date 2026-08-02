# Server-Coordinated Participant Mesh Progress

This document tracks the clean-slate Live Share mesh introduced after the
native-v3 experiment. The normative architecture is documented in
`docs/server-coordinated-mesh-design.md`.

## Fixed product contract

- The service owns an opaque authoritative roster with at most four members.
- Every unordered participant pair owns exactly one direct WebRTC connection.
- Two, three, and four participants therefore have exactly one, three, and six
  pair connections respectively.
- The service relays only encrypted pair-signaling envelopes. Audio, video,
  source state, cursors, annotations, participant identities, SDP, and ICE
  plaintext never traverse the service.
- The invite path contains only an eight-character presentation code. The
  opaque API room ID and complete invitation capability are authenticated and
  encrypted in the URL fragment and never sent while the link is opened.
- One invite remains byte-for-byte stable across every join, leave, reconnect,
  and roster revision. Only the explicit **New Invite** action rotates it.
- Adding or removing a participant reconciles only incident pairs. Existing
  pairs are retained.
- A noncreator may leave without ending the room. Creator departure ends the
  room for everyone. There is no election, quorum, leadership handoff, or
  locked-room state.
- Capture, encoding, sender policy, source-aware 1x/Retina resolution, cursor,
  audio, viewer, and quality behavior must remain identical to the approved
  pre-mesh implementation.
- No legacy wire compatibility is required.

## Implemented

- v4 HTTP discovery and room creation.
- v4 WebSocket room protocol with complete authoritative roster snapshots.
- Opaque encrypted admission and creator-certified member descriptors.
- Stable client-secret invite fragment.
- Deterministic pair ID, offerer, epoch, and encrypted signaling contexts.
- Server roster reconciliation into one retained WebRTC transport per remote
  participant.
- Pair-scoped failures and retries that do not tear down unrelated links.
- Per-participant publishing of windows, fullscreen, system audio, source
  manifests, cursor events, and collaboration events.
- Creator-only admission, Access Word, Ask Before Joining, member removal,
  invite rotation, and room termination.
- Ordinary member leave and reconnect grace.
- Creator reconnect grace followed by terminal room closure.
- Common participant popover and diagnostics driven from the authoritative
  roster and concrete WebRTC link state.
- Canonical app/web invite grammar
  `/ROOMCODE#v=4&key=<sealed>&join=<capability>`, with Swift/JavaScript vectors.
- Signed four-step v4 friendship primitives, directional per-friend presence
  mailboxes, crash-safe local storage, and opaque encrypted presence transport.
- Friend add/remove presentation, private online presence, friend-initiated
  room join, and mandatory creator Allow/Deny for every friend join.
- Pair-local SDP recreation, canonical-offerer renegotiation, and fresh member
  incarnation handling so leave/rejoin never replaces an unrelated pair or
  resurrects stale source state.
- Authoritative source recovery and stale-capture-notice clearing after a
  publication succeeds or a participant incarnation changes.
- Actual negotiated codec, route, RTT, loss, bytes, available bitrate, encode,
  and receive-buffer values in directional diagnostics.
- Compact **Shared With You** navigation for remote sources while **Your
  Share** remains expanded, plus AV1, Native Display, and Max (20 Mbps) as the
  initial sender defaults.

## Verified evidence

The real server acceptance currently proves:

- roster sizes `2, 3, 4`;
- unordered pair counts `1, 3, 6`;
- twelve directed encrypted signaling messages for four participants;
- a stable invite across repeated joins;
- zero private values exposed to server-visible fields;
- ordinary member leave leaves three members and three pairs;
- creator leave sends terminal room-ended events.

Package tests additionally cover cryptographic admission, descriptor and
roster validation, deterministic pair identity, real WebRTC loopback, retained
pair identity during roster growth, isolated pair failure, source and audio
replication, reconnect, and creator termination.

The signed three-process GUI run on 2026-07-31 additionally proves:

- the same unchanged clipboard invite admitted A, B, and C;
- every participant showed three members and two direct links;
- A published Heynote and Scratch, B published Toggl and Untitled, and C
  published Xcode and Welcome; every participant received two windows from the
  other two people and reported three media streams;
- diagnostics reported negotiated AV1 at the real source resolutions together
  with P2P bytes and available bitrate rather than a hard-coded codec label;
- C leaving preserved A-B and its windows; C rejoining with the original invite
  restored both A and B windows immediately;
- C added A as a friend, A approved the signed friendship, private presence
  showed A as Live after C left, and the friend join required and passed a new
  explicit Allow/Deny decision before restoring the remote windows; and
- creator **End for Everyone** returned B and C directly to idle. Unified logs
  contained no Clip RTCP/SDP, stale-capture, locked-room, election, or crash
  message; only expected socket resets during leave/end and benign macOS system
  diagnostics remained.

## Verification status and remaining release gates

- The composed three-client app-session test is complete: it covers all three
  retained pair transports, all-source replication, signaling reconnect,
  ordinary member leave, and terminal creator departure as one system.
- Transient admission and signaling-send replay/idempotency coverage is
  complete, including pair-local backpressure and stale-sequence recovery.
- Capture and media policy parity with the approved pre-mesh baseline is
  complete, including the source-aware 1x/Retina resolution policy.
- The full deterministic Swift/Go/project/localization gate is complete:
  `./scripts/test.sh` passes; Core 81, Media 74, Capture 40, LiveShare 86, and
  WebRTC 76 pass; 394 hosted app tests pass with the one deliberately opt-in
  visual snapshot skipped; and the app links for arm64 under strict Swift 6.
- The isolated stable-signed three-process acceptance on the real local service
  is complete for invite reuse, one real window publication per participant, all-pairs
  reception, ordinary leave/rejoin, friend presence/approval, diagnostics, and
  creator termination.
- The post-review signed repeat is complete: the serialized signaling outbox
  retained exact-envelope retry attribution under test, while the real GUI run
  again reached three participants/two links each, three simultaneous real
  publications, retained A-B through C's leave, restored both publishers to C
  through the original invite, and terminated all participants cleanly. The
  participant and server logs contained no hidden SDP/RTCP-mux, capture,
  signaling-loss, election, locked-room, or crash error.
- Repeat the signed gate with four processes, real system audio/exclusions and
  Fullscreen; then run direct Internet/TURN, physical display/Spaces, churn,
  performance, and soak acceptance before release.

No election or legacy-compatibility work belongs in this plan.
