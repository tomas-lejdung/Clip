Here is the finalized product specification for **Clip**.

# Clip — Product Specification

## Product summary

**Clip** is a lightweight native macOS screen recorder for creating short, compact product and development demos.

Its primary workflow is:

1. Choose an area of the screen.
2. Record a short demonstration.
3. Trim the beginning or end.
4. Copy a compact MP4.
5. Paste it directly into Slack, GitHub, Linear, Discord, or another application.

Clip is not intended to replace a full video editor or general screenshot suite. It should do one task extremely well:

> Record and share a clear screen clip with as little friction as possible.

---

## Product principles

Clip should be:

- Fast to activate.
- Native to macOS.
- Primarily controlled from the menu bar.
- Optimized for short recordings.
- Designed around sharing rather than video production.
- Simple enough that users rarely need to open a settings window.
- Local-first, with no account or cloud service required.
- Able to produce compact files while preserving readable interface text.

---

# Core user experience

## Application behavior

Clip launches as a menu-bar application.

By default:

- No regular application window opens.
- No Dock icon is shown.
- A Clip icon appears in the macOS menu bar.
- Clip may optionally launch automatically when the user logs in.

Clicking the menu-bar icon opens the main Clip popover.

---

## Menu-bar popover

The default popover contains:

```text
Capture Area…
Last Area
Fullscreen
Display 1
Display 2

Microphone        Off
System Audio      Off

● Record

Recent Recordings
Settings
Quit Clip
```

Unavailable options should be hidden. For example, `Display 2` should only appear when a second display is connected.

Clip remembers:

- The most recently used capture mode.
- The most recently selected area.
- Audio settings.
- Frame-rate preference.
- Export preset.

---

# Capture modes

## Capture Area

Choosing **Capture Area…** activates Capture Mode.

During Capture Mode:

- All connected displays are covered by transparent selection overlays.
- The screen outside the selected region is dimmed.
- The cursor becomes a crosshair.
- The user draws a rectangular capture region.
- The selected region remains undimmed.
- The region displays resize handles.
- The region can be moved or resized before recording begins.

A compact toolbar appears next to the selected region.

Example:

```text
1440 × 900

Microphone: Off
System Audio: Off

Cancel     Record
```

Keyboard controls:

```text
Return     Start recording
Escape     Cancel Capture Mode
Arrow keys Move selection
Shift      Resize or constrain movement
```

The toolbar must position itself outside the selected region whenever possible so that it does not cover the content being recorded.

---

## Last Area

The **Last Area** preset immediately restores the most recently used capture rectangle.

This is particularly important for repeated recordings of:

- A browser viewport.
- An application preview.
- An iOS Simulator.
- A fixed section of an ultrawide display.
- A development environment.

The region should be stored relative to its display configuration where practical.

If the original display is unavailable, Clip should fall back gracefully and allow the user to adjust the region.

---

## Fullscreen

The **Fullscreen** preset records an entire display.

If multiple displays are connected, the user selects the display before recording.

---

## Display presets

The menu-bar popover lists connected displays, such as:

```text
Display 1 — 5120 × 1440
Display 2 — 2560 × 1440
```

Selecting a display prepares it as the capture target.


---

# Starting a recording

After selecting a capture target, the user may start recording through:

- The Record button.
- The Return key.
- A configurable global shortcut.
- The menu-bar popover.

A countdown may appear before recording starts.

Default:

```text
3
2
1
```

The countdown can be disabled in settings.

---

# Recording state

While recording:

- The Clip menu-bar icon changes to indicate an active recording.
- The elapsed recording time is visible in the menu-bar popover.
- The app remains usable without showing a floating controller over the recording.
- The selected capture border is hidden or reduced to a subtle indicator outside the recorded pixels.

The menu-bar popover changes to:

```text
● Recording 00:18

Pause
Finish Recording
Cancel Recording
```

Keyboard shortcuts:

```text
Option + Command + R   Enter Capture Mode
Option + Command + S   Finish recording
Option + Command + P   Pause or resume
Escape                 Cancel before recording begins
```

All shortcuts must be configurable.

---

# Recording controls

## Pause and resume

The user can pause and resume recording.

Paused time must not appear in the final video.

Audio and video should remain synchronized after resuming.

---

## Finish

Finishing the recording stops capture and opens the preview window.

---

## Cancel

Canceling during a recording discards the recording after a brief confirmation when meaningful content has already been captured.

Very short accidental recordings may be discarded immediately.

---

# Audio

Clip supports:

- No audio.
- Microphone only.
- System audio only.
- Microphone and system audio.

Audio is disabled by default.

The most recently selected audio configuration is remembered.

Clip must clearly communicate when additional macOS permissions are required.

Potential microphone input selection can initially use the system default input device.

Explicit microphone-device selection may be added later.

---

# Video capture

## Default recording configuration

The default recording configuration is:

- MP4 container.
- H.264 video.
- 30 frames per second.
- Native capture resolution where practical.
- Hardware-accelerated encoding.
- Cursor visible.
- No audio unless enabled.
- No webcam.
- No click animations.
- No keystroke overlay.

An optional 60 FPS mode is available in settings or export preferences.

---

## Cursor

The user can choose whether the cursor is visible in recordings.

Default:

```text
Show cursor: On
```

Cursor highlighting, click ripples, and cursor enlargement are not part of the MVP.

---

# Preview and editing

When recording stops, Clip opens a compact floating preview window.

The preview contains:

- Video playback.
- Play and pause.
- Current time.
- Total duration.
- A simple timeline.
- Trim handles for the beginning and end.
- File-size estimate.
- Export preset.
- Primary Copy Video action.

Example:

```text
┌─────────────────────────────────────┐
│                                     │
│            Video preview            │
│                                     │
├─────────────────────────────────────┤
│ |◀──────────────────────────────▶|  │
│ 00:02                         00:24  │
│                                     │
│ Compact · approximately 5.8 MB      │
│                                     │
│ Delete    Save As…    Copy Video    │
└─────────────────────────────────────┘
```

---

## Editing scope

The MVP editor supports:

- Playback.
- Trimming from the beginning.
- Trimming from the end.
- Restoring the original trim.
- Retaking the recording.
- Deleting the recording.

The MVP does not support:

- Splitting clips.
- Joining recordings.
- Text overlays.
- Shapes or arrows.
- Blur regions.
- Zoom effects.
- Transitions.
- Speed changes.
- Audio editing.
- Multi-track editing.

---

# Export

## Primary action: Copy Video

The primary action is **Copy Video**.

When selected, Clip:

1. Applies the selected trim.
2. Encodes or remuxes the recording as needed.
3. Produces a compact MP4.
4. Places the resulting file on the macOS clipboard.
5. Shows a completion confirmation.

Example:

```text
✓ Video copied — 5.8 MB
```

The user should then be able to paste the video directly into:

- Slack.
- GitHub issues and pull requests.
- Linear.
- Discord.
- Messages.
- Mail.
- Finder.
- Other applications that accept copied files.

---

## Save As

The user can save the exported recording to a chosen location.

The default filename format may be:

```text
Clip 2026-07-17 at 10.42.18.mp4
```

The filename should be editable before saving.

---

## Reveal in Finder

After export or save, the user can reveal the file in Finder.

---

# Export presets

Clip exposes simple presets instead of technical bitrate controls.

## Compact

Default preset.

Designed for:

- Slack.
- GitHub.
- Linear.
- Short product demos.
- Bug reports.

Behavior:

- 30 FPS.
- H.264.
- Small file size.
- Preserves readable UI text.
- May slightly reduce resolution for unusually large captures.

---

## Crisp

Designed for recordings where fine interface detail matters.

Behavior:

- Higher bitrate.
- Preserves native resolution more aggressively.
- Optional 60 FPS.
- Larger output file.

---

## Smallest

Designed for strict upload limits.

Behavior:

- Lower bitrate.
- May reduce dimensions.
- May reduce frame rate.
- Can target a maximum approximate size.

Initial target options:

```text
10 MB
25 MB
Custom
```

Exact target-size encoding may be introduced after the initial release if it requires a two-pass export process.

---

# Recent recordings

Clip maintains a small local recording history.

The menu-bar popover shows recent recordings:

```text
Recent Recordings

Checkout validation      3.8 MB
Dashboard filters        7.1 MB
Mobile navigation        2.4 MB
```

Each recording supports:

- Preview.
- Copy.
- Save.
- Reveal in Finder.
- Delete.

Recordings remain local.

Default retention:

```text
7 days
```

Retention options:

- 1 day.
- 7 days.
- 30 days.
- Keep indefinitely.
- Do not retain recordings after export.

Clip should clearly show how much storage its history is using.

---

# Settings

The settings window contains the following sections.

## General

- Launch Clip at login.
- Show Clip in Dock.
- Global keyboard shortcuts.
- Countdown duration.
- Recording history retention.
- Default save location.

---

## Recording

- Default capture mode.
- Remember last selected area.
- Frame rate: 30 or 60 FPS.
- Show cursor.
- Default microphone state.
- Default system-audio state.
- Default microphone input.

---

## Export

- Default export preset.
- Default filename format.
- Automatically copy after stopping.
- Automatically close preview after copying.
- Keep original recording after export.
- Maximum target file size for Smallest mode.

---

## Storage

- Recording-history location.
- Current storage usage.
- Clear recording history.
- Automatic cleanup policy.

---

## Permissions

A dedicated permissions section shows status for:

- Screen Recording.
- Microphone.
- System Audio, where applicable.
- Accessibility, only if a future feature requires it.

Each permission should include a button that opens the relevant macOS System Settings page.

---

# Permissions onboarding

On first launch, Clip displays a short onboarding flow.

## Step 1

Explain what Clip does.

```text
Record a selected area of your screen and copy a compact video in seconds.
```

## Step 2

Request Screen Recording permission.

## Step 3

Optionally explain microphone and system-audio permissions.

## Step 4

Offer to configure the global shortcut and launch-at-login preference.

The application must use a permanent bundle identifier and stable development signature from the beginning so macOS permissions remain consistent across builds.

---

# Error handling

Clip must handle the following cases gracefully:

- Screen Recording permission denied.
- Microphone permission denied.
- A display disconnects during recording.
- The capture area becomes invalid.
- Available disk space becomes low.
- Encoding fails.
- The application quits unexpectedly.
- The selected clipboard destination rejects the file.
- A recording contains no frames.
- Audio and video input become unavailable.

Error messages should explain what happened and what the user can do next.

Raw technical errors should be available through a details or logs view but not shown as the primary message.

---

# Performance goals

Clip should target:

- Menu-bar popover opening instantly.
- Capture Mode appearing in under 300 milliseconds.
- Recording beginning immediately after the countdown.
- Minimal CPU use while idle.
- Hardware-accelerated capture and encoding.
- Preview available shortly after recording stops.
- Compact exports usually completing in under two seconds for short recordings.
- Stable long-running menu-bar behavior.
- No noticeable interference with the application being demonstrated.

---

# Privacy

Clip is local-first.

The MVP includes:

- No user account.
- No cloud upload.
- No analytics by default.
- No AI processing.
- No remote processing.
- No recording data leaving the Mac.

Any future telemetry must be optional and transparent.

---

# Accessibility

Clip should support:

- VoiceOver labels.
- Full keyboard navigation.
- Sufficient contrast.
- Reduced-motion preference.
- Adjustable shortcut bindings.
- Clear focus states.
- Menu items that can be activated without using the mouse.

---

# Technology stack

## Language

- Swift 6.

## User interface

- SwiftUI for:
  - Menu-bar popover.
  - Settings.
  - Preview controls.
  - Recording history.
  - Onboarding.

- AppKit for:
  - Capture overlays.
  - Transparent full-screen panels.
  - Floating preview windows.
  - Multi-display coordination.
  - Global keyboard handling.
  - Lower-level macOS window behavior.

## Capture

- ScreenCaptureKit.

Used for:

- Display capture.
- Region capture.
- Cursor capture.
- System audio.
- Efficient frame delivery.

## Video and audio

- AVFoundation.
- AVAssetWriter.
- AVPlayer.
- AVAssetExportSession where suitable.
- VideoToolbox where more direct hardware-encoding control is required.

## Persistence

- UserDefaults for user preferences.
- JSON metadata for the initial recording-history index.
- Files stored under the appropriate Application Support or Caches directories.

SQLite is not required for the MVP unless the recording-history model grows significantly.

## Package management

- Swift Package Manager.

External dependencies should be kept to a minimum.

## Development environment

- Source editing can be done in Codex, Cursor, VS Code, Zed, or another editor.
- Xcode and Apple command-line tools remain installed for SDKs, signing, building, and distribution.
- The project should support command-line builds.


---

# Distribution

Clip will be distributed as a proper signed macOS application.

Primary distribution:

```text
Clip.dmg
```

or:

```text
Clip.zip
```

Installation:

```text
Download
→
Move Clip.app to Applications
→
Open Clip
→
Grant Screen Recording permission
```

Release requirements:

- Permanent bundle identifier.
- Apple Development signing during development.
- Developer ID Application signing for release.
- Hardened Runtime.
- Apple notarization.
- Stapled notarization ticket.
- Testing on a separate Mac or clean user account.

Homebrew is optional.

A later Homebrew Cask may allow:

```bash
brew install --cask clip
```

The main source repository should simply be named:

```text
clip
```

A separate Homebrew tap can be added later if needed.

---

# MVP feature list

## Included in version 1.0

- Native menu-bar application.
- Capture Area mode.
- Last Area preset.
- Fullscreen capture.
- Per-display capture.
- Multi-display support.
- Movable and resizable selection rectangle.
- Menu-bar recording controls.
- Configurable global shortcuts.
- Configurable countdown.
- 30 FPS recording.
- Optional 60 FPS.
- Cursor visibility option.
- Microphone capture.
- System-audio capture.
- Pause and resume.
- Cancel recording.
- Floating preview.
- Playback.
- Trim beginning and end.
- Compact MP4 export.
- Crisp export preset.
- Smallest export preset.
- Copy video file to clipboard.
- Save As.
- Reveal in Finder.
- Recent local recording history.
- Automatic history cleanup.
- Launch at login.
- Permission onboarding.
- Signed and notarized distribution.

---

# Deferred features

Potential later additions:

- Saved named capture regions.
- Individual-window capture.
- GIF export.
- Webcam bubble.
- Click animations.
- Keystroke visualization.
- Blur regions.
- Simple annotations.
- Automatic maximum-file-size encoding.
- Drag-and-drop export from the preview.
- Optional upload destinations.
- Homebrew Cask.
- Automatic application updates.

These features should only be added if they support the core workflow without turning Clip into a general-purpose video editor.

---

# Explicit non-goals

Clip will not initially provide:

- Screenshot capture.
- Scrolling screenshots.
- Full video editing.
- Multi-clip timelines.
- Cloud accounts.
- Team workspaces.
- Collaboration.
- Comments.
- Hosted video links.
- AI features.
- Transcription.
- Automatic zoom effects.
- Windows or Linux versions.
- A browser extension.
- Watermarks.

---

# Product identity

## Name

**Clip**

## Application name

```text
Clip.app
```

## Executable

```text
Clip
```

## Repository

```text
clip
```

## Positioning

> Quick screen recordings for sharing your work.

## Core promise

> Select, record, copy, paste.

## Primary audience

- Software developers.
- Product designers.
- QA engineers.
- Product managers.
- Support engineers.
- Anyone who regularly shares short interface demonstrations.

## Typical use cases

- Showing a newly developed feature.
- Demonstrating a bug.
- Attaching reproduction steps to a GitHub issue.
- Sharing progress in Slack.
- Recording an interaction for a pull request.
- Showing a UI state to a designer or colleague.
- Creating a short silent product demo.

---

# Recommended implementation order

## Phase 1 — Application foundation

- Create Clip.app.
- Add the menu-bar icon.
- Set the permanent bundle identifier.
- Establish stable signing.
- Request and retain Screen Recording permission.
- Produce a signed and notarized test release.

## Phase 2 — Capture

- Enumerate displays.
- Implement fullscreen recording.
- Implement rectangular selection.
- Add Last Area.
- Write H.264 MP4 output.
- Add recording controls.

## Phase 3 — Preview and sharing

- Build the preview window.
- Add playback.
- Add start and end trimming.
- Add Copy Video.
- Add Save As.
- Add export presets.

## Phase 4 — Audio and history

- Add microphone capture.
- Add system audio.
- Add recent recordings.
- Add cleanup and retention.

## Phase 5 — Polish

- Improve multi-display behavior.
- Add launch at login.
- Complete accessibility.
- Improve error handling.
- Optimize file size and export performance.
- Prepare the public release.

This specification is narrow enough for a strong first release while leaving clear room for later improvements.
