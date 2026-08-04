# Collaboration Window Controls — Implementation Checklist

This checklist tracks the post-mesh collaboration controls, fullscreen viewer
chrome, friend-join presentation, and local friend aliases. Capture,
ScreenCaptureKit resolution selection, encoding, media quality, and the
server-coordinated mesh transport remain out of scope for this pass.

## Shared floating-control design

- [x] Add reusable floating-control layout and appearance tokens.
- [x] Add reusable icon-toggle buttons, grouped-selection surfaces, and a
      fullscreen capsule shared by the viewer’s windowed/fullscreen chrome.
- [x] Preserve participant tint, hover, tooltip, keyboard, and accessibility
      behavior in windowed mode.
- [x] Reuse the same components in windowed and fullscreen viewer chrome.

## Collaboration controls

- [x] Add a pure global/per-source collaboration policy reducer.
- [x] Make new remote sources inherit the global Pointer, Ping, and Draw state.
- [x] Detach a source from global state after its first per-window edit.
- [x] Retain an internal reset-to-global path without adding redundant viewer
      chrome.
- [x] Reset all source overrides whenever any global tool changes.
- [x] Keep Pointer independent and make Ping and Draw mutually exclusive.
- [x] Preserve overrides across visibility and temporary peer/track recovery.
- [x] Prune overrides only when the authoritative source or room ends.
- [x] Send a targeted hidden-pointer event when Pointer becomes disabled.
- [x] Expose three compact per-window controls with tooltips and custom-state
      indication.
- [x] Clarify in the Collaboration popover that its controls apply globally.

## Fullscreen viewer controls

- [x] Replace the fullscreen-wide header with a compact centered capsule.
- [x] Position it below the menu-bar/notch safe area.
- [x] Reveal it on fullscreen pointer movement without requiring the screen edge.
- [x] Fully hide it after inactivity and disable hidden hit-testing.
- [x] Keep it visible while hovered and respect Reduce Motion.
- [x] Preserve Escape, explicit exit, scale mode, and restored window geometry.

## Friend join lifecycle

- [x] Keep the Live Share pane visible while joining and awaiting approval.
- [x] Model denied, timed-out, failed, canceled, and active outcomes explicitly.
- [x] Show Waiting for Approval with friend/room context and Cancel.
- [x] Show Denied until the user chooses Try Again or Done.
- [x] Refresh encrypted friend presence before retrying.
- [x] Close a candidate after a bounded approval timeout.
- [x] Keep invites and access words memory-only.

## Friend aliases

- [x] Persist an optional local alias without changing the signed friend profile.
- [x] Add atomic rename and reset repository operations.
- [x] Preserve aliases across friendship reconfirmation.
- [x] Preserve presence revision/backoff state for alias-only changes.
- [x] Add Rename and Remove actions to friend rows.
- [x] Validate, trim, and reset aliases safely.

## Verification

- [x] Add reducer and source-lifecycle unit tests.
- [x] Add window-control layout, tooltip, accessibility, and interaction tests.
- [x] Add fullscreen safe-area, HUD-overlap, reveal, and hide tests.
- [x] Add waiting, denial, timeout, retry, cancel, and approval tests.
- [x] Add alias persistence, identity-integrity, and presence-continuity tests.
- [x] Run the focused Swift package and Xcode suites.
- [x] Build and verify a stable-signed repository app.
- [x] Run real two-instance collaboration/fullscreen acceptance.
- [x] Run real three-instance regression acceptance.

Manual acceptance on 2026-08-02 used stable-signed repository builds. The
two-instance pass exercised Pointer, Ping, Draw, per-window overrides,
fullscreen reveal/hide and exit, Native cursor-follow panning, friend approval,
and friend rename. The three-participant pass confirmed collaboration delivery
to host and viewers, per-source window controls, source occlusion masking, and
cleanup as participants and shared windows left. These dated runs are product
evidence; the deterministic tests above remain the repeatable regression gate.

## Manual visual refinements

- [x] Keep per-window overrides visually quiet: no detached-state outline.
- [x] Remove the redundant per-window “Use Global Settings” button.
- [x] Give the Follow/Native/Fit control balanced horizontal padding.
- [x] Hide Clip’s separate top-right sharing HUD while a remote viewer is
      fullscreen, then restore it on exit.

## Manual acceptance follow-ups

- [x] Balance the scale-mode dropdown’s left and right content padding in
      windowed and fullscreen chrome.
- [x] Preserve Native rendering and cursor-follow panning while fullscreen.
- [x] Give friend rows balanced content padding and a hoverable trailing actions
      target.
- [x] Make the friend row two contiguous full-height action segments, with the
      join content on the left and a centered actions icon on the right.
- [x] Remove the close/leave control from fullscreen viewer chrome.
- [x] Exit AppKit fullscreen before tearing down a viewer window so room leave
      cannot strand a frozen fullscreen surface.
