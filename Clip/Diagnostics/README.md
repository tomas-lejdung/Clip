# Diagnostics

This directory contains test and acceptance-test entry points that must be
compiled into the signed Clip application. They are not user-facing features
and are unreachable during a normal launch.

## Why these live in the app target

The unattended capture checks exercise the real ScreenCaptureKit pipeline.
macOS grants Screen Recording access to a signed application identity, not to
an arbitrary XCTest process or command-line helper. Running the checks through
Clip therefore lets them validate the production capture path with the same
bundle identifier, sandbox, entitlements, signing identity, and AppKit
lifecycle that a user runs.

Moving this code into a separate executable would give that executable a
different privacy identity and would either require another permission grant
or stop testing the production integration.

## Test-suite map

- `Packages/*/Tests` contains fast unit and component tests for the package
  that owns each behavior.
- `ClipTests` covers app-level models, policies, adapters, persistence, and
  service integration without driving the macOS UI.
- `ClipUITests` drives production SwiftUI surfaces in isolated processes.
  `App/DeterministicUIScenarioCoordinator.swift` supplies fixed, inert state to
  those launches and is guarded by the UI-testing launch configuration.
- `scripts/run-deterministic-acceptance.sh` runs the permission-free UI and
  media acceptance gate used by release verification.
- The coordinators below are the exceptional real-capture checks that require
  Clip's signed Screen Recording identity.

## Unattended capture diagnostics

### `UnattendedCaptureSmokeCoordinator.swift`

Runs a controlled recording of Clip's own deterministic video and audio
fixture. It covers real capture, pause/resume, H.264/AAC output, timestamps,
preview decoding, copy, and cleanup. The shell entry point is:

```sh
./scripts/run-unattended-capture-smoke.sh \
  --allow-controlled-self-capture
```

`scripts/run-unattended-quality-acceptance.sh` invokes the same coordinator for
the longer quality gate.

### `UnattendedCursorCaptureRegressionCoordinator.swift`

Captures raw pre-encoder ScreenCaptureKit frames from a deterministic fixture
and compares the relevant 1x/2x display-resolution candidates while the native
cursor is static and moving. It preserves PNG evidence and a JSON report when
requested. The shell entry point is:

```sh
./scripts/run-unattended-cursor-capture-regression.sh \
  --allow-controlled-pointer-movement \
  --output .build/cursor-capture-evidence
```

This is the regression harness for the mixed Retina/external-display capture
matrix documented beside `CaptureVideoResolutionPolicy`.

## Safety and launch guards

Both coordinators fail closed unless their exact private command-line mode,
explicit acknowledgement flag, and matching environment variable are all
present. They also reject conflicting diagnostic modes.

- They never request or reset Screen Recording permission.
- The smoke check never controls the pointer, keyboard, or another app.
- The cursor regression moves the pointer only after explicit acknowledgement,
  only across Clip's own fixture, and restores its original position.
- The scripts verify Clip's bundle identifier and stable signing certificate.
- The cursor script refuses to run while another Clip instance is active.
- No coordinator is reachable from Clip's normal menu or ordinary launch path.

These diagnostics are distinct from the Swift package tests, `ClipTests`, and
`ClipUITests`. Those suites remain in their conventional test targets because
they do not need Clip's production Screen Recording identity.

## Server-coordinated mesh acceptance

The current clean-slate v4 gate is:

```sh
./scripts/run-live-share-acceptance.sh
```

It covers the authoritative Go room service, fragment-secret invite and
admission protocol, opaque encrypted pair signaling, WebRTC pair reconciliation,
and app-hosted three-participant flow. The composed app test establishes all
three A-B, A-C, and B-C links, replicates every participant's source to the
other two, preserves retained pairs across signaling reconnect and an ordinary
member leave, and treats creator departure as terminal for the room.

This architecture has no leader election, quorum, authority-chain catch-up, or
locked-room phase. The service owns the bounded opaque roster; the creator owns
admission while present; and each unordered participant pair owns one direct
WebRTC connection. The server never receives the invite fragment, private
identity key, decrypted SDP or ICE, source metadata, collaboration content, or
media.

The signed multi-process gate uses distinct local application state for each
instance while retaining Clip's one stable signed identity and existing Screen
Recording grant:

```sh
./scripts/launch-server-room-v4-mesh-acceptance.sh \
  --allow-server-room-v4-mesh-multi-instance \
  /absolute/path/to/Clip.app \
  --participants 3 \
  --server-root http://127.0.0.1:18080 \
  --menu-bar-popovers
```

The launcher verifies Clip's bundle, Team ID, and stable certificate; refuses
an already-running Clip process; creates a fresh run identifier; and launches
each participant with a fail-closed `--mesh-acceptance` mode plus unique
participant state. It does not manufacture a room, approve admission, publish
media, or expose private evidence. The owner exercises production Create Room,
Join Invite, source, audio, ordinary-leave, and creator-exit controls manually.
Use `--menu-bar-popovers` for manual testing of the real status-item interaction;
omit it when automation needs the separately addressable participant windows.
The full evidence contract is documented under **Signed multi-process GUI
gate** in `docs/ACCEPTANCE.md`.

`--server-root` is optional. It points only these isolated participants at a
branch-local v4 coordinator while the public server is still on an older
protocol. It never changes the installed app's endpoint or ordinary Clip
settings.

Normal launches cannot enter this mode. All four private flags are required:

- `--ui-testing`
- `--mesh-acceptance`
- `--acknowledge-mesh-acceptance`
- optional `--mesh-acceptance-menu-bar-popover`
- one `--mesh-acceptance-run=<id>` and one
  `--mesh-acceptance-participant=<id>`

The retired native-v3 reporter, validator, launcher, launch flags, paths, and
compatibility aliases have been removed.
