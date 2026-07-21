import Foundation

/// Negotiates ScreenCaptureKit audio as full-band stereo music instead of
/// libwebrtc's mono voice default.
///
/// Opus always advertises `opus/48000/2` in SDP, but that RTP channel count is
/// only the codec capability. libwebrtc selects a one-channel VoIP encoder
/// unless the negotiated fmtp explicitly contains `stereo=1`. The viewer must
/// apply the same profile to its answer so the remote description configures
/// Clip's sender with these values.
enum WebRTCOpusMusicSDP {
    static let maximumAverageBitrateBps = 128_000

    private static let requiredParameters: [(key: String, value: String)] = [
        ("stereo", "1"),
        ("sprop-stereo", "1"),
        ("maxaveragebitrate", String(maximumAverageBitrateBps)),
        ("usedtx", "0"),
    ]

    static func applying(to sdp: String) -> String {
        let lineSeparator = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: lineSeparator)
        var sectionStart = 0
        while sectionStart < lines.count {
            guard isMediaLine(lines[sectionStart]) else {
                sectionStart += 1
                continue
            }
            var sectionEnd = sectionStart + 1
            while sectionEnd < lines.count,
                  !isMediaLine(lines[sectionEnd]) {
                sectionEnd += 1
            }
            guard isAudioMediaLine(lines[sectionStart]) else {
                sectionStart = sectionEnd
                continue
            }

            let opusPayloads = Set(
                lines[sectionStart ..< sectionEnd].compactMap(opusPayloadType)
            )
            for payloadType in opusPayloads.sorted() {
                if let formatIndex = (sectionStart ..< sectionEnd).first(where: {
                    formatPayloadType(lines[$0]) == payloadType
                }) {
                    lines[formatIndex] = upgradedFormatLine(
                        lines[formatIndex],
                        payloadType: payloadType
                    )
                } else if let mappingIndex =
                    (sectionStart ..< sectionEnd).first(where: {
                        opusPayloadType(lines[$0]) == payloadType
                    }) {
                    lines.insert(
                        upgradedFormatLine("", payloadType: payloadType),
                        at: mappingIndex + 1
                    )
                    sectionEnd += 1
                }
            }
            sectionStart = sectionEnd
        }
        return lines.joined(separator: lineSeparator)
    }

    private static func isMediaLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .hasPrefix("m=")
    }

    private static func isAudioMediaLine(_ line: String) -> Bool {
        let mediaType = line.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0.isWhitespace })
            .first
        return mediaType?.caseInsensitiveCompare("m=audio") == .orderedSame
    }

    private static func opusPayloadType(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lowercased = trimmed.lowercased()
        let prefix = "a=rtpmap:"
        guard lowercased.hasPrefix(prefix) else { return nil }
        let value = trimmed.dropFirst(prefix.count)
        let fields = value.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2,
              fields[1].lowercased() == "opus/48000/2" else { return nil }
        return String(fields[0])
    }

    private static func formatPayloadType(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lowercased = trimmed.lowercased()
        let prefix = "a=fmtp:"
        guard lowercased.hasPrefix(prefix) else { return nil }
        let value = trimmed.dropFirst(prefix.count)
        return value.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    private static func upgradedFormatLine(
        _ line: String,
        payloadType: String
    ) -> String {
        let existingParameters: String
        if let whitespace = line.firstIndex(where: { $0.isWhitespace }) {
            existingParameters = String(line[line.index(after: whitespace)...])
        } else {
            existingParameters = ""
        }
        var parameters = existingParameters
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for required in requiredParameters {
            if let index = parameters.firstIndex(where: {
                parameterKey($0).caseInsensitiveCompare(required.key) == .orderedSame
            }) {
                parameters[index] = "\(required.key)=\(required.value)"
            } else {
                parameters.append("\(required.key)=\(required.value)")
            }
        }
        return "a=fmtp:\(payloadType) \(parameters.joined(separator: ";"))"
    }

    private static func parameterKey(_ parameter: String) -> String {
        guard let equals = parameter.firstIndex(of: "=") else { return parameter }
        return String(parameter[..<equals])
            .trimmingCharacters(in: .whitespaces)
    }
}
