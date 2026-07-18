# Clip

Clip is a native Apple-Silicon macOS menu-bar recorder for short screen clips. Its core workflow is:

> Select an area or application, record, trim, then drag or copy an MP4.

The app is local-only: it has no account, cloud upload, analytics, AI processing, or third-party runtime dependencies. See [spec.md](spec.md) for the product contract, [ARCHITECTURE.md](ARCHITECTURE.md) for technical boundaries, and [PROGRESS.md](PROGRESS.md) for implementation and verification status.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Xcode 26.6 with the macOS SDK and Swift 6.3.3 command-line tools
- No paid Apple Developer membership is required; permission-free builds need
  no Team ID, while a free Personal Team can provide stable signing for real
  permission-backed testing

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
acceptance, Release packaging, read-only DMG mounting/inspection, signature and
entitlement checks, and a SHA-256 checksum. It never starts XCTest UI
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

When Xcode's project driver is temporarily unavailable, the same source set can be assembled with the lower-level Apple tools as an additional release diagnostic:

```bash
CLIP_MANUAL_BUILD=1 ./scripts/package-dmg.sh
```

That path still runs all package tests, performs the strict Swift 6 compile/link gate, compiles the asset and string catalogs, applies the production entitlements and Hardened Runtime, and uses the same configured signing identity. The normal Xcode Release build remains the final release path.

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

Managed masters and the versioned history index live below the app's Application Support container. Temporary drag, clipboard, and export files live in the app's Caches container. **Save As** files are independent and are never deleted by Clip history cleanup.

Save As uses the standard macOS Save panel. Selecting Downloads or another
sandbox-protected destination gives Clip access to that exact file through the
macOS Powerbox; no broad folder permission is required.

Settings exposes the resolved history directory, current default microphone, retention policy, and relevant Privacy & Security pages.

Export Settings also provides a validated default filename format using
`YYYY`, `MM`, `DD`, `HH`, `mm`, and `ss` tokens with a live example. Its three
independent video-quality controls accept whole numbers from 1 through 100;
Reset Quality Defaults restores Crisp `98`, Compact `90`, and Smallest `85`.

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
Settings defaults of `98`, `90`, and `85`. All three preserve the master's
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
