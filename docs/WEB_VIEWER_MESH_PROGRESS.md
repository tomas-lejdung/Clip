# Web Viewer Mesh — Implementation Board

Status values: `[ ]` pending, `[-]` in progress, `[x]` verified.

This board covers the first web participant release. The browser is a
receive-only member of the existing encrypted server-room-v4 mesh. It does not
introduce a browser-specific native connection path, media relay, codec
fallback, transcoding, friendship, collaboration, publishing, or room
administration.

## Invariants

- [x] Existing native-to-native pairs retain their transport identity,
  negotiation epoch, tracks, selected codec, and media continuity when a web
  participant joins or leaves.
- [x] Native capture, source-aware 1x/2x ScreenCaptureKit resolution, cursor
  capture, encoder quality, and system-audio publishing remain unchanged.
- [x] Every participant pair uses the same encrypted v4 signaling and direct
  WebRTC connection contract; `NATIVE` and `WEB` affect capabilities and UI,
  not routing.
- [x] Each publishing participant's selected codec is exact. Clip never creates a second encoding
  for a browser and never falls back to another codec. Unsupported browsers
  stay in the authoritative room roster; the affected peer edge may fail or
  remain black, and shows `Unsupported Encoding` when the codec is observable.
- [x] The canonical invite remains
  `https://service/ROOMCODE#v=4&key=...&join=...`; the unmodified Web client
  never places its fragment in a normal service request or log.

## 1. Baseline and contract

- [x] Create `codex/web-viewer-mesh` from the verified native mesh checkpoint.
- [x] Record the web-v1 product, privacy, capability, media, and follow rules.
- [x] Add a diff guard proving capture/Retina/quality implementation files did
  not change.
- [x] Preserve the existing native 2-, 3-, and 4-participant mesh tests.

## 2. Authenticated participant profile

- [x] Add closed, versioned `nativeApp/nativeV1` and
  `webViewer/webViewerV1` profiles to the signed encrypted member descriptor.
- [x] Reject unknown, mismatched, or noncanonical kind/profile combinations.
- [x] Document that the signed profile is a participant declaration, not
  Native application attestation; a custom client can claim `nativeV1`.
- [x] Surface Native/Web identity in participant presentation models.
- [x] Share cross-language canonical descriptor fixtures.

## 3. Exact codec contract

- [x] Restrict every video transceiver to the user-selected codec only.
- [x] Keep roster presence when an exact codec leaves that peer edge without a
  common video format. Show a precise unsupported-codec state when the codec is
  observable, while allowing an early-failed edge to remain unavailable or
  black. Do not redesign or split the proven native peer transport merely to
  retain audio.
- [x] Prove the unsupported-codec path never falls back or starts a second
  encoder.
- [x] Verify retained native links do not renegotiate when a web member joins.

## 4. Browser room security and session

- [x] Parse and decrypt the canonical fragment invite in-browser.
- [x] Implement canonical Web Crypto signing, possession, admission, roster
  verification, pair ECDH/HKDF/AES-GCM, and strict sequence validation.
- [x] Store a tab-scoped reconnect identity without exposing room secrets to
  URLs, logs, analytics, or third parties.
- [x] Implement waiting, approval, denial, full-room, reconnecting, room-ended,
  malformed, replay, and protocol-error states.
- [x] Keep the encrypted declared profile, identities, SDP, media, and source
  metadata hidden from an honest server deployment. HTTP/WebSocket endpoints
  may reveal use of the Web surface, but the unmodified client never sends the
  fragment secret or encrypted profile in a normal request. The serving origin
  remains trusted because modified same-origin JavaScript could read the
  fragment.
- [x] Require HTTPS for non-loopback browser invites; permit HTTP only for the
  exact development hosts `localhost`, `127.0.0.1`, and `[::1]`.

## 5. Browser peer mesh and media

- [x] Reconcile one browser `RTCPeerConnection` for every remote roster member.
- [x] Support the existing deterministic offerer and answerer roles.
- [x] Use the fixed contract: four video transceivers, one participant system
  audio transceiver, and one ordered reliable control DataChannel.
- [x] Publish an empty source snapshot and no browser media tracks.
- [x] Receive all native source snapshots and correlate tracks by stable
  participant/source identity rather than browser-generated track IDs.
- [x] Preserve browser-to-browser data-only mesh edges.

## 6. Web viewer product

- [x] Show participant roster, Native/Web badges, creator, and per-link P2P
  state.
- [x] Render all received windows with focused, grid, and compact-row layouts.
- [x] Support fit, fill, native-size, cursor-follow panning, and browser
  fullscreen.
- [x] Follow a participant: auto-select the sole sharer; require/select a
  participant when several share; follow their focused source; fail over in
  stable roster order when they stop or leave; never jump back unexpectedly.
- [x] Clicking a different participant's source switches Follow to that
  participant.
- [x] Add explicit audio unlock, master mute/volume, and per-participant
  mute/volume.
- [x] Hide publishing, friendship, collaboration, invite administration, room
  creation, approval, and removal controls.
- [x] Handle 1–4 sources per native publisher and all twelve possible incoming
  source slots in a full room.

## 7. Secure same-origin hosting

- [x] Serve `/ROOMCODE` and versioned viewer assets from the Go room service.
- [x] Keep all `/api/native/v4` routes and their restrictive CSP unchanged.
- [x] Apply a viewer-only CSP with no third-party scripts, styles, fonts,
  analytics, or CDN dependencies.
- [x] Document that CSP and fragment URL semantics do not protect against a
  malicious or compromised same-origin viewer deployment.
- [x] Reject traversal, invalid room paths, unsupported methods, and accidental
  asset/source-map exposure.
- [x] Define strong-ETag asset revalidation and no-store HTML behavior.

## 8. Verification

- [x] Cross-language invite, descriptor, admission, roster, pair-crypto,
  signaling, and source-snapshot vectors pass in Swift and JavaScript.
- [x] Browser malformed/replay/stale/future sequence tests pass.
- [x] Go static-route, CSP, cache, API-regression, and traversal tests pass.
- [x] The production Native transport and a browser-like receive-only libwebrtc
  endpoint negotiate in both offerer roles with four video receivers, one
  participant system-audio receiver, and no browser sender tracks.
- [x] A + B + Web forms all three links without changing A–B.
- [x] A + B + C + Web forms all six links without changing retained links.
- [x] Simultaneous publishers, source churn, audio toggles, follow failover,
  browser reload/reconnect, approval, denial, capacity, and room end pass.
- [x] Unsupported AV1/VP9 browser proves no fallback, no secondary encoding,
  a codec-specific error when observable, and no disturbance to any other peer
  edge.
- [ ] Desktop Safari and Chromium acceptance passes; mobile and Firefox remain
  explicitly unsupported for web-v1.
- [x] The dependency-free viewer shell renders in a controlled desktop browser
  with its assets, controls, and error state intact.
- [x] Update `spec.md`, server documentation, protocol documentation, and the
  final evidence summary.
