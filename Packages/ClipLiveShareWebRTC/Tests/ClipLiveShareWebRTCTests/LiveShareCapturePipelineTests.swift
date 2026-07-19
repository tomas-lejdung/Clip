import ClipCapture
import ClipLiveShare
import Testing
@testable import ClipLiveShareWebRTC

@Suite("Live Share capture pipeline policy")
struct LiveShareCapturePipelineTests {
    @Test("only the four negotiated slots are accepted")
    func slotBounds() async {
        let pipeline = LiveShareCapturePipeline(host: FakeSlotHost())
        await #expect(throws: LiveShareCapturePipelineError.invalidSlot(-1)) {
            try await pipeline.start(Self.descriptor(), inSlot: -1)
        }
        await #expect(throws: LiveShareCapturePipelineError.invalidSlot(4)) {
            try await pipeline.start(Self.descriptor(), inSlot: 4)
        }
    }

    private static func descriptor() -> LiveShareCaptureDescriptor {
        let source = LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: 42),
            windowName: "Fixture",
            appName: "Tests"
        )
        return LiveShareCaptureDescriptor(
            source: .window(source),
            target: .window(id: 42),
            video: CaptureVideoConfiguration(width: 1_280, height: 720),
            stream: GoPeepV1StreamInfo(
                trackID: "video0",
                windowName: "Fixture",
                appName: "Tests",
                isFocused: true,
                width: 1_280,
                height: 720
            )
        )
    }
}

private final class FakeSlotHost: LiveShareVideoSlotHosting, @unchecked Sendable {
    func send(
        _ frame: BorrowedCaptureVideoFrame,
        toSlot slot: Int
    ) -> CaptureFrameDisposition {
        .accepted
    }

    func activateSlot(_ slot: Int, metadata: GoPeepV1StreamInfo) throws {}
    func deactivateSlot(_ slot: Int) {}
}
