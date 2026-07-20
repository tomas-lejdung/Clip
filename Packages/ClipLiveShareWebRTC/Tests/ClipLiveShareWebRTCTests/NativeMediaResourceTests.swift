import Testing

/// One process-wide serialization boundary for tests that allocate WebRTC,
/// VideoToolbox, or IOSurface resources. Per-suite `.serialized` traits do not
/// prevent separate suites from running concurrently.
@Suite("Native media resource integration", .serialized)
struct NativeMediaResourceTests {}
