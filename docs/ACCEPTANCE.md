# Clip acceptance harness

## Server-coordinated Live Share local acceptance

Run the deterministic, pointer-free in-repository lane with:

```sh
./scripts/run-live-share-acceptance.sh
```

The script needs no sibling checkout. It runs the Go authoritative-room suite,
the v4 invite/admission/roster protocol tests, real WebRTC loopback and mesh
reconciliation tests, a real localhost two/three/four-participant service run,
and the app-hosted room, media-runtime, coordinator, presentation, and composed
three-participant suites against the same source. The Web release extension
adds embedded-viewer, browser canonical-crypto/session/media, and mixed-profile
mesh tests before the same native gates.

### Current local result — `DONE`

The v4 acceptance lane proves a client-secret stable invite, authoritative
server rosters, opaque pair signaling, deterministic full-mesh reconciliation,
pair-local recovery, and terminal creator departure. With the repository's
unmodified client and server, normal requests expose room and route identifiers
but never the invite fragment, private identity keys, decrypted pair messages,
media, or collaboration content. This does not claim fragment secrecy from a
malicious serving origin that replaces the Web client JavaScript.

This is a clean-slate v4 gate. There is no compatibility negotiation, legacy
connection fallback, leadership transfer, quorum, election, or locked-room
phase. The room creator owns admission for the room lifetime. An ordinary
participant may leave without disturbing other pairs; creator departure ends
the room for everyone.

The real localhost acceptance records rosters of two, three, and four
participants; direct-pair totals of one, three, and six; twelve directed
encrypted signaling routes at four participants; a byte-stable invite across
joins; zero private values exposed to the service; preserved remaining pairs
after an ordinary leave; and one terminal room-ended fanout after creator
departure.

The complete deterministic gate also passes `./scripts/test.sh`, Core 81,
Media 74, Capture 40, LiveShare 86, WebRTC 76, the Go service suites, strict
Swift 6 app/test compilation, project/localization audits, and 394 hosted app
tests. The hosted suite's only skip is the deliberately opt-in visual snapshot
lane.

Protocol and transport tests cover:

- P-256 participant identity and pair proof, HKDF-SHA256, AES-GCM,
  authenticated context, replay/tamper/sequence rejection, and strict v4 wire
  envelopes.
- A reusable fragment-secret invite, optional independent Access Word proof,
  optional creator approval, bounded admission, authoritative roster revisions,
  and cleanup on timeout or failure.
- One independently negotiated WebRTC connection and ordered data channel per
  participant pair, with exact pair isolation and retry of recoverable
  sequence/member/backpressure failures without ending the room.
- Stable media and collaboration state across signaling reconnects; reconnecting
  the service must not tear down an already usable P2P connection.
- Rejection of wrong-room, wrong-participant, wrong-pair, expired,
  duplicate-identity, stale-revision, malformed, oversized, and unsigned input.
- Signed four-step friendship with durable idempotent recovery, directional
  encrypted friend-presence mailboxes, identity-pinned friend join, mandatory
  creator Allow/Deny, and Access Word retry without exposing private values to
  the service.

The deterministic topology suite proves:

- Two participants: one peer link.
- Three participants: three independent peer links.
- Four participants: all six independent peer links.
- Every Native participant can publish four source slots and one audio track
  while receiving every other Native participant. A Web participant publishes
  an authenticated empty source snapshot and no media while receiving every
  compatible Native publisher.
- A slow, disconnected, renegotiating, or removed peer does not backpressure or
  corrupt another link.
- Provisional media stays quarantined until membership commits.

Presentation tests cover one common participant popover; `Your Share`; remote
sources in the compact `Shared With You` pane; independent per-participant
audio mute/volume; directional diagnostics using the negotiated codec rather
than the selected preference; source add/update/remove and rejoin recovery;
Fit, Native, Follow and fullscreen; hide/reopen and bring-to-front;
source-aware 1×/Retina geometry; focus and native cursor context; exact
participant cleanup; authoritative stale-capture-notice clearing; and the
room-global final-video-window prompt, which offers Stay Connected or Leave
Room only while a remote audio track remains.

Collaboration tests cover explicit pointer reveal, pings, and bounded temporary
vector strokes. They require source/participant attribution, normalized
coordinate mapping across Fit/Native/Follow and Retina scales, stale/wrong
source rejection, rate and size ceilings, clear/expiry semantics, and
capture-excluded local overlays. They never inject keyboard or pointer input
into another Mac.

The lane never opens the installed app, calls ScreenCaptureKit, requests a
privacy permission, uses the general clipboard, or controls the keyboard or
pointer. It does not establish production service availability, real desktop
quality, audible hardware output, overlay exclusion, remote Internet ICE, TURN,
sleep/wake behavior, or soak stability.

### Live Share evidence map

| Surface | Completed automated evidence | Not established by that evidence |
| --- | --- | --- |
| Server-room v4 protocol | Canonical crypto vectors, typed bounds, stable invite/Access Word proof, optional explicit admission, authoritative rosters, replay/tamper rejection and transactional teardown. | Traffic-analysis resistance, production service availability or private-key compromise. |
| Go service | Authoritative bounded room membership and pair routing, strict ciphertext relay, origin policy, security headers and real localhost WebSockets without private invite material or decrypted content. | Multi-replica routing, production TLS/reverse proxy or remote NAT traversal. |
| Mesh WebRTC | 1/3/6 authenticated links, independent negotiation and congestion, reserved source/audio tracks, exact selected-codec preference, RTP statistics and decoded stereo Opus quality. | Real ScreenCaptureKit system audio, controlled TURN, physical thermal behavior or four independently signed GUI processes. |
| Participant UI | Common Native room model, Native/Web profile badges, expanded local sources plus compact remote-source detail, per-participant audio, negotiated-codec diagnostics, ordinary and friend admission, private friend presence, immutable creator identity, window modes, rejoin recovery, stale-notice cleanup and collaboration overlays. | Production Spaces/displays, native window ordering, click consumption or capture exclusion. |
| Receive-only Web | Canonical fragment parsing/crypto, signed Web profile, same v4 admission/roster/pair wire, empty publication, source/track reconciliation, participant-scoped Follow, layouts, audio controls, unsupported-codec state, secure static hosting and browser reconnect ticket bounds. | Firefox/mobile support, cross-device production ICE/TURN, subjective browser rendering or a browser that lacks the selected exact codec. |
| Distribution | Clean-slate v4 source audit, dependency pins, sandbox entitlements and privacy-preserving service structure. | Final signed DMG, published image provenance and notarization. |

The receive-only Web row is the required web-v1 evidence set; it must not be
reported as completed until the integrated browser gate and controlled desktop
Safari/Chromium run have both passed.

The optional Access Word is checked by Clip inside the encrypted admission
route; its text is never sent to the service. Changing it applies to future
admissions and does not eject a member. Each Native participant's exact-window
audio is application-scoped; Fullscreen audio excludes Clip plus its selected
applications. Every receiver gets one independently controllable Opus track per
remote participant. Live Share never captures a microphone.

### Receive-only Web release gate

The Web participant is not a compatibility fallback or a separate signaling
system. Native and Web must pass the same reusable fragment-secret invite,
candidate admission, creator-certified descriptor, authoritative roster,
stable pair identity, pairwise encrypted SDP/ICE, fixed transceiver, and
ordered DataChannel fixtures. A + B + Web must produce three links without
changing A-B's transport ID, negotiation epoch, tracks, codec, or media; A + B
+ C + Web must produce six links.

The selected video codec is exact. The gate proves one publisher encoding, no
browser-specific fallback, transcode, or second encoder, an explicit
`Unsupported Encoding: <codec>` state when the selected codec is observable,
and no change to an unrelated pair. Current libwebrtc may reject the whole
incompatible edge before exposing that codec, so the edge may instead remain
unavailable or black and does not claim audio or DataChannel availability.

Current desktop Safari and Chromium are the web-v1 browser scope. A controlled
browser run must receive every compatible Native source and per-publisher audio,
exercise Focus/Grid/Row, participant-scoped Follow, Fit/Fill/Native, fullscreen,
master and per-participant audio controls, reload/reconnect, explicit Leave,
approval, denial, capacity, and room termination. It must also prove that
publishing, friendships, collaboration, and room administration are absent for
the signed Web profile.

Before release, the controlled-Mac lane must run two, three, and four
independently launched signed Clip GUI processes. All participants must share
and receive privacy-authorized real ScreenCaptureKit content concurrently;
exercise one through four windows, Fullscreen, resize, per-participant real
system audio and exclusions; prove pointer/ping/ink and capture exclusion;
remove and reconnect ordinary members; confirm creator departure ends the room
for every remaining member; create a replacement room; and stop cleanly.
Four participants must establish all six links. Physical multi-display/Spaces
and Retina/non-Retina combinations, direct Internet ICE, controlled TURN,
repeated churn, CPU/upstream/thermal/audio-mix observation, and the required
soak remain mandatory separate gates. Loopback is never described as complete
real-world Live Share evidence.

### Signed multi-process GUI gate — `THREE_PROCESS_DONE`

The controlled three-process run used Clip's stable signed identity, isolated
participant state, the real v4 local service, and only production Create Room,
Join Invite, source, friendship, leave/rejoin, and room-ending controls. A, B,
and C joined with the same unchanged invite; each reported three participants
and two direct links. They published one real ScreenCaptureKit window each,
and each received two windows from the other two people. Diagnostics showed
three media streams, actual negotiated AV1 and source resolution, P2P bytes,
and available bitrate.

C then left. A and B retained their direct link and each other's window. C
rejoined from the original clipboard invite and immediately recovered both
remote publishers. C's signed friend request to A completed after approval;
after leaving again C saw A as Live through private friend presence, selected
A, waited for the mandatory creator decision, and rejoined after A chose
Allow. Creator **End for Everyone** returned B and C directly to idle. A
unified-log audit found no Clip RTCP/SDP, `Capture is not running`, election,
locked-room, or crash report.

The final post-review repeat used a fresh signed three-process run and the same
production controls. Each participant published a persistent real window and
reported two links plus three media streams. C left while A and B retained
their link and windows, then rejoined from the original unchanged invite and
immediately recovered both remote publishers. Creator termination returned all
three directly to idle. Participant and server logs contained no SDP/RTCP-mux,
capture, signaling-loss, election, locked-room, or crash error.

This is real evidence for the three-participant window, reconnect, friends,
diagnostics, and termination path. It does not claim the still-pending four
participant/six-link gate, real system audio/exclusions, Fullscreen, remote
Internet/TURN, physical display/Spaces combinations, performance observation,
or soak run.

Launch three isolated instances with:

```sh
./scripts/launch-server-room-v4-mesh-acceptance.sh \
  --allow-server-room-v4-mesh-multi-instance \
  /absolute/path/to/Clip.app \
  --participants 3 \
  --menu-bar-popovers
```

Use `--participants 4` for the six-pair gate. The launcher only verifies the
signed app and creates fresh per-run participant state; it does not bypass or
simulate any production room action. `--menu-bar-popovers` exercises the real
status-item popovers for manual testing; omit it when Computer Use needs the
separately addressable participant windows.

The default acceptance lane is deterministic and permission-free:

```sh
./scripts/run-deterministic-acceptance.sh
```

It compiles `ClipTestHelper` with Swift 6 strict concurrency, synthesizes a
two-second H.264 MP4, validates the file with AVFoundation, remuxes it with
Apple's `avconvert`, validates a one-second trimmed remux, rejects a fake
`.mp4`, renders the capture fixture to a 960×540 PNG, copies the MP4 to an
independent renamed path containing spaces, and resolves that file URL through
a private named pasteboard. Validation includes H.264 High profile, Rec.709,
exact dimensions/sample count, and a maximum two-frame timestamp gap. It never
launches Clip or calls ScreenCaptureKit,
`AVCaptureDevice`, Accessibility, Automation, or another application.

The objective, permission-free quality gate is separate and can be run alone:

```sh
./scripts/run-quality-acceptance.sh
```

It renders deterministic small bitmap text, physical one-pixel lines,
saturated edges, scrolling, and cadence-relative 30/60 FPS motion. At the
default quality settings, it decodes the real quality-98 master, a forced
quality-98 Crisp transcode, and Compact-90 H.264 outputs and enforces luma SSIM/edge-retention floors of
0.985/95%, 0.98/92%, and 0.96/85% respectively. It also requires native
dimensions, durable cadence, High-profile Rec.709 video, bounded timestamps,
Compact output distinct from its source, and byte-identical eligible Crisp
reuse. Policy tests cover the Smallest-70 rung, independent 1–100 settings and
the `98`/`90`/`70` reset values, while inspecting encoder properties to ensure
hardware quality paths omit bitrate limits and the exact oversized native
software-H.264 fallback uses only its quality-derived soft average bitrate,
never a hard data-rate limit.
A test-only A/B baseline still requires the quality-0.98 master to materially
outperform the former ABR-only settings. The native writer tests also prove
that bounded held-frame cadence repair keeps all original timestamps as an
exact subsequence while leaving long sparse VFR timelines untouched.

The complete permission-free release gate is `./scripts/verify-release.sh`.
It includes the local Live Share lane above before packaging the app.
App-hosted unit tests detect XCTest injection and suppress normal production
startup before Clip creates its coordinator, status item, onboarding, system
integrations, or production-state services. Conditional real UI sources are
compiled by the strict gate but not launched.

## Unattended controlled-capture smoke

After Clip's stable-signed identity already has Screen & System Audio Recording
access, its production ScreenCaptureKit/AVAssetWriter path can be exercised
without XCTest UI automation or controlling another app:

```sh
export CLIP_CODE_SIGN_IDENTITY='YOUR_STABLE_40_CHARACTER_CERTIFICATE_SHA1'
./scripts/run-unattended-capture-smoke.sh --allow-controlled-self-capture
```

The wrapper verifies Clip's bundle identifier, code signature, and exact leaf
certificate before it runs the app executable. Clip fails without prompting if
Screen Recording is not already authorized. A double argument/environment
guard then creates one pointer-inert, app-owned synthetic window and a quiet
997 Hz app-owned tone. ScreenCaptureKit targets that exact window ID, includes
the current process's audio only for this lane, waits for a complete first
frame, records, pauses and resumes once, and finalizes through the production
`ScreenRecorder`.

Validation requires H.264 video, AAC system audio, expected native dimensions,
decoded fixture colors and motion, requested cadence, strictly increasing
video/audio timestamps without a pause-sized gap, close A/V endpoints, and a
non-silent decoded tone. It then generates a decoded Preview PNG, copies the MP4
byte-for-byte, resolves that copy through a private named pasteboard, and
re-decodes/re-evaluates the copy. It does not replace the user's clipboard. The
MP4, copy, Preview PNG, and private temporary directory are deleted
before success is reported; stale smoke directories from a force-terminated
run are cleared at the next start. The wrapper terminates a hung process after
the requested duration plus 30 seconds and retains its stdout/stderr diagnostics.
Optional `--fps 60` and `--duration 3...600` arguments support bounded cadence
and soak runs. It reports the strict two-frame-gap and fine-edge targets without
making them default hardware blockers. To enforce both at 30 and 60 FPS, run:

```sh
./scripts/run-unattended-quality-acceptance.sh --allow-controlled-self-capture
```

For a manual review of the same checkerboard, scrolling fine-detail text, motion,
and synthetic beep, explicitly preserve one validated 30 FPS result:

```sh
./scripts/run-unattended-capture-smoke.sh \
  --allow-controlled-self-capture \
  --duration 6 \
  --fps 30 \
  --require-quality-targets \
  --preserve-output "$PWD/.build/clip-checkerboard-beep-demo.mp4"
```

The app-side preserve flag remains behind the same argument/environment guard.
It reports the sandboxed source path only after the complete Preview/Copy/decode
validation passes. The wrapper verifies that path is the expected Clip sandbox
temporary tree, copies it byte-for-byte without overwriting an existing file,
and removes the temporary source, copy, and Preview image. Without
`--preserve-output`, the smoke lane continues to delete every artifact.

Both real-capture wrappers remain explicitly opted in and permission-dependent.
No mode uses CGEvent, AppleScript, Accessibility, Automation, the pointer,
keyboard, general clipboard, browser, or user application content.

## Signing for permission-backed lanes

The default build is ad-hoc signed so permission-free CI needs no certificate.
It keeps Hardened Runtime and App Sandbox enabled, but dynamically receives a
library-validation exception because certificate-free host/framework binaries
cannot share a Team ID. Certificate-signed builds explicitly omit that
exception and retain full library validation.
Because macOS gives each ad-hoc rebuild a different privacy identity, use one
stable certificate before approving Screen Recording, System Audio, or
Microphone access:

```sh
security find-identity -v -p codesigning
export CLIP_CODE_SIGN_IDENTITY='BA37BFFD2BD1C29A995682647428847DBC6A83B3'
./scripts/verify-release.sh
```

Keep that environment value for `test.sh`, both real-acceptance wrappers, and
all later packaging. The scripts never create, import, or modify certificates.
Packaging records the exact designated requirement in
`.build/Clip.dmg.designated-requirement`, and DMG verification compares the
packaged app with that record and the requested signer. After the first grant,
fully relaunch Clip before capture. Changing the certificate requires a new
privacy approval.

## Native fixture

Launch the native capture target and local receiver with:

```sh
HELPER="$(./scripts/build-test-helper.sh)"
"$HELPER" --fixture
```

The left side is deliberately easy to validate in captured frames:

- a high-contrast checkerboard and yellow crop boundary;
- stable color bars and coordinate labels;
- physical one-pixel lines, small text, and colored fine-edge targets;
- a 30 or 60 fps frame timecode;
- a horizontally moving pink marker;
- scrolling text containing the current frame number; and
- a crosshair for validating the recorded cursor position and clicks.

The right side accepts a dragged file URL, the current pasteboard file URL, or
a file selected with `NSOpenPanel`. It validates that the URL is a readable,
playable MP4 containing a positive-duration video track. It does not upload,
send, or open the file in another app. Pass `--result-file PATH` to atomically
write its latest validation report as JSON.

Useful noninteractive modes are `--status`, `--generate-mp4 PATH`,
`--validate-mp4 PATH`, `--validate-pasteboard`, and
`--render-fixture PATH --frame NUMBER`. Pass `--fixture-fps 30|60` to the
animated window to keep motion speed constant while changing cadence.

## Real capture lane

The real ScreenCaptureKit UI test is dormant by default. Once macOS permission
can be approved, invoke it explicitly:

```sh
./scripts/run-real-capture-acceptance.sh --allow-permission-prompts-and-pointer-control
```

After permission has been granted once, the same command can run unattended.
The helper publishes exact global drag endpoints and expected backing-pixel
dimensions. The test draws Capture Area around the fixture, verifies the
selection, records, and confirms the managed master has the corresponding even
dimensions, H.264 `avc1`, decoded frames, and the fixture's calibration colors.
It then pauses/resumes, trims, renames, drags to the local receiver, uses Copy,
and requires decoded fixture evidence in both shared files before confirming
the edit in History. It does not paste or drop into Messages, Slack, or another
external app.

Running `scripts/test.sh --ui` without `--allow-pointer-control` is refused.
Every UI lane therefore requires an explicit acknowledgement before XCTest can
move the visible pointer or type into app windows.

## Real audio lane

Microphone and system audio are covered by a separate compile-time opt-in lane:

```sh
./scripts/run-real-audio-acceptance.sh --allow-permission-prompts-and-pointer-control
```

This command requires Screen & System Audio Recording access, Microphone
access, a current default input device, and a working audio output device. It
prints a warning before starting because XCTest drives the real macOS pointer
and keyboard; leave the Mac idle until it finishes. Neither the ordinary test
lane nor `scripts/test.sh --ui --allow-pointer-control` compiles these three UI
test methods.

The microphone-only, system-audio-only, and combined paths are recorded and
validated independently through the real Clip app. ClipTestHelper emits a
low-volume 997 Hz synthetic tone, so system-audio validation never opens a
browser or user media. Each resulting MP4 must be playable and contain one
positive-duration AAC track with decoded PCM samples. System-audio and combined
assertions additionally require non-silent peak and RMS levels, rather than
accepting an empty or silent metadata-only track. For the combined mode, the
managed master must first contain two source tracks, each with meaningful
duration, encoded data, and decoded PCM samples; at least one must contain the
synthetic system tone. The exported file must then contain one mixed AAC track.
This proves both inputs reached the master and the sharing mix was produced,
without claiming that an unattended test independently proves an audible live
microphone signal.

Promised exports and isolated Clip test state are removed after validation.
