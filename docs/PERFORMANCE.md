# Permission-free performance evidence

Run the opt-in Release benchmark with:

```bash
./scripts/benchmark-performance.sh
```

This benchmark is intentionally separate from the ordinary test and release
gates so machine load cannot make correctness tests flaky. It does not launch
Clip, request a privacy permission, run UI automation, or move the pointer. A
machine-readable result is written to `.build/performance/latest.json`.

## Reference fixture and measurement boundaries

The benchmark creates the specification's 30-second, 1,440 × 900, 30 FPS
fixture through Clip's real `AssetWriterSession`. Its 900 frames contain a
deterministic low-motion screen pattern and use the app's default audio-off
setting.

- **Preview media readiness** starts after the last video sample has been
  accepted. It includes `AssetWriterSession.finish()` and reopening/loading the
  finalized H.264 MP4 metadata through `MediaInspector`. This proves the native
  media needed by Preview is ready; it deliberately does not claim to measure
  AppKit window drawing or a real ScreenCaptureKit stream stop.
- **Compact export** runs the real `NativeAssetExporter` with the Compact
  configuration, validates every output's duration, dimensions, frame rate,
  codec, and readability, and includes the atomic publication path.

Compact avoids another lossy encode only when an untrimmed source already
satisfies every output constraint: one H.264 video track, exact target
dimensions, source FPS no higher than the target, actual data rate no higher
than the target, Rec.709 color metadata, and at most one compatible 48 kHz
stereo AAC track. Two audio tracks always take the mixing/transcode path. The
temporary copied MP4 is inspected before it is atomically published.

## Development Mac result

Measured 2026-07-17 in a Swift 6.3.3 Release build on an Apple M3 Max with
64 GB memory and macOS 26.5.2:

| Metric | Samples | Median | Maximum | Target | Result |
| --- | --- | ---: | ---: | ---: | --- |
| Preview media readiness | 130.83, 116.39, 126.10 ms | 126.10 ms | 130.83 ms | < 1,000 ms | Pass |
| Compact export | 4.10, 2.67, 2.25, 2.08, 1.97 ms | 2.25 ms | 4.10 ms | < 2,000 ms | Pass |

The checked policy and integration coverage includes positive reuse plus
rejection for trimming, resizing, FPS reduction, and two-track audio mixing.
The complete `ClipMedia` suite passed 37/37 after this measurement work.
