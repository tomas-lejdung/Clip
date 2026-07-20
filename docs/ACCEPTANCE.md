# Clip acceptance harness

## Native Live Share local acceptance

Run the deterministic, pointer-free in-repository lane with:

```sh
./scripts/run-live-share-acceptance.sh
```

The script needs no sibling checkout. It runs the complete Go server suite and
browser protocol tests, builds the real `server/cmd/clip-live-share-server`
binary, launches it on an unused loopback port, and validates `/healthz`,
`/version`, `/.well-known/clip-live-share`, and the embedded viewer. It then
runs the `ClipLiveShare` and `ClipLiveShareWebRTC` Swift package suites against
the same repository source. The WebRTC suite receives the loopback endpoint
through `CLIP_LIVE_SHARE_ACCEPTANCE_ENDPOINT` and enables its offscreen native
WebKit end-to-end case with `CLIP_RUN_NATIVE_WEBKIT_ACCEPTANCE=1`.

The Go tests include actual localhost WebSocket routing and cover room
advertisement, owner-token-hash authentication, leases, reconnect grace,
pending-route isolation, monotonic relay sequences, origin policy, security
headers, strict JSON and resource ceilings. Swift and browser tests share
deterministic P-256 ECDH, HKDF-SHA256 and AES-GCM vectors. They verify
directional keys, authenticated route context, tamper/replay/sequence rejection,
encrypted admission/SDP/ICE envelopes and the exact 196,400-byte inner-message
ceiling.

Native WebRTC coverage includes four random-identity video transceivers, exact
H.264/VP8 choices, preferred VP9 → VP8 and AV1 → VP9 → VP8 chains, one
Opus system-audio send track, transactional live codec switching, actual
outbound-codec statistics, bounded SDP/ICE/control input, reliable ordered
`clip-control-v1`, authoritative low-water replay and idempotent teardown. The
viewer tests cover encrypted host admission, opaque manifest-to-track binding,
focus/cursor state, audio attachment, mute/volume and autoplay recovery.

The offscreen WebKit viewer does not expose or move a pointer. The lane never
opens the installed app, calls ScreenCaptureKit, requests a
privacy permission, uses the general clipboard, or controls the keyboard or
pointer. It does not establish production service availability, real desktop
quality, audible hardware output, overlay exclusion, remote Internet ICE, TURN,
sleep/wake behavior or soak stability.

### Live Share evidence map

| Surface | Current automated evidence | Not established by that evidence |
| --- | --- | --- |
| Encrypted protocol | Cross-language crypto vectors, typed bounds, replay/tamper rejection, encrypted admission/SDP/ICE, opaque random stream identities and DataChannel handoff. | A malicious viewer deployment, traffic-analysis resistance or service availability. |
| Go service | In-memory ownership/leases, authenticated host replacement, route isolation, strict opaque relay, origin policy, embedded assets and real localhost WebSockets. | Multi-replica routing, production TLS/reverse proxy or remote NAT traversal. |
| Native WebRTC | Per-viewer negotiation, documented codec fallbacks, bounded capture/control queues, RTP statistics, Opus input and teardown. | Four simultaneous real browser-rendered sources, real system audio or controlled TURN. |
| Browser viewer | Protocol crypto, admission UI, opaque manifest binding, multi-stream state, audio controls and reconnect behavior. | Subjective text/audio quality or every target browser/OS combination. |
| UI and capture | Deterministic state/policy tests for popover, overlays, source rules, geometry and audio filters. | Production ScreenCaptureKit permission, Spaces/displays, click consumption and capture exclusion. |
| Distribution | Source audits cover dependency pins, sandbox entitlements and server container structure. | Final signed DMG, published image provenance and notarization. |

The optional access code is generated and checked by Clip inside an encrypted
route; its text is never sent to the server. Changing it applies to new
admissions and does not eject a connected peer. Window sharing captures audio
at application scope for unique owning apps, while Fullscreen captures system
audio excluding Clip. The embedded viewer attaches the stable Opus track and
offers mute, volume and autoplay-unlock controls. Live Share never captures a
microphone.

Before release, the controlled-Mac lane must share real ScreenCaptureKit content
through the production coordinator, exercise one through four windows plus
Fullscreen and resize, verify synchronized browser audio, prove both overlays
are absent from shared pixels, and stop cleanly. Remote Internet/TURN traversal,
repeated start/stop, and a ten-minute soak remain separate gates. Until those
run, loopback must not be described as complete real-world Live Share evidence.

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
