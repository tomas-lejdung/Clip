Here is the finalized product specification for **Clip**.

# Clip — Product Specification

## Product summary

**Clip** is a lightweight native macOS screen recorder for creating short, compact product and development demos.

Its primary workflow is:

1. Choose an area of the screen, an application, or a display.
2. Record a short demonstration.
3. Trim the beginning or end.
4. Drag the video from the preview, or copy a compact MP4.
5. Drop or paste it directly into Slack, GitHub, Linear, Discord, or another application.

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
- Launch at login is Off but may be enabled in Settings.
- Clip follows the current macOS light or dark appearance.
- Version 1.0 is English-only and uses a String Catalog so later localization remains straightforward.

Clicking the menu-bar icon opens the main Clip popover.

---

## Menu-bar popover

The default popover contains:

```text
Capture Area…
Capture App…
Last Area
Fullscreen
Display 1
Display 2

Microphone        Off
System Audio      Off
Click Highlights  Off

● Record

Recent Recordings
Settings
Quit Clip
```

Unavailable options should be hidden. For example, `Display 2` should only appear when a second display is connected.

Every clickable popover row must show immediate hover feedback and use the
pointing-hand cursor so the action about to be selected is unambiguous.

Clip remembers:

- The most recently used capture mode.
- The most recently selected area.
- Audio settings.
- Click-highlight visibility.
- Frame-rate preference.
- Export preset.

The floating Preview remains visible when Clip deactivates or Capture Mode
starts. A Preview that is already open does not block a new selection or
recording and is not closed when capture begins. After the new recording has
been safely imported, Clip persists and replaces the old Preview. If the old
Preview is still completing Copy, Save As, or another operation, the new
recording remains safe in History and Clip reports that Preview opening was
deferred; it must never report that the completed recording failed.

Choosing **Quit Clip** immediately closes the popover and all Clip-owned
windows and overlays, removes the menu-bar item, stops UI-producing background
work, and prevents late startup or capture tasks from reopening UI. Clip then
gets a best-effort grace period of at most eight seconds to finalize an active
recording, persist Preview state, and release managed sessions. An in-flight
first video frame is offered to the capture writer for authoritative
finalization rather than being discarded merely because its UI event is still
queued. AppKit receives exactly one termination reply. If cleanup does not
finish within the grace period, Clip exits without leaving frozen UI and uses
its durable capture/history recovery state on the next launch.

---

# Capture modes

## Capture Area

Choosing **Capture Area…** activates Capture Mode.

During Capture Mode:

- All connected displays are covered by transparent selection overlays.
- The screen outside the selected region is dimmed.
- The cursor becomes a crosshair.
- The user draws a rectangular capture region by pressing at one corner and
  smoothly dragging to the opposite corner.
- A new region begins at the exact mouse-down position and follows the pointer;
  Clip does not create an initial minimum-sized rectangle or warp the pointer.
- The selected region remains undimmed.
- The region displays resize handles.
- The region can be moved or resized before recording begins.
- A capture region belongs to exactly one display and cannot span display boundaries.
- Dragging or resizing is constrained to the selected display.

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
Tab        Move focus between the region, handles, and toolbar
Arrow keys Move the focused region or resize the focused handle by 1 pixel
Shift      Increase keyboard movement to 10 pixels; preserve aspect ratio while dragging
```

The toolbar must position itself outside the selected region whenever possible so that it does not cover the content being recorded.
The Cancel and Record buttons use the pointing-hand cursor; the surrounding
selection surface continues to use the capture crosshair and resize/move
cursors appropriate to its current interaction.

---

## Last Area

The **Last Area** preset immediately restores the most recently used capture rectangle.

It reopens Capture Mode with that rectangle ready for adjustment; it does not begin recording automatically.

This is particularly important for repeated recordings of:

- A browser viewport.
- An application preview.
- An iOS Simulator.
- A fixed section of an ultrawide display.
- A development environment.

The region is stored using its display identity and normalized coordinates.

If the original display is unavailable, Clip moves and clamps the region to the main display, then allows the user to adjust it before recording.

---

## Capture App

Choosing **Capture App…** opens an application-selection overlay on every
connected display.

- Moving the pointer over a visible application highlights all of that
  application's visible windows on that display.
- Clicking selects the application under the pointer. The user confirms with
  Record or Return; double-click may confirm immediately.
- Clip records the union of all visible windows belonging to the selected
  application on the clicked display. It does not capture only the single
  window that was clicked, and it does not include that application's windows
  from other displays.
- Clip's own windows and selection UI remain excluded.
- Escape and Cancel leave application selection without starting a recording.
- The selected application and display are stored as the durable target so
  Retake can resolve the application again when it is still available.

Individual-window capture remains outside the v1 scope.

---

## Fullscreen

The **Fullscreen** preset records an entire display.

If multiple displays are connected, the user selects the display before recording.

Fullscreen includes the display's menu bar and Dock. Clip's own windows, popovers, overlays, and sounds are excluded from every capture mode.

---

## Display presets

The menu-bar popover lists connected displays, such as:

```text
Display 1 — 5120 × 1440
Display 2 — 2560 × 1440
```

Selecting a display prepares it as the capture target.

Selecting a display does not immediately begin recording. The user starts the countdown with the Record button, Return key, or configured global shortcut.


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

The countdown is visual and silent. Settings offers Off, 1, 3, and 5 seconds.

---

# Recording state

While recording:

- The Clip menu-bar icon changes to indicate an active recording.
- The elapsed recording time is visible in the menu-bar popover.
- The app remains usable without showing a floating controller over the recording.
- For Capture Area, the selected rectangle remains visible as a clear,
  click-through border while recording.
- The rest of the screen is no longer dimmed once recording begins.
- The border is a Clip-owned, capture-excluded overlay and therefore does not
  appear in the resulting video.

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

The three global shortcuts for Capture, Finish, and Pause or Resume are configurable. Contextual keyboard controls inside Capture Mode remain fixed.

---

# Recording controls

Clip has no hard recording-duration limit. It is optimized for short clips and should support recordings of at least 30 minutes, stopping early only when capture cannot safely continue.

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

Recordings three seconds long or shorter may be discarded immediately. Longer recordings require confirmation.

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

The MVP uses the current system-default microphone input device. Settings may show its name as read-only status.

Explicit microphone-device selection may be added later.

When both microphone and system audio are enabled, the managed recording master
retains the two source tracks independently. Drag, Copy, and Save As exports mix
them into one broadly compatible AAC audio track. If an audio source becomes
unavailable, video recording continues with the remaining sources and Clip
reports the change.

---

# Video capture

## Default recording configuration

The default recording configuration is:

- MP4 container.
- Hardware H.264 video when the selected native dimensions are supported;
  otherwise an exact-size hardware HEVC managed master. Shared exports remain
  H.264.
- 30 frames per second.
- Native capture dimensions derived from the selected pixel area; there is no
  fixed 1,080p or 4K capture envelope.
- Hardware-accelerated encoding.
- A quality-based master using the current Crisp quality setting. The
  default user-facing value is `98`, passed to VideoToolbox as `0.98`; Clip
  does not set an average bitrate or hard data-rate limit.
- SDR Rec.709 color for predictable sharing compatibility.
- Cursor visible.
- No audio unless enabled.
- No webcam.
- Click highlights off unless enabled.
- No keystroke overlay.

An optional 60 FPS capture mode is available in settings. Every export preset
preserves the recording's durable capture cadence and exact eligible sample
timing; export never interpolates or deliberately decimates frames.

---

## Cursor and click highlights

The user can choose whether the cursor is visible in recordings.
The user can also enable ScreenCaptureKit's native click highlights, which
draw a visible click indicator into the recorded video. Cursor visibility and
click highlights are independent choices; Clip does not require Accessibility
permission or synthesize a custom cursor overlay.

Default:

```text
Show cursor: On
Click highlights: Off
```

The menu-bar popover exposes Click Highlights as a persistent quick toggle
alongside Microphone and System Audio. The selected value is frozen into each
recording session and its History snapshot, and Retake restores that value.
Custom cursor enlargement and non-native cursor effects are not part of the MVP.

---

# Preview and editing

When recording stops, Clip opens a compact floating preview window.

The preview contains:

- Video playback in a top preview surface that acts as the exported-file drag source.
- Play and pause.
- Current time.
- Total duration.
- A simple timeline below the video preview.
- Trim handles for the beginning and end.
- An editable filename.
- Quality-based size status.
- Export preset.
- A **Remove audio** switch when the recording contains audio.
- Delete, Retake, Save As, and Copy actions below the timeline and export details.

Dragging the video preview drags the current trimmed and exported MP4 as a file. The timeline itself remains dedicated to seeking and trimming and is not the file drag source.

Before export, Preview says `Quality based — size varies` for every preset.
After a successful Drag, Copy, or Save As operation, it shows the actual output
size. Changing trim, preset, quality, or Remove audio clears the prior result
until the next export; Clip does not present a predicted or guaranteed size.

Example:

```text
┌─────────────────────────────────────┐
│                                     │
│      Video preview · drag file       │
│                                     │
├─────────────────────────────────────┤
│ |◀──────────────────────────────▶|  │
│ 00:02                         00:24  │
│                                     │
│ clip-20260717-104218.mp4             │
│ Crisp · Quality based — size varies │
│                                     │
│ Delete   Retake   Save As…   Copy   │
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
- Renaming the recording and exported file.
- Removing or restoring all recorded audio for playback and exported files.
- Dragging the video preview to another application as an MP4 file.

Retake reuses the previous target, audio, and countdown settings. Clip keeps the previous recording until the replacement succeeds, then discards the old draft.

**Remove audio** is a non-destructive, per-recording Preview/export choice. It
is Off by default for both new recordings and history created before the field
existed. Turning it On mutes Preview playback immediately, removes the audio
track from Drag, Copy, and Save As output. Turning it Off restores playback and
exported audio.
The choice persists through Done, sharing, History, Preview reopen, and app
relaunch. It never removes or rewrites audio in the managed recording master.

The MVP does not support:

- Splitting clips.
- Joining recordings.
- Text overlays.
- Shapes or arrows.
- Blur regions.
- Zoom effects.
- Transitions.
- Speed changes.
- Audio-level, per-source, or timeline audio editing.
- Multi-track editing.

---

# Export and sharing

Clip has two equally supported sharing actions: dragging the video preview and selecting **Copy**. There is no automatic-copy-after-stopping feature or setting.

## Drag video

Dragging the top video preview supplies an MP4 file using the current trim,
export preset, editable filename, and Remove audio choice. The file can be
dropped into Finder or another application that accepts file drags. The drag
payload advertises both the MPEG-4 representation and the resulting local file
URL so Finder and browser upload targets can consume it directly. Every
destination receives the current edited filename; macOS must not substitute a
generic name such as `MPEG-4 movie.mp4`.

## Copy

When **Copy** is selected, Clip:

1. Applies the selected trim.
2. Encodes or remuxes the recording as needed.
3. Applies the recording's current Remove audio choice and produces a compact
   MP4, with no audio track when removal is selected.
4. Places the resulting file URL on the macOS clipboard.
5. Shows a completion confirmation.

Example:

```text
✓ Video copied — 5.8 MB
```

The user should then be able to paste the video directly into applications that accept copied files, including:

- Slack.
- GitHub issues and pull requests.
- Linear.
- Discord.
- Messages.
- Mail.
- Finder.
- Other applications that accept copied files.

Clip considers the operation successful when it has written a valid, readable MP4 file to the pasteboard. macOS does not tell Clip whether a different application later accepted or rejected a paste.

---

## Save As

The user can save the exported recording to a chosen location. Save As uses the
same trim, preset, filename, and Remove audio choice as Drag and Copy.

The default filename format is:

```text
clip-20260717-104218.mp4
```

The filename is editable in Preview and History. The `.mp4` extension is preserved automatically. Save As creates an independent external file that Clip never removes through history cleanup.

The default format is editable in Export Settings. It supports the
case-sensitive fixed-width tokens `YYYY`, `MM`, `DD`, `HH`, `mm`, and `ss`,
shows a live example, and rejects formats that could produce an unsafe path or
invalid MP4 filename. Existing settings created before this option migrate to
the default format above.

Save As always uses the standard macOS Save panel. Choosing a destination such
as Downloads grants Clip access to that exact output URL through the App
Sandbox Powerbox; Clip must not fail merely because the destination is outside
its container, and it must not request broad permanent access to the parent
folder. Canceling the panel makes no filesystem change.

---

## Reveal in Finder

After export or save, the user can reveal the file in Finder.

---

# Export presets

Clip exposes three independently configurable quality presets instead of
bitrate, resolution, frame-rate, or target-size controls. Every preset keeps the
managed master's native encoded dimensions, aspect ratio, durable capture
cadence, H.264 High profile, Rec.709 color, and 128 kbps AAC export policy. The
only user-controlled video-encoding parameter is quality. Hardware H.264
receives that normalized value directly. For exact dimensions outside Apple's
hardware H.264 envelope, its native software H.264 encoder does not support a
quality property, so Clip maps the same value to a resolution/FPS-scaled soft
average bitrate. It never adds a hard data-rate limit or target file size.

Settings presents each value as an independent integer from 1 through 100 and
passes it to VideoToolbox on its normalized 0 through 1 scale. Clip does not
reorder or constrain the three values. **Reset Quality Defaults** restores
Crisp `98`, Compact `90`, and Smallest `70`.

An unchanged, full-duration Crisp export may atomically reuse the managed
master byte-for-byte when its recorded quality and audio layout already match
the requested output. Trimming, changing Crisp quality, audio mixing, or
removing existing audio requires the native offline transcode path. Compact and
Smallest are offline quality-based exports rather than source-reuse modes.

## Compact

Middle quality rung for ordinary sharing.

Designed for:

- Slack.
- GitHub.
- Linear.
- Short product demos.
- Bug reports.

Behavior:

- Preserves the managed master's native dimensions and durable cadence.
- Uses H.264 High profile at the independently configurable quality value;
  default `90` (`0.90` internally).
- Uses direct VideoToolbox quality when hardware H.264 supports the exact
  dimensions; otherwise uses the native software encoder's derived soft
  average-bitrate fallback without a hard limit.
- Uses offline quality-oriented encoding.

---

## Crisp

Designed for recordings where fine interface detail matters.

Default preset.

Behavior:

- Preserves the managed master's native dimensions and durable cadence.
- Uses H.264 High profile at the independently configurable quality value;
  default `98` (`0.98` internally).
- Uses direct VideoToolbox quality when hardware H.264 supports the exact
  dimensions; otherwise uses the native software encoder's derived soft
  average-bitrate fallback without a hard limit.
- Reuses a compatible untrimmed master byte-for-byte instead of introducing a
  second lossy encode.
- Otherwise uses offline quality-oriented encoding.

---

## Smallest

Lowest default quality rung for smaller ordinary sharing files.

Behavior:

- Preserves the managed master's native dimensions and durable cadence.
- Uses H.264 High profile at the independently configurable quality value;
  default `70` (`0.70` internally).
- Uses direct VideoToolbox quality when hardware H.264 supports the exact
  dimensions; otherwise uses the native software encoder's derived soft
  average-bitrate fallback without a hard limit or target file size.
- Uses offline quality-oriented encoding.

Smallest is a relative preset name, not a promise that an export will fit a
particular upload limit. Content complexity determines the resulting size.

---

# Recent recordings

Clip maintains a small local recording history.

The menu-bar popover shows recent recordings:

```text
Recent Recordings

clip-20260717-104218      3.8 MB
dashboard-filters        7.1 MB
mobile-navigation        2.4 MB
```

New recordings use the timestamp filename by default. The user may rename them in Preview or History.

Each recording supports:

- Preview.
- Rename.
- Copy.
- Save.
- Reveal in Finder.
- Delete.

The full History window uses native **Recordings** and **Exports** tabs.
Recordings show any still-live Copy or drag exports linked to that source as
compact chips below the row; each chip can be revealed in Finder or deleted.
The Exports tab inventories every still-live Copy and drag export, shows its
quality, size, and source relationship, and supports Reveal, individual Delete,
and Delete All. If the source recording has been removed, its export remains in
the Exports tab with a visible **Source deleted** state and is no longer shown
under a recording row.

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

## History storage model

- A history item is created when a recording successfully stops.
- Clip keeps the managed original plus non-destructive trim, preset, filename,
  and per-recording Remove audio metadata.
- Copy and drag create managed temporary exports.
- Save As creates an independent external file that Clip never deletes.
- Only exports actually published by Copy or drag appear in the Exports tab;
  an internal cache file produced while completing Save As is not listed.
- Recording retention, recording deletion, and Clear History remove managed
  masters but retain live Copy and drag exports. Those exports can be removed
  independently from the Exports tab and otherwise expire through the
  ownership-aware seven-day cache cleanup.
- Cleanup age is based on recording creation time.
- The history location is fixed under Application Support and can be revealed but not relocated.
- **Keep original recording after export** defaults to On. When Off, Clip replaces the managed master with the trimmed exported result after a successful export and records that replacement's quality separately from the original Retake settings.
- **Do not retain recordings after export** removes the history item after successful Copy, drag, or Save As while keeping clipboard and drag temporary files available long enough for their receiving application to consume them.

---

# Settings

The settings window contains the following sections.

The first presentation explicitly selects **General** and must render every visible label,
control, and current value immediately. Opening Settings must not depend on leaving and
returning focus to complete SwiftUI layout or drawing.

General, Recording, Export, Storage, and Permissions are presented as an always-visible
native macOS top tab bar. They must not collapse into a toolbar overflow button at the
supported initial window size. Clip does not draw a custom segmented selector or glass
backdrop for these tabs; the system `TabView` supplies the current native appearance,
including Liquid Glass where macOS applies it. Forms scroll vertically when their contents
exceed the window; controls and labels remain single-line where practical.

## General

- Launch Clip at login.
- Show Clip in Dock.
- Default capture mode.
- Remember last selected area.
- Global keyboard shortcuts.

---

## Recording

- Frame rate: 30 or 60 FPS.
- Countdown duration.
- Show cursor.
- Show click highlights.
- Default microphone state.
- Default system-audio state.
- Current system-default microphone name, shown read-only.

---

## Export

- Default export preset.
- Independent integer quality values from 1 through 100 for Crisp, Compact,
  and Smallest, each shown in a clearly bordered single-line numeric field.
- Reset Quality Defaults, restoring `98`, `90`, and `70` respectively.
- Default filename format in a clearly bordered editable field. The editor contains only
  the filename template stem; a fixed, non-editable `.mp4` suffix is shown beside it and
  appended automatically. The field's accessible label must not also render as duplicate
  visible prompt text.
- Automatically close preview after copying.
- Keep original recording after export.
- Default Save As location.

---

## Storage

- Recording-history location, shown read-only with Reveal in Finder.
- Current storage usage.
- Clear recording history.
- Recording history retention and automatic cleanup policy.

---

## Permissions

A dedicated permissions section shows status for:

- Screen Recording.
- Microphone.
- System Audio, where applicable.

Each permission should include a button that opens the relevant macOS System Settings page.

## Initial defaults

- Launch at login: Off.
- Show in Dock: Off.
- Capture mode: Capture Area.
- Remember Last Area: On.
- Frame rate: 30 FPS.
- Show cursor: On.
- Click highlights: Off.
- Microphone: Off.
- System audio: Off.
- Countdown: a silent 3 seconds, with Off, 1, 3, and 5-second choices.
- History retention: 7 days.
- Export preset: Crisp.
- Export qualities: Crisp `98`, Compact `90`, Smallest `70`.
- Automatically close preview after Copy: Off.
- Keep original after export: On.
- Default Save As location: `~/Movies`.
- Canonical/output filename format: `clip-YYYYMMDD-HHmmss.mp4`; the Settings editor shows
  `clip-YYYYMMDD-HHmmss` with the protected `.mp4` suffix beside it.
- Appearance: the current macOS light or dark appearance.

---

# Permissions onboarding

On first launch, Clip displays a short onboarding flow.

## Step 1

Explain what Clip does.

```text
Record a selected area of your screen, then drag or copy a compact video in seconds.
```

## Step 2

Request Screen Recording permission.

## Step 3

Optionally explain microphone and system-audio permissions.

## Step 4

Offer to configure the global shortcut and launch-at-login preference.

The application uses the permanent bundle identifier `com.tomaslejdung.clip`. The owner's local release is signed with the Apple Development certificate from free Personal Team `FJ2BS65H3F`; a paid Apple Developer membership is not required for this local-only workflow. This gives rebuilds a stable macOS privacy identity. Permission-free CI may still use ad-hoc signing, but those builds can require fresh approvals whenever their code identity changes.

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
- Clip cannot place a valid, readable MP4 file URL on the clipboard.
- A recording contains no frames.
- Audio and video input become unavailable.

When a display disappears, disk space becomes critical, or capture fails, Clip should safely finalize and preserve playable material where possible. Interrupted recordings should be recovered on the next launch where technically possible. Protected or DRM-controlled screen and audio content may remain unavailable by macOS design.

Clip may offer troubleshooting when another application does not accept a paste or drop, but it cannot observe or report that destination application's result.

Error messages should explain what happened and what the user can do next.

Raw technical errors should be available through a details or logs view but not shown as the primary message.

---

# Performance goals

Clip should target:

- Menu-bar popover opening instantly.
- Capture Mode appearing with p95 latency under 300 milliseconds.
- Recording beginning immediately after the countdown.
- Minimal CPU use while idle.
- Hardware-accelerated capture and encoding.
- Preview available in under one second after recording stops.
- Always-offline Compact-90 exports usually completing in under two seconds for a 30-second, 1440 × 900, 30 FPS fixture on the development Mac.
- Trim timing accurate to within one frame.
- Audio and video synchronization within 50 milliseconds, including across pause and resume.
- A ten-minute real recording soak test plus longer synthetic state and writer tests.
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

# Technology stack

## Language

- Swift 6 language mode using Apple Swift 6.3.3.

## Target platform

- Xcode 26.6, build 17F113.
- macOS 15.0 or later deployment target.
- Apple Silicon (`arm64`).
- Version 1.1.0.

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
- Native click highlighting.
- System audio.
- Efficient frame delivery.

## Video and audio

- AVFoundation.
- AVAssetWriter for MP4 muxing and AAC audio encoding.
- AVPlayer.
- VideoToolbox for direct hardware H.264/HEVC master encoding and native H.264
  export controls.
- Native hardware H.264/HEVC master encoding and H.264/AAC sharing only; Clip
  does not bundle or invoke FFmpeg or another media binary.

### Capture-quality contract

- Capture Area and Capture App rectangles are snapped to the display's physical-pixel grid. One exact even-sized geometry is used for the ScreenCaptureKit source rectangle, stream output, video encoder, History metadata, and MP4 dimensions.
- Every complete incoming video pixel buffer is checked against the configured width and height before encoding. A mismatch stops with a visible recording error; Clip never silently rescales a capture frame.
- Raw ScreenCaptureKit pixel buffers are transient. They are submitted directly to a `VTCompressionSession`; Clip retains at most the latest frame in memory for bounded cadence repair and stores only compressed H.264 or HEVC MP4 media.
- The live master encoder uses H.264 High or HEVC Main profile,
  `RealTime = true`, the current Crisp quality setting (default `0.98`),
  quality-over-speed priority, no average bitrate or hard data-rate limit, no
  frame reordering, and a two-second keyframe interval.
- Clip requires hardware encoding for live capture. It prefers H.264 when
  VideoToolbox supports the exact native dimensions and falls back to
  exact-size hardware HEVC when H.264 rejects an oversized mode such as a
  5,120-pixel-wide display. Clip never uses a software encoder for real-time
  capture and never downscales this fallback.
- AVAssetWriter receives VideoToolbox's compressed H.264 or HEVC samples through a passthrough input and only muxes them with native AAC audio into MP4; it does not perform another video encode.
- Brief encoder or muxer pressure is bounded and queued. Sustained pressure or a VideoToolbox-dropped frame ends capture with an error instead of silently creating a cadence gap.
- A short complete-frame delivery gap above two and no more than three nominal frame intervals is bridged with one held copy of the prior frame at the next nominal timestamp. Every original sample timestamp and duration remains unchanged; longer ordinary gaps remain native variable-frame-rate timing, while an excessive first-post-resume gap is a visible error.

### Export-quality contract

- An unchanged full-duration Crisp export with compatible audio reuses a
  compatible H.264 managed master byte-for-byte. An HEVC managed master is
  transcoded offline so every shared export remains H.264.
- Crisp, Compact, and Smallest otherwise encode offline with their independent
  Settings quality values (defaults `0.98`, `0.90`, and `0.70`), frame
  reordering enabled, and no hard data-rate limit. Hardware-supported H.264
  uses VideoToolbox quality directly. Exact oversized software H.264 maps the
  same quality value to a soft average bitrate because Apple's encoder rejects
  the quality property at those dimensions.
- All three presets preserve native dimensions and the durable per-recording
  30/60 FPS cadence ceiling. Exact eligible sample timestamps are preserved; a
  measured variable rate such as 28.29 FPS is never rounded down into an
  accidental 28 FPS export.
- Trim, audio mixing, and audio removal are applied in one export generation.
- Every transcoded export uses the same 128 kbps AAC policy when audio is kept.
- Before every export, Preview says `Quality based — size varies`; after a
  successful share it shows the actual file size.

## Persistence

- Versioned JSON under Application Support for user preferences, with atomic replacement and backward-compatible defaults.
- Versioned JSON metadata for the initial recording-history index.
- Managed recording masters and metadata under Application Support.
- Temporary clipboard, drag, and intermediate export files under Caches.

SQLite is not required for the MVP unless the recording-history model grows significantly.

## Package management

- Swift Package Manager.

Sparkle 2 is the sole third-party runtime dependency and is pinned to an exact
version through Swift Package Manager. It is used only for application update
discovery, download, verification, installation, and relaunch. Clip bundles no
third-party media encoder or other media runtime. Test-only dependencies should
also be avoided unless they materially improve deterministic verification.
Publishable DMGs resolve that exact Sparkle revision and its reviewed binary
checksum in a fresh isolated package cache; ignored development-package state
is not accepted as release provenance.

## Development environment

- Source editing can be done in Codex, Cursor, VS Code, Zed, or another editor.
- Xcode 26.6 and Apple command-line tools provide the macOS 26.5 SDK, Swift 6.3.3, local signing, building, and DMG creation.
- The project should support command-line builds.

## Security configuration

- App Sandbox enabled.
- Hardened Runtime enabled.
- Entitlements limited to the capabilities Clip actually uses, including microphone input and user-selected file access.
- Clip uses its outbound network entitlement only for the Sparkle update feed
  and release download path; the sandboxed Sparkle installer receives only its
  documented installer-service and mach-lookup exceptions.
- No Accessibility permission is requested.


---

# Distribution

Clip is a personally maintained direct-download application distributed from
the public GitHub repository's Releases page. It is not an App Store release.

The distribution artifact is:

```text
Clip.dmg
```

Installation:

```text
Open Clip.dmg
→
Move Clip.app to Applications
→
Open Clip
→
Grant Screen Recording permission
```

Release requirements:

- Permanent bundle identifier `com.tomaslejdung.clip`.
- Local Apple Development signing with Personal Team `FJ2BS65H3F`, preserving one privacy identity across rebuilds.
- Hardened Runtime.
- App Sandbox.
- A DMG containing a launchable `Clip.app` with an Applications shortcut.
- A Sparkle EdDSA-signed update enclosure using the immutable, tag-specific
  GitHub Release DMG URL and a one-item appcast hosted by GitHub Pages.
- Mount, copy, launch, record, export, drag, clipboard, and remount smoke testing on the development Mac.

The first Sparkle-enabled Clip build is a bootstrap release and must be
downloaded and installed manually from its DMG. Builds installed before the
updater exists cannot discover it. After that bootstrap install, Clip checks
the signed appcast periodically and presents an available update through the
native Sparkle flow. **Check for Updates…** in the menu-bar popover performs the
same check on demand. Update installation downloads the signed full DMG,
relaunches Clip, and preserves the existing Settings and History directories.

The DMG is Apple Development signed for local use, not Developer ID signed or notarized. If the artifact later receives a quarantine attribute through download, messaging, or AirDrop, macOS may require a one-time **Open Anyway** approval in Privacy & Security.

Mac App Store distribution, Homebrew, Developer ID signing, and notarization
are outside the current scope.

The main source repository should simply be named:

```text
clip
```

A separate Homebrew tap can be added later if needed.

---

# Testing strategy and platform limitations

- All automated tests run locally on the development Mac; no CI service or separate test machine is required.
- Unit, integration, state-machine, media, and UI tests use injected services and deterministic synthetic frames and audio where practical.
- `--ui-scenario=<name>` fixtures are honored only with `--ui-testing`. They use isolated defaults and storage plus inert permission, audio, capture, display, pasteboard, shortcut, and external-AppKit actions; they never request privacy access or enter the real-capture lane.
- Deterministic launch fixtures cover onboarding, the populated menu-bar popover and displays, denied permissions, recording, paused recording, Preview, History, every Settings tab, and a representative failure surface. Their UI-automation assertions compile in the permission-free suite but execute only after an explicit visible-pointer-control opt-in.
- A pointer-free hosted visual lane renders the production Settings window at the top and fully scrolled bottom of every tab, writes ten PNGs plus scroll-position metadata, and fails if a scrollable form does not reach its bottom.
- Real ScreenCaptureKit, microphone, system-audio, clipboard, drag, Save As, history, and DMG smoke tests run on the development Mac.
- Application-update verification checks the embedded feed URL/public key,
  sandbox services and entitlements, nested code signatures, exact app/build
  versions, immutable enclosure URL, archive length, and Sparkle EdDSA
  signature. Once two updater-enabled releases exist, final acceptance installs
  an older build and exercises automatic discovery plus **Check for Updates…**
  through download, install, relaunch, and Settings/History preservation.
- The owner performs the required one-time Screen Recording, System Audio, and Microphone approvals. Test runs after approval should be unattended.
- Multi-display topology, display disconnection, and deterministic loopback-audio cases are simulated when the necessary hardware is unavailable.
- There is no automated Slack, GitHub, Linear, Discord, Messages, or Mail integration suite. A local receiver and Finder validate file drag and clipboard contracts; an agent-driven check in an explicitly authorized application may be performed without sending content.
- There is no dedicated accessibility or human subjective visual-quality audit for this personal local release. Deterministic screen-content fidelity is automated with small text, one-pixel rules, saturated edges, scrolling, and 30/60 FPS motion.
- Automated acceptance at the default `98`/`90`/`70` values requires no
  scaling, master luma SSIM of at least 0.985 with at least 95% edge retention,
  Crisp SSIM of at least 0.98 with at least 92% edge retention, Compact-90 SSIM
  of at least 0.96 with at least 85% edge retention, and no video gap beyond
  two frame intervals.
- A fresh-account privacy grant cannot be automated through supported macOS behavior.
- Clipboard and drag temporary files must remain available long enough for receiving applications to consume them and therefore cannot be removed immediately after export.
- The two-second export goal applies only to the defined performance fixture, not arbitrary native-resolution 5K/60 FPS recordings.

---

# MVP feature list

## Included in the current version

- Native menu-bar application.
- Capture Area mode.
- Capture App mode for all visible windows of the clicked application on the selected display.
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
- Native click-highlights option, with menu-bar quick toggle.
- Microphone capture.
- System-audio capture.
- Pause and resume.
- Cancel recording.
- Floating preview.
- Playback.
- Trim beginning and end.
- Editable timestamp-based filename.
- Rename in Preview and History.
- Non-destructive Remove audio in Preview, persisted for History and exports.
- Compact MP4 export.
- Crisp export preset.
- Smallest export preset.
- Drag the exported MP4 from the video preview.
- Explicit Copy button that places the MP4 file on the clipboard.
- Save As.
- Reveal in Finder.
- Recent local recording history.
- Automatic history cleanup.
- Launch at login.
- Permission onboarding.
- Local launchable DMG distribution.
- Signed application updates from immutable GitHub Release DMGs, with periodic
  automatic checks and an on-demand **Check for Updates…** action.

The release-critical path is: install and launch from DMG → select → record → preview → trim → drag or copy. Other included items remain planned for v1 and should be completed where feasible, but they do not prevent validating the core workflow incrementally.

---

# Deferred features

Potential later additions:

- Saved named capture regions.
- Individual-window capture.
- GIF export.
- Webcam bubble.
- Custom click animations beyond the native system click-highlight rings.
- Keystroke visualization.
- Blur regions.
- Simple annotations.
- Automatic maximum-file-size encoding.
- Explicit microphone-device selection.
- Optional upload destinations.
- Homebrew Cask.
- Universal Intel support and native Intel validation.
- Developer ID signing and notarization.

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
- Mac App Store distribution.
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

## Version

```text
1.1.0
```

## Bundle identifier

```text
com.tomaslejdung.clip
```

## Copyright

```text
Copyright © 2026 Tomas Lejdung. All rights reserved.
```

The local release uses free Personal Team ID `FJ2BS65H3F`. It is not a Developer ID or App Store release.

## Positioning

> Quick screen recordings for sharing your work.

## Core promise

> Select, record, trim, drag or copy.

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
- Establish stable local Apple Development signing, an ad-hoc CI fallback, and the sandbox entitlements.
- Request and retain Screen Recording permission.
- Produce and launch a test DMG on the development Mac.

## Phase 2 — Capture

- Enumerate displays.
- Implement fullscreen recording.
- Implement rectangular selection.
- Implement application selection and all-visible-window application capture.
- Add Last Area.
- Write H.264 MP4 output.
- Add recording controls.

## Phase 3 — Preview and sharing

- Build the preview window.
- Add playback.
- Add start and end trimming.
- Add editable filenames and rename.
- Add non-destructive Remove audio playback/export state.
- Make the top video preview the exported-file drag source.
- Add Copy.
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
- Improve error handling.
- Optimize file size and export performance.
- Produce and verify the local launchable DMG.

This specification is narrow enough for a strong first release while leaving clear room for later improvements.
