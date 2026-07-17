# Clip implementation board

This file tracks implementation against [spec.md](spec.md). The specification is the product source of truth; this board records execution state and verification evidence.

Last updated: 2026-07-17

## Status model

- `PENDING` — ready or waiting on dependencies; no active implementation.
- `IN_PROGRESS` — actively owned and being implemented.
- `BLOCKED` — cannot progress; record the concrete blocker under the card.
- `DONE` — every checklist item is complete and verification evidence is recorded.

Board rules:

1. Keep card IDs stable so commits and agent handoffs can reference them.
2. Assign one primary owner before moving a card to `IN_PROGRESS`.
3. Prefer no more than one `IN_PROGRESS` card per lane.
4. Mark checklist items as they are completed, but update the card status separately.
5. Do not mark a card `DONE` based only on compilation. Record the relevant test, inspection, or artifact under its Evidence heading.
6. If behavior changes, update `spec.md` first and then adjust this board.

## Release-critical path

The minimum validated product path is:

```text
Launch from DMG
→ select an area
→ record
→ preview
→ trim
→ rename
→ drag or copy the MP4
```

All cards are planned for v1. The critical path above receives priority when work must be sequenced.

Feature implementation is complete in source for the agreed personal-use v1.
Unchecked items below are release-acceptance or physical-hardware evidence, not
known missing product features. The owner reported the installed build's core
workflow working manually; final Fullscreen, optional-audio, multi-display, and
long-soak checks remain explicitly unverified rather than assumed.

## Verification snapshot

Permission-free evidence completed on 2026-07-17:

- The final merged source passes ClipCore 80/80 and ClipMedia 76/76. The most recent complete hosted Xcode ClipTests lane passed 142/142 with 0 failures and 0 skips (`.build/Test-Clip-v1-final-permission-free-current.xcresult`); the final cadence/report additions subsequently passed strict Swift 6 Release compilation and link. The Xcode gate also compiles the guarded Fullscreen/real-audio UI-test sources and test helper without executing UI automation.
- The Xcode action log recorded `Production application startup suppressed for hosted unit tests` twice. Hosted ClipTests stop before the production coordinator is created, so the unit-test host cannot create a status item, show onboarding, register system integrations, read production state, move the pointer, or request Screen Recording, System Audio, Microphone, Accessibility, or Automation access.
- The final strict source gate passed complete Swift 6 concurrency checking, an arm64 executable link, app-test compilation, and the opt-in Capture Area, Fullscreen, and real-audio UI source configurations without executing UI automation. Xcode emitted only its informational App Intents metadata-skip message because Clip has no AppIntents dependency.
- Native media tests encoded and exported an actual 5120 x 2880, 60 FPS H.264 asset; preserved decoded frame order with PSNR at least 24 dB per frame and 28 dB on average; and kept pause-adjusted video and two-source/mixed audio aligned within 50 ms.
- The Release benchmark in `.build/performance/latest.json` passed both reference targets. Preview media readiness measured 130.832292, 116.388208, and 126.097208 ms (maximum 130.83 ms, target below 1,000 ms); Compact export of the exact 30-second 1440 x 900 at 30 FPS fixture measured 4.10125, 2.670583, 2.245916, 2.075292, and 1.969584 ms (maximum 4.10 ms, target below 2,000 ms).
- Synthetic reliability coverage completed 10,000 Pause/Resume cycles across a multi-hour state-machine timeline and produced a playable H.264 writer output spanning two hours using sparse timestamps.
- `./scripts/run-deterministic-acceptance.sh` passed without requesting privacy access: it produced and decoded a 640 x 360, two-second, 30 FPS H.264 (`avc1`) MP4, rendered the 960 x 540 fixture PNG, verified a byte-identical renamed file and private-pasteboard file URL, validated an Apple `avconvert` one-second trim/remux, and rejected an invalid `.mp4` payload.
- The current `.build/Clip.dmg` is 2,252,815 bytes with SHA-256 `5e7c45d5f3fe283efd76571056abea3443dd328c9a9bf5c846bed0866c54ec84`. Read-only mounting and verification proved its arm64 `Clip.app`, Applications shortcut, resources, metadata, privacy descriptions, Hardened Runtime, sandbox entitlements, leaf certificate `BA37BFFD2BD1C29A995682647428847DBC6A83B3`, Team ID `FJ2BS65H3F`, and certificate-based designated requirement without a build-specific `cdhash`. The packaged executable SHA-256 is `f63ab3932c55cab422af5fc61b67c2ffebfc903122e228783fffed979bae66e9`, exactly matching `/Applications/Clip.app`.

Permission-gated evidence and remaining checks:

- `scripts/run-real-capture-acceptance.sh --allow-permission-prompts-and-pointer-control` selects and executes exactly one real UI test rather than silently skipping it. Its explicit opt-in and startup warning state that XCTest drives the visible macOS pointer. The latest pointer-driven run remains the superseded ad-hoc Debug failure (0 passed, 1 failed, 0 skipped) and was stopped by owner choice. The stable-signed installed app instead completed the no-pointer production ScreenCaptureKit acceptance described below.
- The enhanced Capture Area lane and the focused Fullscreen lane are compiled but have not run. Capture Area validates the managed master and both drag/Copy exports against the fixture's exact backing-pixel dimensions and visual fingerprint. Fullscreen validates display-sized H.264, decoded fixture pixels/colors, Preview presentation, and AVPlayer playback, and attaches a capture description plus Preview screenshot to its xcresult.
- Controlled stable-identity ScreenCaptureKit acceptance passed at both 30 and optional 60 FPS with H.264 High/AAC, Rec.709, Pause/Resume, decoded fine-detail motion, Preview generation, a byte-identical private-pasteboard Copy, copy re-decode/evaluation, bounded cadence, A/V endpoint checks, and complete artifact cleanup. The exact packaged `/Applications/Clip.app` passed the final 30 FPS lane with a 40 ms maximum video gap; the same final source passed the optional 60 FPS lane with a 23.33 ms maximum gap. These no-pointer checks prove the native engine and primary 30 FPS product path but do not replace the stopped pointer-driven Fullscreen workflow or real microphone tests.
- The current stable-signed DMG and installed app are the same executable and designated requirement. The owner also reported the ordinary installed workflow working manually.
- Real microphone/system-audio modes, physical display/device cases, idle/menu-bar stability, and the ten-minute real recording soak remain unverified.

## Feature board

| ID | Lane | Status | Owner | Card | Depends on |
| --- | --- | --- | --- | --- | --- |
| FND-01 | Platform | `DONE` | Codex | Project foundation | — |
| APP-01 | Platform | `IN_PROGRESS` | Codex | App shell and menu bar | FND-01 |
| PER-01 | Platform | `BLOCKED` | Codex | Permissions and onboarding | FND-01, APP-01 |
| SET-01 | Platform | `IN_PROGRESS` | Codex | Settings, shortcuts, and login behavior | FND-01, APP-01 |
| CAP-01 | Capture | `IN_PROGRESS` | Codex | Displays and capture selection | FND-01, APP-01 |
| REC-01 | Capture | `IN_PROGRESS` | Codex | Recording engine and controls | FND-01, CAP-01 |
| AUD-01 | Capture | `IN_PROGRESS` | Codex | Microphone and system audio | REC-01, PER-01 |
| EDT-01 | Post-capture | `IN_PROGRESS` | Codex | Preview and trimming | FND-01, REC-01 |
| EXP-01 | Post-capture | `IN_PROGRESS` | Codex | Export, drag, copy, and save | EDT-01 |
| HIS-01 | Post-capture | `IN_PROGRESS` | Codex | History and managed storage | FND-01, EDT-01, EXP-01 |
| ERR-01 | Quality | `IN_PROGRESS` | Codex | Recovery, errors, and performance | REC-01, AUD-01, EXP-01, HIS-01 |
| TST-01 | Quality | `IN_PROGRESS` | Codex | Deterministic automated test harness | FND-01 |
| TST-02 | Quality | `BLOCKED` | Codex | Real-Mac acceptance suite | CAP-01, REC-01, AUD-01, EXP-01, HIS-01, TST-01 |
| REL-01 | Release | `IN_PROGRESS` | Codex | Local DMG and final handoff | APP-01, PER-01, SET-01, ERR-01, TST-02 |

## Card checklists

### FND-01 — Project foundation

- Status: `DONE`
- Lane: Platform
- Owner: Codex

- [x] Create a checked-in Xcode project with the Clip app, unit-test, UI-test, and test-helper targets.
- [x] Configure Xcode 26.6, Swift 6 language mode with Swift 6.3.3, macOS 15.0+, and `arm64`.
- [x] Set version `1.0.0`, bundle ID `com.tomaslejdung.clip`, executable/app name `Clip`, and Tomas Lejdung copyright metadata.
- [x] Configure App Sandbox, Hardened Runtime, microphone, user-selected file access, and required privacy usage descriptions.
- [x] Establish the AppKit application coordinator plus SwiftUI view composition.
- [x] Define injectable service boundaries for capture, audio, permissions, clocks, files, pasteboard, shortcuts, displays, and export.
- [x] Create Application Support and Caches directory abstractions with atomic file operations.
- [x] Add structured local logging that does not capture video/audio content.
- [x] Add command-line Debug and Release build scripts with deterministic derived-data locations.
- [x] Verify a clean command-line build with zero compiler errors.

Evidence:

- Project audit passed for every target source, package reference, plist, entitlement, asset, and localization resource.
- The strict Swift 6 gate compiled all app sources, linked a warning-free arm64 executable, compiled app/UI test sources and the helper, and the manual bundle/DMG structural verification passed.

### APP-01 — App shell and menu bar

- Status: `IN_PROGRESS`
- Lane: Platform
- Owner: Codex

- [x] Launch as a menu-bar app with no regular window or Dock icon by default.
- [x] Add a restrained native Clip app icon and monochrome menu-bar template image.
- [x] Implement the default popover and dynamic display rows.
- [x] Implement prepared capture-target state and the remembered-target Record action.
- [x] Implement the recording popover with elapsed time, Pause/Resume, Finish, and Cancel.
- [x] Reflect recording and paused states in the menu-bar icon.
- [x] Hide unavailable actions and secondary displays.
- [x] Give every interactive menu-bar popover row visible hover feedback and a pointing-hand cursor.
- [x] Follow system light/dark appearance and keep all v1 strings in an English String Catalog.
- [x] Support opening Preview, History, Settings, and Quit from the app shell.
- [x] Keep an existing floating Preview visible while another capture starts, and replace it only after the new recording is safely imported.
- [x] Make Quit synchronously remove all owned UI/status items, then reply exactly once after bounded best-effort cleanup or an eight-second fallback.
- [ ] Verify idle relaunch and repeated popover opening without duplicate windows or status items.

Evidence:

- App/menu model implementation, row hover state, and cursor behavior pass the strict source gate; the project audit validates the extracted English String Catalog and both icon sets.
- Focused hosted regression passes 12/12 in `.build/Test-TerminationRegression-2.xcresult` (five termination/Preview lifecycle tests plus seven global-shortcut tests): immediate idempotent UI closure, exactly-once termination reply, non-cooperative cleanup timeout, service-authoritative first-frame finalization, capture selection with a visible Preview, and the durable boundary between successful import and deferred Preview presentation. The app host suppressed production startup; no UI automation or privacy access ran.
- Runtime relaunch/status-item verification remains part of the installed-DMG acceptance pass.

### PER-01 — Permissions and onboarding

- Status: `BLOCKED`
- Lane: Platform
- Owner: Codex

- [x] Build the first-launch onboarding flow and persist completion state.
- [x] Explain area recording and drag/copy sharing before requesting access.
- [x] Detect and request Screen Recording permission.
- [x] Request Microphone and System Audio permissions only when first enabled.
- [x] Show current permission state and deep links to the relevant System Settings pages.
- [x] Provide Continue Without Audio where an optional audio permission is unavailable.
- [x] Handle denial, later revocation, and permission changes that require relaunch.
- [x] Request no Accessibility permission.
- [x] Document stable Personal Team signing and that ad-hoc CI rebuilds may require permission approval again.
- [x] Approve Screen & System Audio Recording once for the stable installed build and relaunch it.
- [ ] Approve optional Microphone/System Audio access when their real modes are exercised.

Evidence:

- Onboarding persistence, permission-state presentation, on-demand optional-audio requests, settings deep links, and per-session audio fallback are implemented and pass the strict source gate.
- The prior real test reached the synthetic fixture but received no first frame with its superseded ad-hoc Debug identity (0 passed, 1 failed, 0 skipped). The owner has since granted Screen & System Audio Recording to the stable certificate-based installed app, relaunched it, and manually confirmed recording on that earlier build. Optional audio permissions and an automated rerun against the next release candidate remain later checks; no Accessibility permission is requested.

### SET-01 — Settings, shortcuts, and login behavior

- Status: `IN_PROGRESS`
- Lane: Platform
- Owner: Codex

- [x] Build General, Recording, Export, Storage, and Permissions settings sections.
- [x] Implement every initial default in `spec.md`, including Capture Area, 30 FPS, cursor On, audio Off, three-second countdown, seven-day retention, and Compact export.
- [x] Implement configurable global Capture, Finish, and Pause/Resume shortcuts without requiring Accessibility access.
- [x] Detect invalid or conflicting shortcut assignments and allow restoring defaults.
- [x] Keep Capture Mode's Return, Escape, Tab, and arrow controls fixed.
- [x] Implement silent countdown choices Off, 1, 3, and 5 seconds.
- [x] Implement Show in Dock behavior.
- [x] Implement launch at login with `SMAppService`.
- [x] Show the current system-default microphone and history directory as read-only values.
- [x] Implement default Save As location and security-scoped persistence where required.
- [x] Implement a validated filename format with `YYYY`, `MM`, `DD`, `HH`, `mm`, and `ss` tokens, a live example, and schema migration for existing settings.
- [x] Persist preferences safely and support future preference migrations.
- [x] Select General explicitly and present the correctly sized key Settings window so labels and controls render on first open without a focus cycle.

Evidence:

- The 80 passing ClipCore tests cover defaults, Capture App persistence, filename formatting and schema migration, validation, shortcut conflicts, history, migrations, Remove audio persistence and legacy decoding, and the multi-hour 10,000-cycle Pause/Resume state soak. Executed app tests cover filename-template persistence/use, Carbon registration, and security-scoped bookmark restoration.
- Settings presentation has a deterministic initial-tab/content-size seam, stable control identifiers, inert external actions for scenario launches, and compile-only assertions that require the initial General controls and labels to exist before any focus interaction.
- Runtime checks for login-item registration, Dock switching, and sandbox bookmark restoration remain in the installed-app pass.

### CAP-01 — Displays and capture selection

- Status: `IN_PROGRESS`
- Lane: Capture
- Owner: Codex

- [x] Enumerate ScreenCaptureKit displays and map them to AppKit screens reliably.
- [x] Present transparent selection overlays across all available displays.
- [x] Implement dimming, crosshair selection, output-pixel dimensions, and an undimmed selected region.
- [x] Grow a newly drawn region smoothly from the exact mouse-down point without a synthetic 96 x 96 draft or pointer warp.
- [x] Constrain every capture rectangle to one display.
- [x] Implement movable and resizable selection geometry with visible handles.
- [x] Implement Tab focus and one-pixel/ten-pixel keyboard movement and resizing.
- [x] Preserve aspect ratio for Shift-modified pointer resizing.
- [x] Position the compact toolbar outside the selected region whenever possible.
- [x] Give the selection toolbar's Cancel and Record buttons pointing-hand cursors that override the overlay crosshair.
- [x] Implement Capture Area, Capture App, Last Area, Fullscreen, and per-display prepared targets.
- [x] Make Capture App select every visible window of the clicked application on that display, with hover highlighting and a durable app/display target for History and Retake.
- [x] Persist Last Area by display identity and normalized coordinates.
- [x] Move and clamp Last Area to the main display when its original display is absent.
- [x] Include normal system UI in fullscreen while excluding Clip windows and overlays.
- [x] Hide the selection UI before the first recorded frame.
- [x] Keep a click-through, capture-excluded area border visible during recording without retaining the dimming overlay.
- [ ] Measure Capture Mode presentation latency and target p95 below 300 ms.

Evidence:

- Passing ClipCore geometry tests cover display clamping, normalized Last Area restoration, application targets, and missing-display fallback. The executed app suite covers smooth draft/finalization geometry, pointer/keyboard behavior, toolbar placement, physical pixel scaling, Capture App hit-testing/unions, persistence, and display identity.
- Physical multi-display overlay behavior, ScreenCaptureKit/AppKit mapping, UI exclusion, and p95 latency remain real-Mac checks.

### REC-01 — Recording engine and controls

- Status: `IN_PROGRESS`
- Lane: Capture
- Owner: Codex

- [x] Implement an explicit recording state machine for idle, selecting, countdown, recording, paused, finishing, canceled, failed, and preview states.
- [x] Configure ScreenCaptureKit for region/fullscreen capture, cursor visibility, SDR Rec.709, and 30/60 FPS.
- [x] Pixel-align Area/App source rectangles and use the same exact even dimensions through ScreenCaptureKit, encoding, History, and MP4 metadata.
- [x] Reject every incoming video pixel buffer whose dimensions differ instead of silently rescaling it.
- [x] Encode transient ScreenCaptureKit pixel buffers directly with a quality-0.98 VideoToolbox H.264 High-profile session.
- [x] Pass compressed H.264 samples into AVAssetWriter as passthrough video while AVAssetWriter muxes MP4/AAC only.
- [x] Bound video encoder/muxer backpressure and surface sustained overload or frame drops as capture failures.
- [x] Start timing on the first valid frame and reject recordings containing no frames.
- [x] Implement Pause/Resume with paused time removed from all output timestamps.
- [x] Implement Finish and produce a playable managed recording.
- [x] Implement Cancel with immediate discard at three seconds or less and confirmation afterward.
- [x] Keep the elapsed timer and menu-bar controls synchronized with state.
- [x] Monitor disk space and stop safely before a corrupt or unfinishable output is produced.
- [x] Preserve playable material on display loss or stream failure where possible.
- [x] Recover interrupted managed recordings on relaunch where technically possible.
- [x] Support at least 30-minute recordings without a product hard stop.

Evidence:

- Passing ClipCore and ClipMedia tests cover state transitions, first-frame timing, cancel thresholds, half-open pause intervals, monotonic retiming, stale callback rejection, direct VideoToolbox H.264 writing, passthrough MP4 muxing, exact input dimensions, bounded cadence gaps, and no-frame rejection.
- Disk start/stop thresholds and UUID-gated failure, early-stream finalization/import of playable output, and sidecar-based adoption of playable interrupted MP4s are implemented and tested. The state machine explicitly accepts active durations beyond 30 minutes; a physical display disconnect and real long-recording soak remain pending.

### AUD-01 — Microphone and system audio

- Status: `IN_PROGRESS`
- Lane: Capture
- Owner: Codex

- [x] Support Off, microphone only, system audio only, and microphone plus system audio.
- [x] Capture system audio through ScreenCaptureKit and exclude Clip's own audio.
- [x] Capture only the current system-default microphone in v1.
- [x] Normalize and mix microphone/system sources into one compatible AAC track.
- [x] Keep audio and video synchronized at recording start and after Pause/Resume.
- [x] Continue video with the remaining sources if an audio device disappears.
- [x] Surface permission and device errors without discarding usable video.
- [x] Remember the last selected audio configuration.
- [ ] Validate all four audio configurations using deterministic inputs where possible and real hardware on a best-effort basis.

Evidence:

- The 76 passing ClipMedia tests include deterministic microphone-only, system-only and two-source mixing, silent export, 50 ms pause-timeline synchronization, source-scoped failure handling, direct VideoToolbox quality/cadence policy, queued audio pre-roll and nonmonotonic timestamp rejection, and the playable two-hour sparse-timestamp writer. An audio append failure disables only that writer input while preserving video, the other source, and earlier samples; Clip presents the loss inline while recording continues.
- Capture configuration supports all four modes and per-session fallback when permission is revoked or the default microphone is unavailable at start. Physical device removal and real microphone/system-audio capture for all four modes remain unverified.

### EDT-01 — Preview and trimming

- Status: `IN_PROGRESS`
- Lane: Post-capture
- Owner: Codex

- [x] Open one compact floating Preview window after Finish.
- [x] Implement the exact layout: draggable video preview, trim timeline below it, then action buttons.
- [x] Add AVPlayer playback, play/pause, seeking, current time, and total duration.
- [x] Implement beginning/end trim handles and a scrubber without waveform or thumbnails.
- [x] Persist non-destructive trim metadata and support Restore Original Trim.
- [x] Add editable filename validation with default `clip-YYYYMMDD-HHmmss.mp4` and protected `.mp4` extension.
- [x] Show `Quality based — size varies` before Compact/Crisp work, actual size after sharing, and target-based estimates for Smallest.
- [x] Show Remove audio only for recordings with audio, default it to keeping audio, mute Preview when selected, and allow immediate restoration.
- [x] Exclude audio from the visible estimate when Remove audio is selected and calibrate ordinary estimates against the managed source's observed byte rate.
- [x] Implement Delete with confirmation and Retake using the previous target/audio/countdown settings.
- [x] Keep the old draft until Retake succeeds.
- [x] Keep the recording in History when Preview closes.
- [x] Reopen the same trim, name, and preset state from History.

Evidence:

- The exact view hierarchy and AVPlayer/timeline implementation pass strict compilation; focused app test sources cover trim clamping/reset, playback state, filename validation, durable close, confirmed Delete, two-phase Retake rollback, History reopen state, Remove audio playback muting/restoration, estimate changes, and Done/share persistence.
- Preview carries the durable 30/60 capture cadence into every export request, resets prior actual-size feedback whenever output-affecting controls change, and presents actual size only after a successful quality-based share. Visual and interaction acceptance remains pending.

### EXP-01 — Export, drag, copy, and save

- Status: `IN_PROGRESS`
- Lane: Post-capture
- Owner: Codex

- [x] Build a native AVFoundation/VideoToolbox export pipeline with no FFmpeg dependency.
- [x] Apply the selected trim accurately to within one frame.
- [x] Implement Compact as offline H.264 quality 0.85 with a soft bitrate target, no hard rate limit, and the 1920 × 1080/30 FPS envelope.
- [x] Implement Crisp as byte-identical compatible master reuse or offline H.264 quality 0.98 with a soft bitrate target and no hard rate limit.
- [x] Preserve the durable 30/60 capture ceiling and exact sample timing, including the 28.29 FPS under-30 regression.
- [x] Implement Smallest with approximate 10 MB, 25 MB, and 1–500 MB Custom targets.
- [x] Keep Smallest constrained with offline ABR and a one-second hard limit with ten percent headroom.
- [x] Keep strict guaranteed maximum-size/two-pass encoding out of v1.
- [x] Cache and invalidate exports when trim, preset, or filename changes.
- [x] Cache and invalidate independently for kept-audio and silent exports.
- [x] Make dragging the top video preview supply the current exported MP4 file.
- [x] Implement the explicit Copy button using a readable MP4 file URL on `NSPasteboard`.
- [x] Make Drag, Copy, and Save As honor Remove audio and emit no audio track when selected without changing the managed master.
- [x] Implement Save As with default location `~/Movies`, editable filename, and an `NSSavePanel` Powerbox grant for the exact chosen destination.
- [x] Stage Save As publication inside Clip's managed container so saving to Downloads or another protected folder does not require unauthorized sibling-file access.
- [x] Implement Reveal in Finder.
- [x] Keep drag/clipboard temporary files alive long enough for receiving apps, then clean them safely.
- [x] Remove all automatic-copy behavior and settings.
- [x] Report export, pasteboard, save, and drag preparation failures with actionable recovery.

Evidence:

- ClipMedia's deterministic export tests decode native H.264 and verify exact quality policies, trim duration within one output frame, arbitrary Crisp dimensions, durable requested FPS, Rec.709, microphone/system/two-source AAC, silent export with an unchanged audible master, constrained Smallest targets, atomic publication, and source/destination preservation on failure. A compatible full-duration Crisp export is byte-identical to its master, while irregular and 28.29 FPS timing regressions prove Crisp preserves every eligible source sample/timestamp and lower-FPS output still decimates.
- Executed Preview/Save tests cover exact trim/preset/name export requests, lazy promised-file drag, explicit Copy with the exact exported size in its confirmation, Save cancellation, exact-URL creation/replacement, balanced security scope, Reveal, post-share warnings, and temporary-file/history ownership. Actual promised-file drag and sandboxed Save-panel interaction remain part of the current-build real-Mac pass.

### HIS-01 — History and managed storage

- Status: `IN_PROGRESS`
- Lane: Post-capture
- Owner: Codex

- [x] Define versioned JSON history metadata and atomic index writes.
- [x] Create a history item when a recording successfully stops.
- [x] Store the managed master plus trim, preset, filename, duration, size, target, and creation metadata.
- [x] Persist the per-recording Remove audio preference through Done, sharing, History reopen, and app relaunch, with legacy metadata defaulting to keep audio.
- [x] Show recent recordings in the menu-bar popover and a fuller History view.
- [x] Support Preview, Rename, Copy, Save, Reveal in Finder, and Delete actions.
- [x] Persist renames and use them for drag, Copy, and Save As.
- [x] Implement 1-day, 7-day, 30-day, indefinite, and do-not-retain-after-export policies.
- [x] Base cleanup on recording creation time and run it at launch plus periodically.
- [x] Implement Keep Original On/Off semantics without deleting external Save As files.
- [x] Show storage usage, reveal the fixed Application Support location, and clear managed history with confirmation.
- [x] Reconcile missing/orphaned files and recover valid interrupted items on launch.

Evidence:

- All 80 ClipCore tests pass, including Codable round trips and legacy migration for the per-recording audio export preference. Repository tests cover import/rename/delete, Preview pins, Remove audio persistence across repository reconstruction, deferred replacement, atomic external saves, cleanup, reconciliation, and interrupted-item adoption.
- The app-owned repository tests now execute under normal `xcodebuild test`; installed-app History persistence remains a real-Mac check.

### ERR-01 — Recovery, errors, and performance

- Status: `IN_PROGRESS`
- Lane: Quality
- Owner: Codex

- [x] Model user-facing recovery for permission denial, invalid area, display loss, disk pressure, encoding failure, zero frames, and unavailable audio/video sources.
- [x] Separate concise user messages from local technical details and logs.
- [x] Explain that protected/DRM content and destination paste/drop behavior may be outside Clip's control.
- [ ] Measure idle resource use and repeated long-running menu-bar stability.
- [x] Measure Preview readiness below one second for the reference fixture.
- [x] Measure Compact export below two seconds for the 30-second 1440 × 900 at 30 FPS fixture on this Mac.
- [x] Verify trim error at or below one frame.
- [x] Verify A/V sync within 50 ms, including Pause/Resume.
- [x] Complete longer synthetic writer/state soak tests.
- [ ] Complete a ten-minute real recording soak.
- [x] Confirm failures leave no unbounded temporary storage or unusable history entry.

Evidence:

- Error states and recovery routes are implemented. Unknown framework/filesystem details are logged privately while primary UI surfaces receive a concise recovery message; deliberately authored `LocalizedError` messages remain actionable.
- Native export tests verify trim duration within one requested output frame, source/destination preservation on failure, and mixed audio/video start and end alignment within 50 ms after Pause/Resume. Synthetic soak coverage exercises 10,000 Pause/Resume cycles across more than two hours and a playable writer with a two-hour sparse timestamp span.
- Release benchmarking passed Preview media readiness at 130.83 ms maximum and Compact export at 4.10 ms maximum. The Preview boundary begins after the final sample and includes writer finalization plus media metadata loading, but not ScreenCaptureKit shutdown or AppKit window drawing. The Compact result exercises the real exporter, validation, and atomic publication on an eligible untrimmed fixture; separate tests reject source reuse when trim, resize, FPS reduction, or two-track audio mixing is required.
- Temporary storage is bounded by strict ownership-aware cleanup: stale transaction artifacts and UUID-shaped export caches expire after seven days, while unknown files and the only recoverable rollback are retained. Atomic publication, failure rollback, retention, reconciliation, and invalid-output tests prevent unusable history entries or destructive source/destination loss. Idle/menu-bar resource stability and the ten-minute real recording soak remain pending.
- Quit cleanup is bounded to eight seconds and replies to AppKit exactly once. Clip closes its popover, Preview and other owned windows, overlays, and status item before asynchronous finalization; if a media or Preview operation does not cooperate, termination proceeds and the existing capture sidecar/history reconciliation path provides next-launch recovery instead of leaving frozen UI.

### TST-01 — Deterministic automated test harness

- Status: `IN_PROGRESS`
- Lane: Quality
- Owner: Codex

- [x] Add injected clocks, permissions, displays, capture streams, audio sources, filesystem, pasteboard, shortcuts, and exporter fakes.
- [x] Unit-test display geometry, selection clamping, Last Area restoration, and missing-display fallback.
- [x] Unit-test the recording state machine, cancel thresholds, Pause/Resume retiming, and interruptions.
- [x] Unit-test settings defaults, persistence, history retention, rename, cleanup, and recovery.
- [x] Generate deterministic checkerboard, scrolling-text, cursor, motion, silence, and tone media fixtures.
- [x] Decode exported files and assert MP4/H.264/AAC, dimensions, FPS, duration, trim, frame order, quality, size bands, and A/V sync.
- [x] Add a fine-detail quality fixture with small bitmap text, one-pixel lines, saturated edges, scrolling, and cadence-relative 30/60 FPS motion.
- [x] Compare the former average-bitrate-only writer with quality 0.98 and require a material fidelity improvement.
- [x] Enforce no capture-to-master scaling, master SSIM/edge floors of 0.985/95%, Crisp 0.98/92%, non-resized Compact 0.96/85%, and no gap beyond two frame intervals.
- [x] Add injected UI launch modes for onboarding, denied permissions, displays, recording states, Preview, History, Settings, and failures.
- [ ] Exercise the menu-bar workflow and keyboard controls through UI tests where reliable.
- [x] Add regression coverage for Copy, drag export preparation, Save As, and temporary-file lifetime contracts.
- [x] Provide one local command that builds and runs the complete deterministic suite.

Evidence:

- Verified suites: ClipCore 80/80, ClipMedia 76/76, and the latest complete hosted Xcode ClipTests lane 142/142. The final strict Release app build/link also passes. Deterministic evidence includes H.264/AAC generation and inspection; objective SSIM/edge floors; dimensions/FPS/duration/trim/VFR timing/bitrate and soft-size-target checks; actual 5K/60 encoding/export; exact original timestamps through bounded held-frame cadence repair; decoded frame-order and PSNR bands; silent/audible exports with an unchanged master; queued audio pre-roll and duplicate/backwards per-input PTS rejection; 50 ms A/V sync; multi-hour state/writer soaks; bounded transaction/export cleanup; renamed-file, promised-drag, Save Panel, Copy-size, and pasteboard contracts; Apple trim/remux validation; and invalid-file rejection.
- `./scripts/verify-release.sh` is the complete permission-free wrapper. Hosted unit-test startup suppression keeps the Xcode lane noninteractive, while conditional real UI sources are compiled but never launched.
- Guarded `--ui-scenario=<name>` launches now use isolated temporary defaults/storage and a dedicated inert coordinator. Nine production-view scenarios cover onboarding, the populated menu/display popover, denied permissions, recording, paused recording, Preview, History, Settings, and failure state; unknown or ambiguous values fail closed, and scenario flags cannot affect production or the real-capture lane.
- UI-automation assertions for every scenario compile under strict Swift 6 checking but skip unless visible pointer control is explicitly opted in. Reliable automated coverage of every menu/keyboard path remains incomplete.

### TST-02 — Real-Mac acceptance suite

- Status: `BLOCKED`
- Lane: Quality
- Owner: Codex

- [x] Prove the explicit wrapper executes exactly one real UI test with no accidental skip.
- [x] Grant Screen & System Audio Recording to the stable installed Release identity and relaunch it.
- [ ] Rerun the no-audio real lane against a freshly built stable-signed release candidate.
- [ ] Capture a deterministic helper window using Capture Area and validate decoded pixels/dimensions.
- [ ] Capture fullscreen and validate Clip UI exclusion and cursor On/Off.
- [x] Exercise 30 FPS and optional 60 FPS capture on supported content.
- [ ] Smoke-test microphone only, system audio only, and both together on available hardware.
- [x] Exercise Pause/Resume and validate no paused interval plus acceptable A/V sync.
- [ ] Drag the video preview into Finder or a local receiver and validate the resulting MP4.
- [ ] Copy the MP4 and paste it into Finder or a local receiver.
- [ ] Exercise Save As, Reveal, Rename, Retake, History actions, and retention cleanup.
- [x] Simulate unavailable second-display, display-disconnect, and loopback-audio cases when hardware is absent.
- [ ] Run the ten-minute soak and record performance evidence.
- [ ] Keep any external-app paste/drop smoke check unsent and limited to an explicitly authorized destination.

Evidence:

- `scripts/run-real-capture-acceptance.sh --allow-permission-prompts-and-pointer-control` is implemented and explicitly opts into both privacy prompts and visible XCTest pointer control. Compile-time test selection proves the lane executes exactly once, and the wrapper rejects any result other than 1 passed, 0 failed, 0 skipped.
- Latest authoritative automated result: 0 passed, 1 failed, 0 skipped. The synthetic fixture opened, but the superseded ad-hoc Debug Clip identity received no ScreenCaptureKit frame and the test failed waiting for Pause. This is evidence that the gate executes, not evidence that capture passed. The owner's later manual pass on the stable-signed installed build confirms the core path but does not replace the automated assertions.
- The remaining flow is scripted to draw Capture Area using helper-published screen coordinates, assert the selected and encoded backing-pixel dimensions, decode H.264 fixture pixels from the managed master, pause/resume, trim, drag, Copy, revalidate fixture evidence in both exports, and check History. It can continue unattended when explicitly rerun against a freshly built app using the approved stable identity.
- The separate real-audio lane exercises microphone-only, system-audio-only, and combined modes. Its combined path requires two meaningful decoded source tracks in the managed master and one mixed AAC export, but all three modes still require owner-assisted permissions and a real run.
- `scripts/run-real-fullscreen-acceptance.sh --allow-permission-prompts-and-pointer-control` is a separate exact-one-test lane for Fullscreen → Record → Finish → Preview → Play. It uses isolated state and a local animated fixture, validates display dimensions/FPS/H.264 and decoded pixels, and has compiled successfully; its visible run was stopped at the owner's request and remains unchecked.
- The extended no-pointer controlled lane records the app-owned fine-detail fixture and tone, Pause/Resumes, generates a decoded Preview frame, makes a byte-identical local MP4 copy through a private pasteboard, re-decodes/re-evaluates the copy, and deletes every artifact. `scripts/run-unattended-quality-acceptance.sh --allow-controlled-self-capture` passed its strict 30 and optional 60 FPS targets without Accessibility, Automation, pointer, or keyboard control. The exact final packaged app then repeated and passed the primary 30 FPS lane.
- Permission-free ClipMedia coverage now proves that a vanished second display invalidates only its target, a disconnect before the first video sample discards empty output, a disconnect after video finalizes recoverable output, and unavailable loopback registration preserves video plus microphone registration.

### REL-01 — Local DMG and final handoff

- Status: `IN_PROGRESS`
- Lane: Release
- Owner: Codex

- [x] Finalize app/menu-bar icons, version metadata, bundle identifier, and copyright.
- [x] Produce a Release build with App Sandbox, Hardened Runtime, and stable local Apple Development signing.
- [x] Verify the current code-signing structure and entitlements locally.
- [x] Rebuild the current source into `Clip.dmg` containing `Clip.app` and an Applications shortcut.
- [ ] Mount the DMG, copy Clip to Applications, launch it, and complete the core workflow.
- [ ] Reopen the installed app and verify permission, settings, history, drag, and Copy persistence behavior.
- [x] Document installation, permissions, stable local Apple Development signing, ad-hoc CI fallback, Open Anyway, storage, and known platform limitations.
- [x] Add concise build, test, DMG, and cleanup instructions to the repository README.
- [ ] Run the full deterministic and real-Mac suites against the Release build.
- [x] Audit every v1 item in `spec.md` and reconcile this board before handoff.

Evidence:

- A clean stable-signed `scripts/package-dmg.sh` Release build and `scripts/verify-dmg.sh` read-only verification produced the current `.build/Clip.dmg`: 2,252,815 bytes, SHA-256 `5e7c45d5f3fe283efd76571056abea3443dd328c9a9bf5c846bed0866c54ec84`.
- The mounted artifact contains the arm64 app and Applications symlink, production resources and privacy descriptions, Apple Development certificate `BA37BFFD2BD1C29A995682647428847DBC6A83B3`, Team ID `FJ2BS65H3F`, a stable certificate-based designated requirement, Hardened Runtime, and required sandbox entitlements.
- The final packaged executable SHA-256 is `f63ab3932c55cab422af5fc61b67c2ffebfc903122e228783fffed979bae66e9`; `/Applications/Clip.app` matches it byte-for-byte, satisfies the same designated requirement, and passed the final no-pointer 30 FPS record/Pause/Resume/Preview/Copy/decode/quality flow.
- The permission-free release wrapper now writes ad-hoc verification images to `.build/Clip-permission-free.dmg`, preventing a CI-style verification run from overwriting the stable-signed `.build/Clip.dmg` and its privacy identity.
