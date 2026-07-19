import Foundation
@preconcurrency import WebRTC

struct WebRTCOutboundCounterKey: Hashable, Sendable {
    let viewerID: String
    let slot: Int
}

struct WebRTCOutboundCounter: Equatable, Sendable {
    let timestampMicroseconds: Double
    let bytesSent: UInt64
    let framesSent: UInt64
}

struct WebRTCRawOutboundStatistics: Equatable, Sendable {
    let viewerID: String
    let slot: Int
    let trackID: String
    let timestampMicroseconds: Double
    let bytesSent: UInt64
    let packetsSent: UInt64
    let framesSent: UInt64
    let framesEncoded: UInt64
    let reportedFramesPerSecond: Double?
    let route: WebRTCConnectionRoute?

    init(
        viewerID: String,
        slot: Int,
        trackID: String,
        timestampMicroseconds: Double,
        bytesSent: UInt64,
        packetsSent: UInt64,
        framesSent: UInt64,
        framesEncoded: UInt64,
        reportedFramesPerSecond: Double?,
        route: WebRTCConnectionRoute? = nil
    ) {
        self.viewerID = viewerID
        self.slot = slot
        self.trackID = trackID
        self.timestampMicroseconds = timestampMicroseconds
        self.bytesSent = bytesSent
        self.packetsSent = packetsSent
        self.framesSent = framesSent
        self.framesEncoded = framesEncoded
        self.reportedFramesPerSecond = reportedFramesPerSecond
        self.route = route
    }

    var key: WebRTCOutboundCounterKey {
        .init(viewerID: viewerID, slot: slot)
    }

    var counter: WebRTCOutboundCounter {
        .init(
            timestampMicroseconds: timestampMicroseconds,
            bytesSent: bytesSent,
            framesSent: framesSent
        )
    }
}

enum WebRTCOutboundStatisticsParser {
    static func parse(
        _ report: RTCStatisticsReport,
        viewerID: String,
        slot: Int,
        trackID: String
    ) -> WebRTCRawOutboundStatistics {
        let outbound = report.statistics.values.filter { statistic in
            guard statistic.type == "outbound-rtp" else { return false }
            let kind = string(statistic.values["kind"])
                ?? string(statistic.values["mediaType"])
            return kind == nil || kind == "video"
        }
        return WebRTCRawOutboundStatistics(
            viewerID: viewerID,
            slot: slot,
            trackID: trackID,
            timestampMicroseconds: outbound.map(\.timestamp_us).max()
                ?? report.timestamp_us,
            bytesSent: sum(outbound, key: "bytesSent"),
            packetsSent: sum(outbound, key: "packetsSent"),
            framesSent: sum(outbound, key: "framesSent"),
            framesEncoded: sum(outbound, key: "framesEncoded"),
            reportedFramesPerSecond: optionalSum(outbound, key: "framesPerSecond"),
            route: selectedConnectionRoute(in: report)
        )
    }

    private static func selectedConnectionRoute(
        in report: RTCStatisticsReport
    ) -> WebRTCConnectionRoute? {
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
            return nil
        }
        let localType = statistics[localID].flatMap {
            string($0.values["candidateType"])
        }
        let remoteType = statistics[remoteID].flatMap {
            string($0.values["candidateType"])
        }
        guard localType != nil || remoteType != nil else { return nil }
        return localType == "relay" || remoteType == "relay" ? .relay : .direct
    }

    private static func sum(_ statistics: [RTCStatistics], key: String) -> UInt64 {
        statistics.reduce(into: 0) { result, statistic in
            result += number(statistic.values[key])?.uint64Value ?? 0
        }
    }

    private static func optionalSum(
        _ statistics: [RTCStatistics],
        key: String
    ) -> Double? {
        let values = statistics.compactMap { number($0.values[key])?.doubleValue }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private static func number(_ value: NSObject?) -> NSNumber? {
        value as? NSNumber
    }

    private static func string(_ value: NSObject?) -> String? {
        if let value = value as? NSString { return value as String }
        return value as? String
    }
}

enum WebRTCOutboundStatisticsAggregator {
    static func makeSnapshot(
        samples: [WebRTCRawOutboundStatistics],
        slots: [WebRTCStreamSlotSnapshot],
        connectedViewerCount: Int,
        previous: inout [WebRTCOutboundCounterKey: WebRTCOutboundCounter],
        capturedAt: Date
    ) -> WebRTCOutboundStatisticsSnapshot {
        let activeKeys = Set(samples.map(\.key))
        previous = previous.filter { activeKeys.contains($0.key) }

        var viewerStatistics: [WebRTCOutboundCounterKey: WebRTCOutboundViewerStatistics] = [:]
        for sample in samples {
            let rates = rates(current: sample, previous: previous[sample.key])
            viewerStatistics[sample.key] = WebRTCOutboundViewerStatistics(
                viewerID: sample.viewerID,
                bytesSent: sample.bytesSent,
                packetsSent: sample.packetsSent,
                framesSent: sample.framesSent,
                framesEncoded: sample.framesEncoded,
                bitrateBps: rates.bitrateBps,
                framesPerSecond: rates.framesPerSecond ?? sample.reportedFramesPerSecond
            )
            previous[sample.key] = sample.counter
        }

        let slotStatistics = slots.sorted { $0.index < $1.index }.map { slot in
            let viewers = viewerStatistics
                .filter { $0.key.slot == slot.index }
                .map(\.value)
                .sorted { $0.viewerID < $1.viewerID }
            let bitrateValues = viewers.compactMap(\.bitrateBps)
            let fpsValues = viewers.compactMap(\.framesPerSecond)
            return WebRTCOutboundSlotStatistics(
                slot: slot.index,
                trackID: slot.trackID,
                isActive: slot.isActive,
                bytesSent: viewers.reduce(0) { $0 + $1.bytesSent },
                packetsSent: viewers.reduce(0) { $0 + $1.packetsSent },
                framesSent: viewers.reduce(0) { $0 + $1.framesSent },
                framesEncoded: viewers.reduce(0) { $0 + $1.framesEncoded },
                aggregateBitrateBps: bitrateValues.count == viewers.count && !viewers.isEmpty
                    ? bitrateValues.reduce(0, +)
                    : nil,
                averageFramesPerSecond: fpsValues.count == viewers.count && !viewers.isEmpty
                    ? fpsValues.reduce(0, +) / Double(fpsValues.count)
                    : nil,
                viewers: viewers
            )
        }
        return WebRTCOutboundStatisticsSnapshot(
            capturedAt: capturedAt,
            viewerCount: Set(samples.map(\.viewerID)).count,
            connectedViewerCount: connectedViewerCount,
            slots: slotStatistics
        )
    }

    private static func rates(
        current: WebRTCRawOutboundStatistics,
        previous: WebRTCOutboundCounter?
    ) -> (bitrateBps: Double?, framesPerSecond: Double?) {
        guard let previous,
              current.timestampMicroseconds > previous.timestampMicroseconds,
              current.bytesSent >= previous.bytesSent,
              current.framesSent >= previous.framesSent else {
            return (nil, nil)
        }
        let seconds = (current.timestampMicroseconds - previous.timestampMicroseconds)
            / 1_000_000
        guard seconds > 0 else { return (nil, nil) }
        return (
            Double(current.bytesSent - previous.bytesSent) * 8 / seconds,
            Double(current.framesSent - previous.framesSent) / seconds
        )
    }
}
