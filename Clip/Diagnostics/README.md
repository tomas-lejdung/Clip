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
