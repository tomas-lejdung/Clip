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

    @Test("encoder dimensions preserve the established even-pixel contract")
    func videoEncoderGeometry() {
        #expect(
            LiveShareCapturePolicy.videoEncoderCompatibleDimension(2_763)
                == 2_762
        )
        #expect(
            LiveShareCapturePolicy.videoEncoderCompatibleDimension(1_203)
                == 1_202
        )
        #expect(
            LiveShareCapturePolicy.videoEncoderCompatibleDimension(1_920)
                == 1_920
        )
        #expect(
            LiveShareCapturePolicy.videoEncoderCompatibleDimension(1)
                == 2
        )
    }

    @Test("H.264 aspect-fits large sources while software codecs stay native")
    func codecCaptureGeometry() {
        #expect(LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 1_920, height: 1_080))
        #expect(LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 1_605,
            sourceHeight: 1_108,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 1_605, height: 1_108))
        #expect(LiveShareCapturePolicy.streamGeometry(
            captureGeometry: LiveShareCaptureGeometry(
                width: 1_605,
                height: 1_108
            ),
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 1_604, height: 1_108))
        #expect(LiveShareCapturePolicy.streamGeometry(
            captureGeometry: LiveShareCaptureGeometry(
                width: 1_605,
                height: 1_109
            ),
            codec: .vp8
        ) == LiveShareCaptureGeometry(width: 1_605, height: 1_109))

        #expect(LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 5_120,
            sourceHeight: 2_880,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 4_096, height: 2_304))
        #expect(LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 5_120,
            sourceHeight: 1_440,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 4_096, height: 1_152))
        #expect(LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 2_880,
            sourceHeight: 5_120,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 2_304, height: 4_096))
        #expect(LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 6_016,
            sourceHeight: 3_384,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 4_096, height: 2_304))

        let sixtyFPSH264 = LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 6_016,
            sourceHeight: 3_384,
            codec: .h264,
            framesPerSecond: 60
        )
        let sixtyFPSMacroblocks = ((sixtyFPSH264.width + 15) / 16)
            * ((sixtyFPSH264.height + 15) / 16)
        #expect(sixtyFPSMacroblocks * 60 <= 2_073_600)
        #expect(
            sixtyFPSH264
                != LiveShareCaptureGeometry(width: 4_096, height: 2_304)
        )

        #expect(LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 6_016,
            sourceHeight: 3_384,
            codec: .vp8,
            framesPerSecond: 60
        ) == LiveShareCaptureGeometry(width: 6_016, height: 3_384))
        #expect(LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 6_017,
            sourceHeight: 3_385,
            codec: .vp8
        ) == LiveShareCaptureGeometry(width: 6_017, height: 3_385))
        for codec in [LiveShareVideoCodec.vp9, .av1] {
            #expect(LiveShareCapturePolicy.captureGeometry(
                sourceWidth: 6_017,
                sourceHeight: 3_385,
                codec: codec
            ) == LiveShareCaptureGeometry(width: 6_017, height: 3_385))
            #expect(LiveShareCapturePolicy.streamGeometry(
                captureGeometry: LiveShareCaptureGeometry(
                    width: 6_017,
                    height: 3_385
                ),
                codec: codec
            ) == LiveShareCaptureGeometry(width: 6_017, height: 3_385))
        }
    }

    @Test("H.264 geometry stays within hardware side, luma, and macroblock limits")
    func h264GeometryLimits() {
        for (width, height) in [
            (5_120, 2_880),
            (6_016, 3_384),
            (8_000, 1_000),
            (1_000, 8_000),
            (4_097, 2_305),
        ] {
            let geometry = LiveShareCapturePolicy.captureGeometry(
                sourceWidth: width,
                sourceHeight: height,
                codec: .h264
            )
            let streamGeometry = LiveShareCapturePolicy.streamGeometry(
                captureGeometry: geometry,
                codec: .h264
            )
            #expect(streamGeometry.width <= 4_096)
            #expect(streamGeometry.height <= 4_096)
            #expect(streamGeometry.width * streamGeometry.height <= 4_096 * 2_304)
            #expect(
                ((streamGeometry.width + 15) / 16)
                    * ((streamGeometry.height + 15) / 16)
                    <= 36_864
            )
            #expect(streamGeometry.width.isMultiple(of: 2))
            #expect(streamGeometry.height.isMultiple(of: 2))
        }

        // Although its visible luma is below the nominal limit, codec padding
        // on both odd sides would otherwise exceed H.264 Level 5.2.
        let pathological = LiveShareCapturePolicy.captureGeometry(
            sourceWidth: 4_081,
            sourceHeight: 2_307,
            codec: .h264
        )
        #expect(
            ((pathological.width + 15) / 16)
                * ((pathological.height + 15) / 16)
                <= 36_864
        )
    }

    @Test("window capture keeps the established external and Retina resolution matrix")
    func windowCaptureResolutionMatrix() {
        // A genuine 1× window must remain nominal even while a Retina display
        // is active. Asking ScreenCaptureKit for `.best` in that topology makes
        // WindowServer compose at 2× and filter the result back to 1×.
        #expect(LiveShareCapturePolicy.windowCaptureResolution(
            sourcePixelWidth: 1_159,
            sourcePixelHeight: 668,
            sourcePointWidth: 1_159,
            sourcePointHeight: 668
        ) == .nominal)

        // A genuine 2× source must keep `.best`; `.nominal` would discard the
        // Retina backing pixels before the networking pipeline sees them.
        #expect(LiveShareCapturePolicy.windowCaptureResolution(
            sourcePixelWidth: 2_318,
            sourcePixelHeight: 1_336,
            sourcePointWidth: 1_159,
            sourcePointHeight: 668
        ) == .best)

        // WindowServer geometry can be one pixel short because of edge
        // rounding. The near-2× source must still be recognized as Retina.
        #expect(LiveShareCapturePolicy.windowCaptureResolution(
            sourcePixelWidth: 2_317,
            sourcePixelHeight: 1_335,
            sourcePointWidth: 1_159,
            sourcePointHeight: 668
        ) == .best)
    }

    @Test("codec and color settings keep the established capture pixel formats")
    func capturePixelFormats() {
        for codec in [LiveShareVideoCodec.vp8, .vp9, .av1] {
            #expect(LiveShareCapturePolicy.captureVideoConfiguration(
                width: 1_920,
                height: 1_080,
                framesPerSecond: 30,
                codec: codec,
                colorMode: .compatibleRec709
            ).pixelFormat == .rec709VideoRange)
            #expect(LiveShareCapturePolicy.captureVideoConfiguration(
                width: 1_920,
                height: 1_080,
                framesPerSecond: 30,
                codec: codec,
                colorMode: .fullRangeRec709
            ).pixelFormat == .rec709FullRange)
        }

        #expect(LiveShareCapturePolicy.captureVideoConfiguration(
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            codec: .h264,
            colorMode: .compatibleRec709
        ).pixelFormat == .rec709BGRA)
        #expect(LiveShareCapturePolicy.captureVideoConfiguration(
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            codec: .vp8,
            colorMode: .nativeDisplay
        ).pixelFormat == .bgra)
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
