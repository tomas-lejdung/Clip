import Foundation
@preconcurrency import WebRTC

/// H.264 encoder factory for native-resolution screen sharing.
///
/// WebRTC's bundled Apple factory advertises H.264 Level 3.1, whose 3,600
/// macroblock frame limit is only large enough for roughly 1280 x 720. A
/// Retina-sized window is accepted by `RTCVideoSource`, but VideoToolbox then
/// rejects encoder preparation and no RTP is produced. The underlying Apple
/// encoder supports higher levels, so expose Level 5.2 and also make sure the
/// codec instance is initialized with that level after offer/answer
/// negotiation.
final class WebRTCH264EncoderFactory: NSObject, RTCVideoEncoderFactory,
    @unchecked Sendable
{
    static let maximumLevelIDC = "34" // H.264 Level 5.2.

    private let configurationController: WebRTCH264EncoderConfigurationController

    private let codecs: [RTCVideoCodecInfo] = RTCVideoEncoderH264
        .supportedCodecs()
        .map(upgradingToMaximumLevel)

    init(
        configuration: WebRTCH264EncoderConfiguration = .quality,
        advancedConfiguration: WebRTCH264AdvancedConfiguration? = nil,
        configurationController: WebRTCH264EncoderConfigurationController? = nil
    ) {
        let initialConfiguration = advancedConfiguration.map {
            WebRTCH264EncoderConfiguration(
                mode: configuration.mode,
                advancedConfiguration: $0
            )
        } ?? configuration
        self.configurationController = configurationController
            ?? WebRTCH264EncoderConfigurationController(
                configuration: initialConfiguration
            )
        super.init()
    }

    func updateMode(_ mode: WebRTCH264EncodingMode) {
        configurationController.updateMode(mode)
    }

    func updateConfiguration(_ configuration: WebRTCH264EncoderConfiguration) {
        configurationController.update(configuration)
    }

    func updateAdvancedConfiguration(
        _ configuration: WebRTCH264AdvancedConfiguration
    ) {
        configurationController.updateAdvancedConfiguration(configuration)
    }

    var submissionBackpressureDropCount: UInt64 {
        configurationController.submissionBackpressureDropCount
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        codecs
    }

    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        guard info.name.caseInsensitiveCompare("H264") == .orderedSame else {
            return nil
        }
        return WebRTCVideoToolboxH264Encoder(
            codecInfo: Self.upgradingToMaximumLevel(info),
            configurationController: configurationController
        )
    }

    private static func upgradingToMaximumLevel(
        _ codec: RTCVideoCodecInfo
    ) -> RTCVideoCodecInfo {
        var parameters = codec.parameters
        if let profileLevelID = parameters["profile-level-id"],
           profileLevelID.count == 6
        {
            parameters["profile-level-id"] =
                String(profileLevelID.prefix(4)) + maximumLevelIDC
        }
        return RTCVideoCodecInfo(
            name: codec.name,
            parameters: parameters,
            scalabilityModes: codec.scalabilityModes
        )
    }

    /// libwebrtc's Apple SDP generator clamps H.264 profile-level-id back to
    /// its built-in Level 3.1 constant even when an injected factory reports a
    /// higher supported level. Munging is safe here because the same factory
    /// also creates every encoder with Level 5.2; changing SDP alone would not
    /// be sufficient.
    static func upgradingProfileLevels(in sdp: String) -> String {
        let expression = try? NSRegularExpression(
            pattern: "profile-level-id=([0-9A-Fa-f]{4})[0-9A-Fa-f]{2}"
        )
        guard let expression else { return sdp }
        let range = NSRange(sdp.startIndex ..< sdp.endIndex, in: sdp)
        return expression.stringByReplacingMatches(
            in: sdp,
            range: range,
            withTemplate: "profile-level-id=$1\(maximumLevelIDC)"
        )
    }
}
