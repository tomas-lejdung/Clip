# Production recording pipeline

The production flow captures full backing pixels with hardware HEVC at a
10 Mbps average target, then processes once to H.264 with software x264. The
initial settings are Native resolution and CRF 24. This is the recipe approved
in the real recording prototype; the prototype and alternate encoding flows
have been removed.

## What the user sees

1. **Stop opens the existing Preview immediately.** The native window and timeline
   remain the product's editing surface. A material-backed progress overlay
   describes finalization, processing, and validation. Playback, editing, sharing,
   and Retake are unavailable until a complete processed result is ready.
2. **The first Preview offers Resolution and CRF.** Resolution is a menu showing
   Native, 75%, 50%, and 25% with actual pixel dimensions. Native means captured
   backing pixels, including macOS HiDPI scaling on external displays. CRF is a
   menu from 18 to 40; lower values generally retain more detail and use more
   space. Changing resolution or CRF processes the retained original
   again. Successful choices are remembered for subsequent recordings.
3. **Recording bitrate lives in Settings → Recording.** It defaults to 10 Mbps
   and applies to new recordings. It does not change
   the already captured original or its recorded provenance.
4. **Ready preserves familiar editing and sharing.** Playback, timeline trimming,
   rename, Remove audio, drag, Copy, and Save As use the existing implementation.
   An enlarged native player provides fullscreen without stretching the editor.
   Dimensions and size describe the actual completed file.
5. **Close commits the full Source.** The latest valid full-duration processed
   H.264 becomes the managed Source. Trim, filename, and audio removal are metadata.
   After durable commit, the private HEVC and other candidates are removed.
6. **Reopening permits non-destructive editing.** A saved Source supports restoring
   the full trim and audio, but has no resolution or CRF controls. Export files
   are separate files and never become the Source.

A 30–60-second feature demo under 25 MB is a goal, not a size guarantee. CRF
controls quality rather than a hard bitrate or file limit. Full backing pixels
can exceed panel dimensions when macOS renders a scaled desktop at a larger
backing resolution; the Preview menu reports encoded pixels, not logical points.

## Production components

| Component | Responsibility |
| --- | --- |
| `Clip/Services/NativeCaptureService.swift` | Capture ownership, recovery metadata, disk monitoring, and stopping/finalization. |
| `ClipMedia/ScreenRecorder.swift` and `AssetWriterSession.swift` | Native geometry, pause/resume, system/microphone audio, and compressed MP4 writing. |
| `ClipMedia/RecordingPixelNormalizer.swift` | Normalize known capture color profiles to sRGB without resizing. |
| `ClipMedia/VideoToolboxHEVCEncoder.swift` | Hardware-only HEVC Main at the selected average bitrate, with bounded pressure and explicit failures. |
| `ClipMedia/RecordingProcessor.swift` | Typed progress/cancellation, native inspection, bundled x264 processing, validation, and atomic candidate publication. |
| `Clip/Processing/RecordingProcessingSession.swift` | Durable first-preview transaction, generations, immutable original, metadata, and commit. |
| `Clip/Processing/RecordingProcessingRecovery.swift` | Startup recovery before legacy capture recovery and retention cleanup. |
| `Clip/Preview/` | Product controls, progress, player, timeline, drag source, and enlarged playback. |
| `Clip/Export/PreviewExportCoordinator.swift` | Export requests, independent copies, reader ownership, caching, and publication. |
| `ClipMedia/NativeAssetExporter.swift` | Independent full copy or native compressed trim/mute passthrough. |
| `ClipCore/RecordingProcessing.swift` | Typed scale, CRF, capture bitrate, and durable processing provenance. |

`ClipMedia` paths above are under `Packages/ClipMedia/Sources/ClipMedia` and
`ClipCore` under `Packages/ClipCore/Sources/ClipCore`.

## Encoding and timing

The writer receives ScreenCaptureKit's full native backing geometry. It rejects
unexpected dimensions and unsupported color profiles instead of silently
resizing or relabeling them. HEVC uses hardware acceleration, real-time mode,
no frame reordering, and a two-second keyframe interval. The temporary MP4 holds
compressed HEVC plus optional AAC tracks; there is no ProRes intermediate.

The final pipeline hardware-decodes HEVC, then uses x264 `veryfast`, four threads,
CRF 24 by default, no B-frames, one reference frame, High profile, 4:2:0 pixels,
and MP4 fast start. Native skips scaling. Reduced resolutions use Lanczos with
accurate rounding and full chroma interpolation, rounded down to even dimensions.
Original timestamps, sample count, and the last sample's duration are preserved.
The 60,000-tick MP4 clock avoids overflow during long static holds while
representing 30/60 FPS exactly.

A single AAC track is copied. Multiple capture tracks are aligned to the video
clock, materializing delayed starts and missing-buffer gaps as silence, then
mixed once to 128 kbps AAC. Subsequent exports copy/remux that audio or remove
it; no additional video quality setting exists during sharing.

The processor inspects both input and output with AVFoundation. It checks
codec, dimensions, duration, video sample count, final sample timing, color, and
audio layout, then natively decodes the first and last frames before atomically
publishing the candidate. Child-process progress is continuously drained and
stderr is bounded. Cancellation terminates and waits for the process before
removing partial files, retaining the original and any prior complete result.

Full unchanged exports are independent byte-for-byte copies. Trim/mute uses
`AVAssetExportPresetPassthrough` and composition edit lists. Native validation
checks the first displayed pixels, including non-keyframe and fractional-frame
starts, plus duration and audio layout. Conversion of legacy timebases permits
only a one-output-tick endpoint overrun; larger out-of-range trims are rejected.

## Storage, Close, and recovery

Capture staging and processing jobs live in the app's Application Support
container. Each UUID-owned session has an atomic `session.json`, `original.mp4`,
and generation-named candidates. The journal establishes ownership before the
original is moved. Recorded hashes protect the original and candidate against
unexpected on-disk changes. Only the currently requested generation may publish.

Commit imports the complete processed recording under its stable recording ID
and preserves its edits and recipe. Journaled commit is idempotent across crashes.
Cleanup occurs after the Source and metadata are durable. Published Copy/drag
files and external Save As files have separate ownership and survive Source
cleanup. Reader leases protect in-flight exports from candidate replacement.

Startup reconciles unfinished sessions and staged captures before ordinary
history maintenance. Malformed or unverified media is retained with an actionable
error, never silently deleted or adopted by filename alone. A missing journal
or externally deleted session must not strand Preview in a loading state. If
recoverable media remains, it stays available; an empty session can close.
Close and Quit use the same transaction, and forced termination relies on the
journal rather than a last-second encoding attempt.

Older settings ignore removed quality fields. Existing Sources remain readable
with unknown processing provenance rather than pretending Apple quality values
were CRF. The retired “remove after export” retention value maps to ordinary
seven-day retention. Export-driven Source replacement and preset encoders have
been removed entirely.

## Self-contained encoder and release checks

`scripts/build-recording-encoder.sh` builds an ARM64-only static FFmpeg 8.0 and
x264 r3222/b35605a helper from exact official source archives. Download hashes,
build configuration, and cache fingerprints are pinned in the repository. It
has no network protocols or non-system dynamic library dependency. Runtime
requires neither Homebrew, Python, nor an encoder download.

The normal Xcode build phase and manual app builder call
`scripts/bundle-recording-encoder.sh`. The app contains the signed helper in
`Contents/Helpers/ffmpeg` and corresponding source archives, GPL texts, notices,
manifest, and build recipe in `Contents/Resources/RecordingEncoderSources`.
The helper has Hardened Runtime plus sandbox inheritance entitlements. The
ordinary signing script signs it before the app's outer seal.

`scripts/verify-recording-encoder.sh` verifies architecture, signature,
entitlements, system-only dylibs, source checksums, recipe hashes, and the
normalized executable payload. DMG provenance records the signed helper,
normalized payload, and source-manifest hashes; mounted-DMG verification checks
these again. The helper has also been exercised from a signed sandboxed native
host, with production processing and AVFoundation output validation.

## Acceptance and cleanup

The regular package/app tests cover processing generations, settings persistence,
commit/recovery failures, external deletion, independent export ownership,
Preview action gating, and locked reopened Sources. Media acceptance covers:

- Hardware HEVC geometry/color policy and native sRGB normalization.
- 30/60 FPS pause/resume, static Stop boundaries, and long sparse timelines.
- Actual x264 processing at Native, 75%, 50%, and 25%, with unchanged original bytes.
- Delayed microphone starts and audio gaps verified from decoded audible content.
- Byte-identical full copies, non-keyframe/fractional trims, and audio removal.
- Cancellation, existing-output preservation, and exact final duration.
- Self-contained signing, source provenance, and sandboxed helper execution.

Run `scripts/run-quality-acceptance.sh` for the complete permission-free media
suite. [ACCEPTANCE.md](ACCEPTANCE.md) separates these tests from controlled real
ScreenCaptureKit and UI checks. [PERFORMANCE.md](PERFORMANCE.md) defines the
30-second synthetic benchmark and its precise Stop-to-ready timing boundary.
Actual high-resolution screen content still needs visual review; an automated
metadata/timing pass is not a subjective sharpness score.

The final source tree must contain no abandoned prototype application, Python
processor, quality lab, alternate ProRes/direct-H.264/capped/fallback recording
modes, old 0–100 recording quality controls, or tests/scripts/docs targeting
those removed paths. Shared Live Share codec controls and pre-existing supported
capture diagnostics remain separate and are not removed merely because they
also mention quality. User recordings are not source-code cleanup targets.
