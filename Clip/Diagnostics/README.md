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

## Native-v3 signed multi-process mesh acceptance

The native-v3 mesh needs distinct participant identities even when several
copies of the same signed Clip bundle run on one Mac. The guarded launcher
starts exactly three or four normal app coordinators with isolated state:

```sh
./scripts/launch-native-v3-mesh-acceptance.sh \
  --allow-native-v3-mesh-multi-instance \
  /absolute/path/to/Clip.app \
  --participants 3
```

Add `--require-system-audio` when every participant must publish one system
audio track. Without that flag the explicit expected audio count is zero.
Regardless of the audio setting, every participant must publish at least one
video source; an empty but connected mesh cannot pass.

The launcher verifies Clip's exact stable, certificate-based designated
requirement, leaf-certificate fingerprint, and Team ID; rejects ad-hoc or
differently signed apps; refuses an existing Clip process; and creates one
owner-only temporary run directory. The designated requirement is the identity
macOS uses to preserve Clip's privacy grants across builds. Each process
requires all private launch guards:

- `--ui-testing`
- `--native-v3-mesh-acceptance` plus its acknowledgement
- one strictly sanitized `--native-v3-mesh-participant=<id>`
- one launcher-generated run identifier and private report directory

The participant ID selects a persistent directory below Clip's temporary
UI-test root. Its Live Share signing key and capabilities are stored in an
owner-only file there instead of the production Keychain item. Normal launches
and real-capture acceptance continue to use the production Keychain.

This changes application state, not executable identity. Every process still
runs the exact same signed bundle identifier, so macOS Screen Recording
permission remains associated with that one signed Clip build. The launcher
prints only non-secret participant labels; it never prints private identities,
owner capabilities, access words, or room invites.

### Evidence contract

`NativeV3MeshAcceptanceReporter.swift` is compiled into the signed app because
the report must observe the production `ApplicationCoordinator`,
`MeshParticipantCoordinator`, participant identity, and AppKit termination
path. Normal launches never construct it.

Every independently launched process atomically writes an owner-only JSON
report signed by its persistent participant identity. The report embeds the
exact leader-signed membership and records:

- run/process/participant identity, session and membership revision;
- committed member count, current leader, leadership term, and room phase;
- every local peer link's readiness and direct/TURN route;
- local publication counts and per-remote received video/audio counts;
- failures, whether ready was ever reached, and clean teardown.

The launcher validates all reports as one set. It rejects missing/forged/stale
reports, inconsistent membership or leadership, missing links, unknown routes,
media counts that do not match the corresponding publisher, zero-source
participants, the wrong explicit audio count, and unclean termination. Once
the ready set passes, the launcher places a private termination request and
each app exits through AppKit's normal asynchronous cleanup path. Final reports
retain the last signed ready topology while proving the app reached `ended`.

This lane remains deliberately interactive for the real product entry points:
the owner creates one room, joins the other participants, approves admission,
and chooses actual sources/audio. The reporting code observes those production
actions; it never manufactures a room, bypasses admission, or injects media.
