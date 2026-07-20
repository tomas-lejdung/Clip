# Clip

Clip is a native Apple-Silicon macOS menu-bar recorder for short screen clips. Its core recording workflow is:

> Select an area or application, record, trim, then drag or copy an MP4.

Recordings remain local: Clip has no account, cloud upload, analytics, or AI
processing. Live Share is a separate, explicit network mode that sends transient
screen frames and optional system audio to viewers over WebRTC. Clip's in-repo
Go service advertises rooms, serves the browser viewer, and relays only bounded
end-to-end-encrypted signaling; Live Share never writes media to History. See
[spec.md](spec.md) for the product contract,
[ARCHITECTURE.md](ARCHITECTURE.md) for recording boundaries, and
[docs/live-share-architecture.md](docs/live-share-architecture.md) for the
network protocol and trust boundary.

Live Share can send up to four application windows or one fullscreen display.
It uses native Swift/AppKit/SwiftUI and ScreenCaptureKit, with a pinned native
WebRTC framework. VP8 remains the default. The live codec picker selects a
preference: H.264 and VP8 are exact choices, VP9 may fall back to VP8, and AV1
may fall back to VP9 and then VP8. Each browser viewer negotiates independently,
so the actual outbound RTP codec shown in Statistics is authoritative. H.264
uses hardware encoding and caps oversized capture geometry; software VP8, VP9
profile 0, and AV1 retain native capture geometry. AV1 can consume substantially
more CPU. SDP, ICE, access-code proofs, stream metadata, and control state are
encrypted between the browser and Clip before reaching the signaling service.
Once the reliable `clip-control-v1` DataChannel opens, signaling for that viewer
closes and subsequent control and renegotiation are peer-to-peer. A configured
TURN relay may still carry encrypted WebRTC traffic when a direct route is not
possible.

The pointer-free acceptance lane builds the in-repo server and viewer, exercises
the encrypted signaling protocol and browser cryptography on loopback, and runs
the native package suites without opening the installed app or controlling the
pointer. Codec tests keep a browser viewer, session, and set of tracks alive
while switching H.264 → VP8 → VP9 → AV1 → H.264, accept only the
documented per-viewer fallbacks, and verify the codec reported by outbound
WebRTC statistics. Real desktop Live Share capture,
overlay exclusion, remote Internet/TURN traversal, soak, and lifecycle stress
remain separate controlled gates; the stable-signed, sandboxed Release DMG has
passed its clean-source packaging gate. See the [Live Share progress
board](docs/live-share-progress.md). Live Share system audio defaults to Off and
persists independently from recording settings. Window sharing captures audio
at application scope for the unique owning apps; Fullscreen captures system
audio while excluding Clip. ScreenCaptureKit's 48 kHz stereo samples
feed one stable Opus WebRTC send track through Clip's native bridge. There is no
microphone sharing. The embedded viewer attaches the received audio track and
provides mute and volume controls, with an explicit click-to-enable path when a
browser blocks autoplay. Thirty FPS is the supported default, 15 FPS is
selectable, and 60 FPS is an optional capability rather than a release
requirement.

Click Highlights can be enabled from the menu-bar quick controls or Recording
Settings. The option uses ScreenCaptureKit's native recorded click indicator,
defaults to Off, remains independent of cursor visibility, and requires no
Accessibility permission.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Xcode 26.6 with the macOS SDK and Swift 6.3.3 command-line tools
- No paid Apple Developer membership is required; permission-free builds need
  no Team ID, while a free Personal Team can provide stable signing for real
  permission-backed testing
- Go 1.25 or newer and Node.js are required only for the in-repository Live
  Share server/viewer acceptance lane; Docker Buildx is optional for publishing
  the self-hosted service image

If a newly updated Xcode reports that first-launch components are missing, initialize it once from an administrator account:

```bash
sudo xcodebuild -runFirstLaunch
```

## Build and test

The repository keeps generated build output under `.build/`.

```bash
# Package tests, strict Swift 6 app type-check, and a real arm64 link
./scripts/typecheck.sh

# Clean Xcode Debug or Release build
./scripts/build.sh Debug
./scripts/build.sh Release

# Package tests plus app unit tests
./scripts/test.sh

# Optional UI tests; XCTest moves the visible pointer and types into app windows
./scripts/test.sh --ui --allow-pointer-control

# Permission-free synthetic media and drag/clipboard acceptance
./scripts/run-deterministic-acceptance.sh

# Permission-free objective master/Crisp/Compact fidelity gate
./scripts/run-quality-acceptance.sh

# In-repo encrypted Live Share server/viewer and native transport acceptance
./scripts/run-live-share-acceptance.sh

# Opt-in Release benchmark for Preview readiness and Compact export
./scripts/benchmark-performance.sh

# Complete permission-free release gate, including a verified Release DMG
./scripts/verify-release.sh

# Explicit real ScreenCaptureKit lane; may show a macOS permission prompt
./scripts/run-real-capture-acceptance.sh --allow-permission-prompts-and-pointer-control

# No-pointer real record/Preview/Copy/decode quality lane; permission must exist
./scripts/run-unattended-quality-acceptance.sh --allow-controlled-self-capture

# Preserve one validated 6-second checkerboard/beep MP4 for manual review
./scripts/run-unattended-capture-smoke.sh --allow-controlled-self-capture \
  --duration 6 --fps 30 --require-quality-targets \
  --preserve-output "$PWD/.build/clip-checkerboard-beep-demo.mp4"

# Explicit real microphone/system-audio lane; also drives the visible pointer
./scripts/run-real-audio-acceptance.sh --allow-permission-prompts-and-pointer-control
```

`typecheck.sh` is the permission-free verification gate. It runs deterministic ClipCore and ClipMedia tests, including direct VideoToolbox H.264/AAC media generation, objective small-text/one-pixel SSIM and edge checks, trimming, cadence, and audio mixing, then compiles and links every app source with complete Swift 6 concurrency checking. It also compiles both conditional real-capture and real-audio UI paths without launching them.

`verify-release.sh` is the single unattended release-candidate command. It
combines the strict source gate, package and app unit tests, deterministic media
acceptance, in-repository Live Share server/viewer/WebKit acceptance, Release
packaging, read-only DMG mounting/inspection, signature and entitlement checks,
and a SHA-256 checksum. It never starts XCTest UI
automation; the pointer-driving lanes remain separate and explicitly opt-in.

`benchmark-performance.sh` generates the exact 30-second, 1,440 × 900, 30 FPS
reference fixture and records Release timings in
`.build/performance/latest.json`. It stays separate from correctness gates to
avoid load-sensitive failures. See [docs/PERFORMANCE.md](docs/PERFORMANCE.md)
for the measurement boundary, reuse safeguards, and latest development-Mac
evidence.

App-hosted unit tests suppress Clip's normal production startup before creating
the coordinator, so they cannot create a menu-bar item, show onboarding,
register system integrations, read production state, or request permissions.

The real-capture wrapper selects exactly one opt-in UI test and fails unless it
executes once with `1 passed, 0 failed, 0 skipped`. A normal
`test.sh --ui --allow-pointer-control` run
keeps that permission-gated case skipped.

The real capture lane is visibly interactive: it opens the local checkerboard
fixture and drag receiver, launches Clip, and drives the real macOS pointer to
draw Capture Area, trim, drag, and Copy. It validates the selected region's
exact backing-pixel dimensions and decoded fixture colors in the managed master
and shared exports. The real-audio lane separately exercises microphone-only,
system-audio-only, and combined recording. Both wrappers require their explicit
permission-and-pointer acknowledgement; the fixture contains synthetic content
only, and seeing it during a run is expected.

## Run the Live Share service

The complete privacy-minimal signaling service and browser viewer live in the
top-level [`server`](server) folder. They do not depend on another checkout.
For local development:

```bash
cd server
go run ./cmd/clip-live-share-server
```

The default address is `http://localhost:8080`. Set that address in Clip's Live
Share Settings, then use **Test Connection**. The server keeps room
advertisements in memory, exposes process-only `/healthz` and `/version`
endpoints, and serves deployment capabilities at
`/.well-known/clip-live-share`.

For a self-hosted deployment, terminate TLS at a reverse proxy and expose the
service through HTTPS/WSS. A single server instance is intentional for v1; a
restart clears its in-memory room registry and Clip re-advertises. Build the
non-root container locally with:

```bash
cd server
docker build --build-arg VERSION=development -t clip-live-share-server .
docker run --rm -p 8080:8080 clip-live-share-server
```

`server/scripts/publish-docker.sh VERSION` publishes `linux/amd64` and
`linux/arm64` images through Docker Buildx. Full configuration, including
origin policy, leases, resource ceilings, and STUN/TURN capabilities, is in
[`server/README.md`](server/README.md).

The viewer link contains the room's ephemeral P-256 public key in the URL
fragment (`#v=1&key=...`). Browsers do not send URL fragments in HTTP requests,
so the signaling service does not receive that key through normal routing. The
viewer combines it with a fresh private key to derive per-viewer AES-GCM keys;
this prevents an honest-but-curious relay from reading or changing signaling.
The fragment is not a password, and the viewer HTML is trusted as part of the
chosen deployment: an operator who replaces that JavaScript can read the page's
fragment. Users who do not trust the hosted deployment can run the same server
and embedded viewer themselves.

## Create the local DMG

```bash
./scripts/package-dmg.sh
./scripts/verify-dmg.sh .build/Clip.dmg
```

The result is `.build/Clip.dmg`, containing `Clip.app` and an Applications shortcut. The bundle identifier is permanently `com.tomaslejdung.clip`, with Hardened Runtime and App Sandbox enabled. By default the app is ad-hoc signed, which is appropriate for permission-free CI but gives every rebuild a different macOS privacy identity.

Before permission-backed testing, use one stable certificate for every build,
test, manual-build, and package command. Set its unique 40-character SHA-1 as
printed by `security find-identity` (the hash avoids ambiguity when Keychain
contains duplicate certificate names):

```bash
security find-identity -v -p codesigning
export CLIP_CODE_SIGN_IDENTITY='BA37BFFD2BD1C29A995682647428847DBC6A83B3'
./scripts/verify-release.sh
```

An Apple Development identity from a free Personal Team is sufficient for this
single-Mac workflow; Developer ID and notarization are not required. Keep the
same exported value when running the real acceptance lanes and future builds.
`package-dmg.sh` records the app's designated requirement beside the image as
`.build/Clip.dmg.designated-requirement`; `verify-dmg.sh` checks that record and
requires either the default ad-hoc signature or the exact configured signer.
When `verify-release.sh` runs without a configured identity, it writes the
ad-hoc diagnostic image as `.build/Clip-permission-free.dmg` so it cannot
replace an existing stable-signed `.build/Clip.dmg`.

The default and Personal Team workflows are intentionally not Developer ID
signed or notarized. If macOS attaches quarantine after the DMG is downloaded,
messaged, or AirDropped, open Privacy & Security and use **Open Anyway** once.

The low-level manual build remains a compile diagnostic, but updater-enabled
release packages must use the Xcode build so Sparkle's framework and installer
services are embedded and signed correctly.

## Publish an update

Clip uses Sparkle 2 for native updates. Versioned DMGs live in GitHub Releases,
while the signed appcast is served from this repository's `docs/appcast.xml`
through GitHub Pages. Release preparation is local and fail-closed: it verifies
the version, build number, code signature, embedded updater configuration,
immutable asset URL, EdDSA signature, exact committed source version, and a
fresh isolated resolution of the pinned Sparkle dependency without publishing
anything.

```bash
./scripts/prepare-github-release.sh \
  --tag v1.2.0 \
  --release-notes docs/releases/1.2.0.md \
  --keychain-account ed25519
```

See [docs/RELEASING.md](docs/RELEASING.md) for the one-time GitHub Pages setup,
key handling, version rules, ordered GitHub Release commands, final update test,
and rollback procedure. Release staging also requires clean-build provenance
and verifies the archive signature against the public key embedded in Clip.
The first Sparkle-enabled build must be installed manually; later releases can
update it in place.

## Install and permissions

1. Open `Clip.dmg`.
2. Drag Clip to Applications.
3. Open Clip; it appears in the menu bar and has no Dock icon by default.
4. Start Capture Area, Capture App, Last Area, or Fullscreen.
5. Approve Screen & System Audio Recording when macOS asks.
6. Enable microphone or system audio in Settings only if wanted; those optional permissions are requested on demand.

Screen Recording approval cannot be granted by a test or install script. An
ad-hoc build has a build-specific code identity, so macOS may ask again after
every rebuild even while System Settings still shows an enabled row named
Clip. Fully relaunch after granting access. Stable signing as described above
makes subsequent builds recognizable as the same app. Changing certificates
requires approval again. Clip never requests Accessibility access.

Capture Area keeps its border visible while recording but removes the selection
dimming; Clip excludes that border from the recorded pixels. Capture App lets
you click an application and records all of its visible windows on the clicked
display, not merely one window.

## Local data

Managed masters and the versioned history index live below the app's Application Support container. Temporary drag, clipboard, and export files live in the app's Caches container. The History window's Exports tab lists files actually published by Copy or drag and lets you reveal or delete them; deleting a source recording leaves its exports available there until you purge them or the seven-day cache cleanup expires them. **Save As** files and unpublished Save As intermediates are not listed; the external files are independent and are never deleted by Clip history cleanup.

Save As uses the standard macOS Save panel. Selecting Downloads or another
sandbox-protected destination gives Clip access to that exact file through the
macOS Powerbox; no broad folder permission is required.

Settings exposes the resolved history directory, current default microphone, retention policy, and relevant Privacy & Security pages.

Export Settings also provides a validated default filename format using
`YYYY`, `MM`, `DD`, `HH`, `mm`, and `ss` tokens with a live example. Its three
independent video-quality controls accept whole numbers from 1 through 100;
Reset Quality Defaults restores Crisp `98`, Compact `90`, and Smallest `70`.

## Automated acceptance design

The deterministic test path does not need privacy grants or external hardware. It uses injected state, filesystem and pasteboard boundaries plus generated video/audio fixtures. After the owner grants macOS privacy permissions once, the real-Mac suite can run unattended against a deterministic helper window and a local drag/paste receiver. A second display and deterministic audio loopback are simulated when unavailable.

Sending content to Slack, GitHub, Linear, Discord, Messages, or Mail is not part of the automated suite. Finder and the local receiver validate the same promised-file drag and pasteboard file-URL contracts without contacting another service.

## Export quality

Export dimensions are derived from the actual recording and always preserve
its aspect ratio. Masters are encoded directly from ScreenCaptureKit pixel
buffers by VideoToolbox at the current Crisp quality setting, default `98`
(`0.98` internally). Clip prefers exact-size hardware H.264 and uses
exact-size hardware HEVC for a managed master only when H.264 cannot represent
an oversized native display mode; Copy, drag, and Save As outputs remain H.264.
AVAssetWriter only muxes the already compressed video with AAC into MP4.
Capture rectangles are physical-pixel aligned and every
frame must match the configured dimensions, so no hidden capture-to-master
resize can blur text. One transient prior frame can bridge a single short
ScreenCaptureKit scheduling miss; original timestamps remain unchanged and
static/sparse variable-frame-rate timing is not expanded.

**Crisp**, **Compact**, and **Smallest** are a quality ladder with independent
Settings defaults of `98`, `90`, and `70`. All three preserve the master's
native even dimensions and durable captured cadence, use H.264 High-profile
Rec.709 video and the same 128 kbps AAC policy. Hardware H.264 uses the selected
VideoToolbox quality directly. Exact oversized exports retain native dimensions
through Apple's software H.264 encoder, which requires a quality-derived soft
average bitrate; no path sets a hard data-rate limit or target file size.
Offline exports prioritize quality and permit frame reordering. The settings
are intentionally independent; Clip does not enforce their ordering.

An eligible unchanged Crisp export byte-reuses the source master. Crisp
transcodes when trim, changed quality, audio mixing, or audio removal makes
reuse incompatible; Compact and Smallest are always offline quality-based
exports. Preview shows “Quality based — size varies” before every export and
the actual size afterward. Remove audio is applied in the same export
generation and never changes the managed master.

## Icon assets

The checked-in app icon is generated from native vector geometry encoded in the regeneration script:

```bash
./scripts/generate-icons.sh
```

Regeneration requires ImageMagick; building Clip does not.
