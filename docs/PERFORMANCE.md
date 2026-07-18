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
  default quality `90` configuration, validates every output's duration,
  native dimensions, durable frame-rate ceiling, codec, and readability, and
  includes the atomic publication path. Compact always exercises the offline
  quality path; only an eligible Crisp request may reuse source bytes.

At its hardware-supported fixture dimensions, the benchmark leaves
`AverageBitRate` and `DataRateLimits` unset and does not resize or decimate the
fixture. Exact oversized exports have a separate regression for the native
software-H.264 soft-rate fallback. The exported MP4 is inspected before it is
atomically published.

## Development Mac result

The 2026-07-18 Release run on the development Mac passed both targets:

- Preview media readiness: `44.69`/`45.72`/`45.81` ms min/median/max, target below `1,000` ms.
- Compact-90 offline export: `1,671.29`/`1,674.66`/`1,740.53` ms min/median/max, target below `2,000` ms.

The Compact samples were real native 1,440 × 900 at 30 FPS quality transcodes,
not source reuse. Machine-readable evidence is in
`.build/performance/latest.json`. The 2026-07-17 Compact timings measured the
superseded export policy and are retained only as historical context.
