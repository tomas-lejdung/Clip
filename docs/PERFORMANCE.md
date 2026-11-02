# Permission-free recording performance

Run `./scripts/benchmark-performance.sh` to generate a 30-second, 1,440 × 900,
30 FPS screen-content fixture using the production HEVC 10 Mbps writer, then
process it with the bundled x264 recipe at Native / CRF 24. The script builds
the pinned encoder first and writes `.build/performance/latest.json`.

This opt-in benchmark does not launch Clip, record the screen, move the pointer,
or request privacy permissions. Machine load can affect timing, so it remains
separate from deterministic correctness tests.

The Preview readiness interval begins after the last capture frame is submitted.
It includes writer finalization, full-duration H.264 processing, and native media
validation. It excludes ScreenCaptureKit stop and AppKit window rendering. Its
comparison target is under 10 seconds for this fixed 30-second fixture.

Copy export measures the actual independent-file export and atomic publication
of the processed Source. It preserves its video bytes rather than recompressing;
the target is under two seconds. Both stages validate codec, dimensions, cadence,
and duration. JSON schema 2 records the final file size and all timing samples.

Older Compact/Crisp encoder timings describe a removed pipeline and are not
comparable to the current Stop-to-ready measurement. Run this benchmark on the
same hardware for comparisons; it does not promise a fixed processing time or
file size for arbitrary resolutions and content.
