import Foundation
@preconcurrency import WebRTC

enum WebRTCInboundStatisticsParser {
    static func parse(
        _ report: RTCStatisticsReport,
        capturedAt: Date = Date()
    ) -> WebRTCInboundStatisticsSnapshot {
        let tracks: [WebRTCInboundTrackStatistics] = report.statistics.values.compactMap {
            statistic -> WebRTCInboundTrackStatistics? in
            guard statistic.type == "inbound-rtp" else { return nil }
            let rawKind = string(statistic.values["kind"])
                ?? string(statistic.values["mediaType"])
            let kind: WebRTCInboundTrackStatistics.Kind = switch rawKind {
            case "video": .video
            case "audio": .audio
            default: .unknown
            }
            let identifier = string(statistic.values["trackIdentifier"])
                ?? string(statistic.values["mid"])
                ?? statistic.id
            return WebRTCInboundTrackStatistics(
                id: identifier,
                kind: kind,
                bytesReceived: number(statistic.values["bytesReceived"])?.uint64Value ?? 0,
                packetsReceived: number(statistic.values["packetsReceived"])?.uint64Value ?? 0,
                packetsLost: number(statistic.values["packetsLost"])?.int64Value ?? 0,
                framesDecoded: number(statistic.values["framesDecoded"])?.uint64Value,
                framesDropped: number(statistic.values["framesDropped"])?.uint64Value,
                framesPerSecond: number(statistic.values["framesPerSecond"])?.doubleValue,
                jitterSeconds: number(statistic.values["jitter"])?.doubleValue,
                codec: codecName(for: statistic, in: report)
            )
        }.sorted { (lhs: WebRTCInboundTrackStatistics, rhs: WebRTCInboundTrackStatistics) in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.id < rhs.id
        }
        return WebRTCInboundStatisticsSnapshot(
            capturedAt: capturedAt,
            route: selectedConnectionRoute(in: report),
            tracks: tracks
        )
    }

    private static func codecName(
        for statistic: RTCStatistics,
        in report: RTCStatisticsReport
    ) -> String? {
        guard let codecID = string(statistic.values["codecId"]),
              let codec = report.statistics[codecID],
              let mimeType = string(codec.values["mimeType"]) else {
            return nil
        }
        return mimeType.split(separator: "/").last.map(String.init) ?? mimeType
    }

    private static func selectedConnectionRoute(
        in report: RTCStatisticsReport
    ) -> WebRTCConnectionRoute {
        let statistics = report.statistics
        let pairs = statistics.values.filter { $0.type == "candidate-pair" }
        let selectedPair = pairs.first(where: {
            number($0.values["selected"])?.boolValue == true
        }) ?? pairs.first(where: {
            number($0.values["nominated"])?.boolValue == true
                && string($0.values["state"]) == "succeeded"
        })
        guard let selectedPair,
              let localID = string(selectedPair.values["localCandidateId"]),
              let remoteID = string(selectedPair.values["remoteCandidateId"]) else {
            return .unknown
        }
        let localType = statistics[localID].flatMap {
            string($0.values["candidateType"])
        }
        let remoteType = statistics[remoteID].flatMap {
            string($0.values["candidateType"])
        }
        guard localType != nil || remoteType != nil else { return .unknown }
        return localType == "relay" || remoteType == "relay" ? .relay : .direct
    }

    private static func number(_ value: NSObject?) -> NSNumber? {
        value as? NSNumber
    }

    private static func string(_ value: NSObject?) -> String? {
        if let value = value as? NSString { return value as String }
        return value as? String
    }
}
