import ClipCapture
import ClipLiveShare
import CoreGraphics
import Foundation
import Testing
@testable import Clip

@Suite("Live Share capture policy")
struct LiveShareCapturePolicyTests {
    @Test("source identifiers round trip without coordinator state")
    func sourceIdentifierRoundTrip() {
        let sources: [LiveShareSourceID] = [
            .window(.init(rawValue: 41)),
            .fullscreen(.init(rawValue: 73)),
        ]

        for source in sources {
            let identifier = LiveShareCapturePolicy.sourceIdentifier(source)
            #expect(LiveShareCapturePolicy.sourceID(from: identifier) == source)
        }
        #expect(LiveShareCapturePolicy.sourceID(from: "participant:41") == nil)
    }

    @Test("capture policy preserves native geometry and encoder metadata")
    func captureGeometryAndConfiguration() {
        let capture = LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 1_605,
            sourceHeight: 1_109,
            codec: .h264
        )
        let stream = LiveShareCapturePolicy.streamGeometry(
            captureGeometry: capture,
            codec: .h264
        )
        let configuration = LiveShareCapturePolicy.captureVideoConfiguration(
            width: capture.width,
            height: capture.height,
            framesPerSecond: 60,
            codec: .h264,
            colorMode: .fullRangeRec709,
            sourceRect: CGRect(x: 3, y: 5, width: 800, height: 450)
        )

        #expect(capture == .init(width: 1_605, height: 1_109))
        #expect(stream == .init(width: 1_604, height: 1_108))
        #expect(configuration.width == 1_605)
        #expect(configuration.height == 1_109)
        #expect(configuration.framesPerSecond == 60)
        #expect(configuration.pixelFormat == .rec709BGRA)
        #expect(!configuration.showsClickHighlights)
    }

    @Test("audio exclusion process state is publication-neutral")
    func audioFilterProcessState() {
        let processes = LiveShareCapturePolicy.audioFilterProcessIdentifiers(
            candidates: [
                .init(
                    processIdentifier: 10,
                    bundleIdentifier: "com.example.Clip"
                ),
                .init(
                    processIdentifier: 20,
                    bundleIdentifier: " com.hnc.Discord "
                ),
                .init(
                    processIdentifier: 0,
                    bundleIdentifier: "com.hnc.Discord"
                ),
            ],
            excludedBundleIdentifiers: ["com.hnc.Discord"],
            clipBundleIdentifier: "com.example.Clip"
        )

        #expect(processes == [10, 20])
    }

    @Test("mesh sender policy is built without coordinator lifecycle")
    func senderPolicy() {
        let policy = LiveShareCapturePolicy.senderPolicy(
            for: LiveShareSettings(
                quality: .insane,
                frameRate: .sixty,
                encodingMode: .quality
            )
        )

        #expect(policy.maximumBitrateBps == 50_000_000)
        #expect(policy.maximumFramesPerSecond == 60)
        #expect(policy.degradationStrategy == .resolution)
        #expect(policy.resolutionScale == 1)
    }

}
