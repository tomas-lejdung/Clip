import Foundation
@preconcurrency import WebRTC

/// Keeps both realtime codecs available for the lifetime of the native peer
/// factory. Individual transceivers select one codec using codec preferences,
/// so renegotiation can switch codecs without replacing tracks or transports.
final class WebRTCVideoEncoderFactory: NSObject, RTCVideoEncoderFactory,
    @unchecked Sendable
{
    private let h264Factory: WebRTCH264EncoderFactory
    private let codecs: [RTCVideoCodecInfo]

    init(
        preferredCodec: WebRTCVideoCodec,
        h264Factory: WebRTCH264EncoderFactory = WebRTCH264EncoderFactory()
    ) {
        self.h264Factory = h264Factory
        let h264 = h264Factory.supportedCodecs()
        let vp8 = RTCVideoEncoderVP8.supportedCodecs()
        codecs = preferredCodec == .h264 ? h264 + vp8 : vp8 + h264
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
        default:
            nil
        }
    }
}
