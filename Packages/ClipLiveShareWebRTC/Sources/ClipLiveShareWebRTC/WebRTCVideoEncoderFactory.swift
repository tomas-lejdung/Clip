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
        h264Factory: WebRTCH264EncoderFactory? = nil,
        advancedConfigurations: WebRTCAdvancedVideoConfigurations = .clipDefault,
        supportsVP9: Bool = RTCVideoEncoderVP9.isSupported(),
        supportsAV1: Bool = RTCVideoEncoderAV1.isSupported()
    ) {
        self.h264Factory = h264Factory ?? WebRTCH264EncoderFactory(
            advancedConfiguration: advancedConfigurations.h264
        )
        self.supportsVP9 = supportsVP9
        self.supportsAV1 = supportsAV1

        // Live Share captures 8-bit SDR video. VP9 profile 2 is intended for
        // higher bit depths, so only advertise the interoperable profile 0.
        let vp9Codecs = supportsVP9
            ? RTCVideoEncoderVP9.supportedCodecs().filter {
                $0.parameters["profile-id"] == "0"
            }
            : []
        let codecsByKind: [WebRTCVideoCodec: [RTCVideoCodecInfo]] = [
            .h264: self.h264Factory.supportedCodecs(),
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
            return h264Factory.createEncoder(info)
        case WebRTCVideoCodec.vp8.rtcName:
            return RTCVideoEncoderVP8.vp8Encoder()
        case WebRTCVideoCodec.vp9.rtcName:
            guard supportsVP9, Self.isVP9ProfileZero(info) else { return nil }
            return RTCVideoEncoderVP9.vp9Encoder()
        case WebRTCVideoCodec.av1.rtcName:
            guard supportsAV1 else { return nil }
            return RTCVideoEncoderAV1.av1Encoder()
        default:
            return nil
        }
    }

    func updateAdvancedConfiguration(
        _ configuration: WebRTCCodecAdvancedConfiguration
    ) {
        switch configuration {
        case let .h264(configuration):
            h264Factory.updateAdvancedConfiguration(configuration)
        }
    }

    private static func isVP9ProfileZero(_ info: RTCVideoCodecInfo) -> Bool {
        info.parameters["profile-id"].map { $0 == "0" } ?? true
    }

}
