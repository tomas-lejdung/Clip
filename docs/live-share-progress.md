# Clip Live Share progress board

Branch: `codex/native-live-share-server`

Last updated: 2026-07-20

Architecture: [live-share-architecture.md](live-share-architecture.md)

Protocol: [clip-live-share-protocol-v1.md](clip-live-share-protocol-v1.md)

Acceptance: [ACCEPTANCE.md](ACCEPTANCE.md)

This board tracks the complete in-repository server/viewer replacement. The
branch is not published and development does not replace `/Applications/Clip.app`.

## Status model

- `DONE` — implementation and deterministic evidence are complete.
- `IN_PROGRESS` — implementation exists, but integration or named evidence is
  still being completed on this branch.
- `EXTERNAL_GATE` — implementation exists, but evidence requires a real Mac,
  network path, permission, signing identity, or published deployment.
- `DEFERRED` — explicitly outside this milestone.

## Milestone board

| ID | Lane | Status | Evidence-based outcome |
| --- | --- | --- | --- |
| LS-00 | Protocol and trust model | `DONE` | `clip-live-share` v1 is the sole contract. The server sees room/routing metadata and bounded ciphertext, while Clip owns admission, peer state and viewer count. Protocol limits, lifecycle and deployment trust are documented. |
| LS-01 | Core crypto and messages | `DONE` | Swift P-256 ECDH, HKDF-SHA256, directional AES-GCM, typed identifiers/messages, strict limits, random stream identities and browser-compatible vectors have deterministic coverage. |
| LS-02 | In-repo Go service | `DONE` | The top-level `server/` module implements in-memory leases, owner-token-hash authentication, host reconnect grace, route isolation, strict opaque relay, origin policy, capabilities, viewer embedding, health/version and graceful shutdown. |
| LS-03 | Browser viewer | `DONE` | The embedded viewer performs fragment-pinned key agreement, encrypted admission/SDP/ICE, opaque manifest binding, reconnect, multi-stream presentation, system-audio playback, mute/volume and autoplay recovery. Node protocol tests cover crypto, tamper, replay and bounds. |
| LS-04 | Native signaling transport | `DONE` | Clip advertises rooms, authenticates with an owner token, handles encrypted per-viewer routes, re-advertises indefinitely with a capped backoff, removes its room on stop, enforces negotiated limits, isolates hostile routes and keeps secrets out of public snapshots. Mock, hostile-input and real-WebKit integration coverage pass. |
| LS-05 | Coordinator migration | `DONE` | Host-side access-code admission, encrypted initial negotiation, browser-reported handoff plus host-confirmed DataChannel readiness, peer-owned viewer counts, authoritative control manifests and peer survival across signaling outages are production-wired. Obsolete legacy code, fixtures, scripts and assumptions are removed. |
| LS-06 | Native WebRTC media | `DONE` | Four random-identity video slots, random audio identity, exact H.264/VP8 choices, VP9/AV1 preference fallback, transactional live switching, RTP statistics, bounded frame delivery, reliable `clip-control-v1`, authoritative audio state, Opus input and peer-isolated teardown pass the 80-test package gate. |
| LS-07 | Capture and streaming | `EXTERNAL_GATE` | Software VP8/VP9/AV1 preserve native geometry; oversized hardware H.264 is bounded without unbounded queues. Window-audio filters deduplicate owning applications; Fullscreen excludes Clip. Real desktop/audio/overload evidence remains controlled-Mac work. |
| LS-08 | Live Share interface | `DONE` | Popover, endpoint settings, overlays, HUD, source controls, unavailable-link behavior and permission-free presentation tests use the native room/link model. Settings probes stream through a hard response-size bound. |
| LS-09 | Privacy and reliability | `DONE` | The server cannot decrypt signaling; secrets are session-only; replay/tamper/size/route checks, persistent capped reconnect, per-peer failure isolation, admission timeouts, bounded queues and static log/storage scans pass. Runtime network/soak evidence remains under LS-12. |
| LS-10 | Local acceptance | `DONE` | The unified pointer-free gate passes the hardened Go service, 11 browser crypto/protocol tests, 55 core tests, a real offscreen WebKit encrypted video/audio flow and all 80 native WebRTC tests. The full hosted app suite and strict Swift 6 source/link/test-source gate also pass. |
| LS-11 | Packaging and self-hosting | `EXTERNAL_GATE` | Non-root multi-architecture Docker build/publish support and deployment documentation exist, and the Release app compiles and links. The installed Apple Development certificate expired in 2025, so valid distribution signing, final container publication/inspection and the DMG remain deliberate release actions. |
| LS-12 | Controlled real-Mac acceptance | `EXTERNAL_GATE` | Requires ScreenCaptureKit permission and owner-authorized runtime testing for real window/Fullscreen video, browser audio, overlays, focus churn, sleep/wake and lifecycle soak. |
| LS-20 | Native Clip viewer | `DEFERRED` | A future Clip-to-Clip receiver may reuse the same encrypted signaling and WebRTC protocol after measurement. Browser viewing remains the supported receiver now. |

## Completed deterministic evidence

### Server and browser

- The Go suite covers room normalization, owner-token hashing, idempotent
  advertisement, ownership conflicts, leases, reconnect grace, room/connection
  ceilings, route isolation, monotonic relay sequences, idle cleanup, strict
  message bounds, security headers, origin policy and actual localhost
  WebSocket routing.
- The service exposes only public capabilities and process-only health/version
  information. Room state is memory-only and no room/viewer metrics endpoint is
  exposed.
- Browser protocol tests use deterministic P-256/HKDF/AES-GCM vectors shared
  with Swift and reject changed associated data, invalid tags, replay, sequence
  gaps, route mismatch and oversized inner messages.
- Viewer assets are embedded in the Go binary. The viewer reads the room public
  key from `location.hash`, sends only its own public key through the server,
  decrypts host admission locally, binds opaque tracks to manifests, and
  attaches the optional remote audio track.

### Native core and transport

- `Packages/ClipLiveShare` owns typed room/route/session/negotiation and opaque
  media identifiers, capabilities, outer and inner messages, cryptography,
  state transitions and four-source allocation.
- The maximum decrypted payload is 196,400 bytes. Tests prove its encrypted,
  base64url JSON envelope remains within the 262,144-byte WebSocket ceiling.
- Every Live Share session allocates new random stream/media identifiers. A
  source can stop and restart within one session without making protocol
  meaning depend on a fixed `video0` name or SDP `mid` arithmetic.
- `Packages/ClipLiveShareWebRTC` is the only target importing the pinned WebRTC
  framework. It owns peers, codecs, SDP/ICE, DataChannel, statistics and the
  PCM-to-Opus bridge behind Swift 6-safe boundaries.

### Admission and trust

- Clip generates the owner token and ephemeral room P-256 identity. The server
  receives it only when the room is advertised, the host connects, or the room
  is removed, and stores only its hash; the token is never exposed to viewers.
- The URL fragment contains the ephemeral room public key and is not included
  in the viewer's HTTP request. Per-route viewer ECDH derives independent
  directional AES-GCM keys.
- The optional access code is checked by Clip through an encrypted random
  challenge/HMAC proof. Its value is never sent to the service or persisted.
- After the ordered reliable DataChannel opens, the temporary viewer signaling
  route closes. Established peers are not dependent on the host signaling
  socket staying continuously connected.

### Audio and controls

- A persisted, default-Off toggle drives one deduplicated ScreenCaptureKit
  audio session: unique owning applications for window sources or system audio
  excluding Clip for Fullscreen.
- Borrowed 48 kHz stereo samples feed one Opus send track through the native
  bridge. No microphone track exists.
- The browser viewer has audible playback support, mute and volume controls,
  and an explicit user-gesture recovery when autoplay is blocked.
- Durable DataChannel state is regenerated from authoritative snapshots after
  low-water drain instead of accumulating an application queue. Cursor state
  is deliberately ephemeral.

## Unified local acceptance

Run:

```sh
./scripts/run-live-share-acceptance.sh
```

The lane is repository-local and pointer-free. It runs Go tests, browser
protocol tests, starts the real server on an unused loopback port, validates
health/version/capabilities and the embedded viewer, then runs the Swift Live
Share and WebRTC package suites, including the opt-in offscreen WebKit
end-to-end case against that loopback endpoint. It does not launch or replace
the installed app, capture the desktop, use privacy permissions, or depend on a
sibling checkout.

## Remaining controlled and release gates

These must not be inferred from loopback tests:

- [x] Complete coordinator migration and remove every obsolete signaling type,
  fixture, environment variable and test assumption.
- [x] Pass the unified local acceptance gate, full hosted app suite, strict
  Swift 6 source/link/test-source gate, documentation audit and legacy search
  from the final source tree.
- [ ] Share one through four real windows, dynamically add/remove and resize,
  toggle Fullscreen, and stress rapid focus/auto-share transitions.
- [ ] Verify H.264, VP8, VP9 and AV1 with real content, actual sender codec
  statistics, live switching, pressure reporting and subjective text quality.
- [ ] Capture real application-scoped and Fullscreen system audio, prove Clip is
  excluded, and hear synchronized audio in the embedded browser viewer.
- [ ] Prove the focused-window chip and HUD consume clicks, place correctly on
  secondary displays/Spaces and never appear in shared pixels.
- [ ] Exercise direct remote Internet ICE plus a controlled configured TURN
  relay. Loopback establishes neither.
- [ ] Exercise sleep/wake, display/window removal, permission revocation,
  server restart/re-advertisement, sustained overload, repeated start/stop and
  a ten-minute share while resources return to idle.
- [ ] Scan runtime logs, preferences, History and caches for access-code text,
  owner/private keys, SDP, ICE, decrypted control data, pixels or PCM.
- [ ] Build and inspect the multi-architecture Docker image, then run the final
  stable-signed sandboxed Release DMG/Sparkle/provenance gate.

## Deployment notes

Local development uses `http://localhost:8080`. The production default is
`https://clip.tineestudio.se`. Internet deployments require HTTPS/WSS and one
server replica. Configure STUN/TURN through the server capabilities; use scoped
TURN credentials.

The server may observe room names, IP addresses, timing, route identifiers and
ciphertext sizes. It cannot decrypt access admission, SDP, ICE, stream/control
metadata or WebRTC media. The selected deployment still serves trusted viewer
JavaScript; self-hosting is the option when the default viewer operator is not
trusted.
