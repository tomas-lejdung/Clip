import Foundation
@preconcurrency import WebRTC

/// Keeps every available realtime codec available for the lifetime of the
/// native peer factory. Individual transceivers select a preferred codec (and,
/// where configured by the host, a compatibility fallback), so renegotiation
/// can switch codecs without replacing tracks or transports.
final class WebRTCVideoEncoderFactory: NSObject, RTCVideoEncoderFactory,
    @unchecked Sendable
{
    private let h264Factory: WebRTCH264EncoderFactory
    private let supportsVP9: Bool
    private let supportsAV1: Bool
    private let codecs: [RTCVideoCodecInfo]

    init(
        preferredCodec: WebRTCVideoCodec,
        h264Factory: WebRTCH264EncoderFactory = WebRTCH264EncoderFactory(),
        supportsVP9: Bool = RTCVideoEncoderVP9.isSupported(),
        supportsAV1: Bool = RTCVideoEncoderAV1.isSupported()
    ) {
        self.h264Factory = h264Factory
        self.supportsVP9 = supportsVP9
        self.supportsAV1 = supportsAV1

        // Captured screen frames are 8-bit BGRA. VP9 profile 2 is intended for
        // higher bit depths, so only advertise the interoperable profile 0.
        let vp9Codecs = supportsVP9
            ? RTCVideoEncoderVP9.supportedCodecs().filter {
                $0.parameters["profile-id"] == "0"
            }
            : []
        let codecsByKind: [WebRTCVideoCodec: [RTCVideoCodecInfo]] = [
            .h264: h264Factory.supportedCodecs(),
            .vp8: RTCVideoEncoderVP8.supportedCodecs(),
            .vp9: vp9Codecs,
            .av1: supportsAV1 ? RTCVideoEncoderAV1.supportedCodecs() : [],
        ]
        let codecOrder = [preferredCodec]
            + WebRTCVideoCodec.allCases.filter { $0 != preferredCodec }
        codecs = codecOrder.flatMap { codecsByKind[$0] ?? [] }
        super.init()
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        codecs
    }

    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        switch info.name.uppercased() {
        case WebRTCVideoCodec.h264.rtcName:
            h264Factory.createEncoder(info)
        case WebRTCVideoCodec.vp8.rtcName:
            RTCVideoEncoderVP8.vp8Encoder()
        case WebRTCVideoCodec.vp9.rtcName:
            supportsVP9 && Self.isVP9ProfileZero(info)
                ? RTCVideoEncoderVP9.vp9Encoder()
                : nil
        case WebRTCVideoCodec.av1.rtcName:
            supportsAV1 ? RTCVideoEncoderAV1.av1Encoder() : nil
        default:
            nil
        }
    }

    private static func isVP9ProfileZero(_ info: RTCVideoCodecInfo) -> Bool {
        info.parameters["profile-id"].map { $0 == "0" } ?? true
    }
}
