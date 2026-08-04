# Clip current implementation status

This page is the concise project checkpoint. Product behavior belongs in
[spec.md](spec.md), architecture in [ARCHITECTURE.md](ARCHITECTURE.md), and
test claims in [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md). The original recording
v1 execution board is preserved unchanged in
[docs/archive/PROGRESS-recording-v1.md](docs/archive/PROGRESS-recording-v1.md).

Last reviewed: 2026-08-04.

## Product status

The local recording workflow is implemented:

```text
select → record → preview → trim → rename → drag, copy, or save MP4
```

- [x] Area, application, display, and fullscreen recording
- [x] Source-aware 1×/Retina capture with native dimensions
- [x] Cursor, click highlights, microphone, and system audio
- [x] Pause/Resume and failure-safe finalization
- [x] Preview, non-destructive trim/Remove Audio, and rename
- [x] Crisp, Compact, and Smallest quality exports
- [x] Drag, Copy, Save As, History, retention, and recovery
- [x] Menu-bar application, Settings, onboarding, updates, and local DMG

Normal capture is local and requires no account, server, or Live Share session.

## Live Share v4 status

The branch replaces the old connection model with one clean-slate
server-coordinated participant mesh. There is no backwards-compatibility path.

- [x] One canonical stable fragment-secret invite for Native and Web
- [x] Authoritative bounded opaque server roster and encrypted pair signaling
- [x] One independent WebRTC pair for every unordered participant pair
- [x] Two-, three-, and four-participant topologies: 1, 3, and 6 links
- [x] Ordinary participant leave/rejoin without replacing unrelated pairs
- [x] Terminal creator departure with no election or locked-room state
- [x] Native participants can publish and receive concurrently
- [x] Receive-only desktop Safari/Chromium participant on the same mesh
- [x] Exact Native-Web codec with no fallback/transcode/second codec per edge
- [x] Per-participant system audio, mute, volume, and app exclusions
- [x] Friends, private presence, approval, and stable invite reuse
- [x] Per-window Follow/Native/Fit/fullscreen and compact remote-source pane
- [x] Pointer, ping, temporary ink, source masks, and per-window controls
- [x] Directional connection, sender, receiver, QP, queue, and codec diagnostics

The room maximum remains four participants. Two Native people sharing together
is the expected common case. Four is the currently tested CPU, thermal,
upstream-bandwidth, and churn boundary rather than an inherent WebRTC limit.

Each published source has one ScreenCaptureKit session and one raw
`RTCVideoTrack`, but standard libwebrtc owns a separate encoder/RTP sender and
congestion controller for every remote peer edge. Adding viewers does not add
screen captures or disk recordings; encoding work and publisher upload still
scale with peer count.

Detailed status and evidence:

- [Native participant mesh progress](docs/native-participant-mesh-progress.md)
- [Web viewer mesh progress](docs/WEB_VIEWER_MESH_PROGRESS.md)
- [Server-coordinated mesh design](docs/server-coordinated-mesh-design.md)
- [Web viewer design](docs/web-viewer-mesh-design.md)
- [Collaboration/window controls progress](docs/collaboration-window-controls-progress.md)

## Before merging the mesh branch

- [x] Commit the final sender-diagnostics and Web diagnostics cleanup
- [x] Finish README, architecture, specification, status, and release-doc audit
- [x] Embed and verify the app-icon favicon in the room service
- [x] Synchronize the branch with the current `origin/main`
- [x] Run `./scripts/test.sh`
- [x] Run `./scripts/run-live-share-acceptance.sh`
- [x] Run `./scripts/audit-project.sh`
- [x] Run `./scripts/verify-web-viewer-native-boundary.sh`
- [x] Run `git diff --check`
- [x] Build the stable-signed repository app
- [x] Smoke-test two Native participants, the primary use case
- [x] Smoke-test Native + Web leave/reconnect
- [ ] Record the exact tested commit and final results in the pull request

When these checks pass, the clean-slate mesh is suitable to replace the old
networking on `main`.

The completed smoke rows reflect the stable-signed two-Native and mixed
Native/Web manual sessions exercised throughout the final branch review. The
repeatable exact-head evidence remains the deterministic app and composed Live
Share gates above; the pull request records their tested commit.

## Remaining public-release gates

These are evidence gates rather than missing product entry points:

- [ ] Controlled current desktop Safari and Chromium visual/input/audio/
  reconnect/unsupported-codec pass
- [ ] Four independent stable-signed Clip GUI processes with all six links
- [ ] Real Fullscreen, system audio, and app-audio exclusion matrix
- [ ] Direct Internet ICE and TURN relay coverage
- [ ] Physical Retina/external-display, Spaces, and display-movement coverage
- [ ] Repeated participant/source churn plus CPU, thermal, upstream, and audio
  observation
- [ ] Ten-minute Live Share soak and clean termination

Until those controlled gates are recorded against the release candidate, Live
Share should be described as preview/beta rather than fully proven for every
supported environment.
