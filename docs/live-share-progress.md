# Clip Live Share progress board

Branch: `codex/live-screen-share`

Last updated: 2026-07-19

Architecture contract: [live-share-architecture.md](live-share-architecture.md)

Acceptance commands: [ACCEPTANCE.md](ACCEPTANCE.md)

This board tracks the GoPeep-compatible Live Share milestone independently from
the published recording product. Status is based on evidence in this branch,
not on the presence of source files alone.

The branch has not been published and development has not replaced
`/Applications/Clip.app`.

At the current 1.2.0 (build 4) integration checkpoint, the feature-specific
package, browser-interoperability, and hosted policy suites are green. The
complete clean-tree release gate is rerun at the final checkpoint; it does not
close the controlled/external gates listed below.

## Status model

- `DONE` — implemented and covered by the deterministic evidence named here.
- `IN_PROGRESS` — useful implementation exists, but named code or automated
  acceptance work remains.
- `EXTERNAL_GATE` — the code path is implemented, but completion requires a
  real display, network path, signing identity, or owner-authorized permission.
- `PENDING` — not yet at its acceptance gate.
- `DEFERRED` — intentionally outside the GoPeep v1 milestone.

## Milestone board

| ID | Lane | Status | Evidence-based outcome |
| --- | --- | --- | --- |
| LS-00 | Contract and GoPeep audit | `DONE` | v1 wire behavior, native UI contract, trust boundary, and v2 direction are documented. |
| LS-01 | Native WebRTC dependency | `IN_PROGRESS` | WebRTC 150.0.0 is pinned and isolated; native H.264 works with the unmodified browser viewer. Final signed-Release packaging evidence remains. |
| LS-02 | Domain and source state | `DONE` | Session transitions, four stable slots, fullscreen exclusivity, viewer counts, reconnect state, and stale-operation gates have unit evidence. |
| LS-03 | Repository boundaries | `DONE` | Live Share, shared transient capture, and the WebRTC adapter are separate targets/folders. Recording was deliberately not mechanically reorganized in this feature. |
| LS-04 | GoPeep v1 signaling | `DONE` | Exact reserve/join/offer/answer/ICE/password-update routing works against the unmodified local Go service; reconnect and queue bounds have unit evidence. |
| LS-05 | WebRTC peer host | `IN_PROGRESS` | Native H.264, four preallocated tracks, reliable control channel, viewer/SDP/ICE/DataChannel bounds, low-water durable-state recovery, timeout, and loopback/browser evidence exist. TURN and a browser exercise of all four active tracks remain. |
| LS-06 | Capture and streaming | `EXTERNAL_GATE` | Exact-size transient pixel buffers feed WebRTC without an MP4 path; resize and latest-frame pressure are bounded, and sustained overload is visible without stopping capture. Real desktop quality and overlay exclusion remain controlled-Mac gates. |
| LS-07 | Live Share popover | `DONE` | The complete popover switches modes and deterministic scenarios cover Ready, Live, bottom content, Reconnecting, and Failed. |
| LS-08 | Focused-window overlay | `EXTERNAL_GATE` | Share/Stop, side animation, geometry, ordinary hit testing, and teardown are implemented. Real-window click consumption, secondary-display behavior, and capture exclusion still need controlled-Mac evidence. |
| LS-09 | Fixed status HUD | `EXTERNAL_GATE` | Four dots, connected-viewer count, Fullscreen, Stop All, placement, and teardown are implemented. Real Spaces/display/capture-exclusion behavior remains. |
| LS-10 | Source transitions | `EXTERNAL_GATE` | Window operations are serialized/coalesced, stale completions are gated, and ON→OFF Fullscreen rollback restores the prior windows without reviving media after Stop All. Real focus churn remains a controlled-Mac gate. |
| LS-11 | Reliability and privacy | `EXTERNAL_GATE` | Bounded reconnect, viewer/ICE/SDP/signaling/DataChannel limits, native low-water authoritative-state replay, teardown, secret redaction, and session-only access codes are implemented. Sleep/wake, permission loss, display removal, and soak evidence remain. |
| LS-12 | Automated acceptance | `IN_PROGRESS` | Native loopback, real local GoPeep signaling, unmodified WebKit viewer, deterministic UI, and package/app tests exist. Real ScreenCaptureKit Live Share and controlled TURN lanes remain. |
| LS-13 | Packaging and release | `IN_PROGRESS` | Strict source/build/test gates and packaging hardening are green; the final stable-signed sandboxed Release DMG/update candidate remains. |
| LS-20 | Opaque-relay v2 | `DEFERRED` | Future protocol/server/viewer work; it is not silently mixed into GoPeep v1. |

## Evidence already established

### Native packages and app composition

- `Packages/ClipCapture` owns ScreenCaptureKit discovery, exact geometry,
  transient frame delivery, in-place resize handoff, and observable latest-frame
  backpressure. Its tests reject silent scaling and accept only the exact old or
  new size during a committed resize.
- `Packages/ClipLiveShare` owns GoPeep-compatible domain values, settings,
  source selection, the session state machine, and stable `video0` through
  `video3` allocation. Its tests cover empty/ready/sharing/stopping/reconnecting
  states, fullscreen/window exclusivity, idempotent removal, viewer counts, and
  exact JSON fixtures.
- `Packages/ClipLiveShareWebRTC` is the only target that imports the pinned
  WebRTC framework. It owns the native H.264 peer host, four transceivers,
  ordered reliable `gopeep-control` channel, signaling transport, statistics,
  ICE validation, resource limits, and the zero-copy pixel-buffer bridge.
  Durable control sends never create an application payload queue: a native
  DataChannel low-water callback regenerates the latest authoritative snapshot
  after backpressure, while cursor samples remain intentionally lossy.
- `Clip/LiveShare` contains the application coordinator, presentation,
  persisted Live Share settings, focus/cursor observation, and AppKit overlays.
  Recording, Preview, History, and export do not own or persist Live Share
  frames.

### Automated transport and browser evidence

Run:

```sh
./scripts/run-gopeep-interop-acceptance.sh
```

The lane uses the unmodified sibling GoPeep Go server on loopback. It verifies
real HTTP room reservation, sharer-secret authentication, access-code join
gating and replacement, targeted offer/answer routing, and bidirectional ICE.
It then opens the server's unmodified viewer in an offscreen `WKWebView`,
negotiates with Clip's native peer host, requires advancing H.264 frames, and
checks that `streams-info`, focus, and cursor metadata reached the browser. It
does not move the pointer or touch the installed app.

The lower-level native loopback test independently negotiates the native host,
sends a deterministic `CVPixelBuffer`, and receives control data. Peer-host
tests cover the eight-viewer default limit, 15-second answer timeout, bounded
and validated ICE/SDP/control payloads, native DataChannel high/low-water
behavior, stale SDP generations, close idempotence, and stable track identity.
Signaling tests cover bounded payload/event delivery, reconnect exhaustion,
stop during suspended connection work, and credential-safe logging.

### Deterministic UI evidence

The app's injected UI scenarios render production Live Share presentation
without reserving a room or requesting capture permission:

- Ready, Live, Reconnecting, and Failed popovers;
- a Live snapshot scrolled to its lower controls and statistics;
- the focused-window Share/Stop overlay and fixed status HUD.

Presentation and policy tests cover exact copy values, unavailable-command
guards, the optional 60 FPS capability gate, connected-viewer counting,
secondary-display coordinate conversion, overlay clamping, source capacity,
and redacted user-facing failures. The targeted Live Share UI scenario run
passed during branch implementation; the final release gate must rerun it if
the UI changes again.

## Remaining controlled/external gates

These are deliberately not inferred from synthetic or loopback tests:

- [ ] Share a real desktop window through the production coordinator and
  ScreenCaptureKit permission path, then decode it in the GoPeep browser viewer.
- [ ] Exercise one through four real active window sources, dynamic add/remove,
  a resize, Fullscreen exclusivity, and rapid focus/auto-share churn.
- [ ] Prove the focused-window control and HUD are excluded from real shared
  pixels, consume clicks, and place correctly on a secondary display and across
  Spaces.
- [ ] Exercise remote Internet connectivity and a configured TURN relay; the
  local loopback result proves neither.
- [ ] Exercise sleep/wake, display removal, window closure, capture permission
  revocation, and visible sustained encoder/network overload.
- [ ] Run repeated start/stop and a ten-minute real-share soak while checking
  capture sessions, peers, sockets, tasks, overlays, and memory return to idle.
- [ ] Build and verify the final stable-signed sandboxed Release DMG, embedded
  framework signatures/rpaths, appcast/update metadata, checksum, and size.

Live Share has no audio in this milestone. Thirty FPS is the supported default;
15 FPS is selectable, while 60 FPS remains optional and capability-gated rather
than a release blocker.

## GoPeep v1 privacy boundary

- WebRTC encrypts media and DataChannel traffic between peers.
- The current GoPeep service can read the room secret, optional access code,
  SDP, ICE candidates, peer IDs, and signaling metadata, and it serves the
  viewer JavaScript. V1 is not zero-knowledge.
- Changing the access code applies to new viewer join attempts. A viewer that
  already joined is not reauthenticated by the v1 server and may finish its
  pending negotiation later.
- Clip generates a cryptographically random session-only access code, redacts
  sensitive signaling from ordinary logs, and persists neither that code nor
  live frames.

The opaque-relay v2 threat model and downgrade rules are documented in
[live-share-architecture.md](live-share-architecture.md). They require a new
server/viewer protocol and are not acceptance criteria for this compatibility
branch.
