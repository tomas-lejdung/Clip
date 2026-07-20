import Foundation
@preconcurrency import WebRTC

struct WebRTCOutboundCounterKey: Hashable, Sendable {
    let viewerID: String
    let slot: Int
}

struct WebRTCOutboundCounter: Equatable, Sendable {
    let timestampMicroseconds: Double
    let bytesSent: UInt64
    let packetsSent: UInt64
    let framesSent: UInt64
    let framesEncoded: UInt64
    let framesDroppedByEncoder: UInt64?
    let totalEncodeTimeSeconds: Double?
    let totalPacketSendDelaySeconds: Double?

    init(
        timestampMicroseconds: Double,
        bytesSent: UInt64,
        packetsSent: UInt64 = 0,
        framesSent: UInt64,
        framesEncoded: UInt64 = 0,
        framesDroppedByEncoder: UInt64? = nil,
        totalEncodeTimeSeconds: Double? = nil,
        totalPacketSendDelaySeconds: Double? = nil
    ) {
        self.timestampMicroseconds = timestampMicroseconds
        self.bytesSent = bytesSent
        self.packetsSent = packetsSent
        self.framesSent = framesSent
        self.framesEncoded = framesEncoded
        self.framesDroppedByEncoder = framesDroppedByEncoder
        self.totalEncodeTimeSeconds = totalEncodeTimeSeconds
        self.totalPacketSendDelaySeconds = totalPacketSendDelaySeconds
    }
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
    let targetBitrateBps: Double?
    let framesDroppedByEncoder: UInt64?
    let totalEncodeTimeSeconds: Double?
    let totalPacketSendDelaySeconds: Double?
    let qualityLimitationReason: String?
    let codec: String?
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
        targetBitrateBps: Double? = nil,
        framesDroppedByEncoder: UInt64? = nil,
        totalEncodeTimeSeconds: Double? = nil,
        totalPacketSendDelaySeconds: Double? = nil,
        qualityLimitationReason: String? = nil,
        codec: String? = nil,
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
        self.targetBitrateBps = targetBitrateBps
        self.framesDroppedByEncoder = framesDroppedByEncoder
        self.totalEncodeTimeSeconds = totalEncodeTimeSeconds
        self.totalPacketSendDelaySeconds = totalPacketSendDelaySeconds
        self.qualityLimitationReason = qualityLimitationReason
        self.codec = codec
        self.route = route
    }

    var key: WebRTCOutboundCounterKey {
        .init(viewerID: viewerID, slot: slot)
    }

    var counter: WebRTCOutboundCounter {
        .init(
            timestampMicroseconds: timestampMicroseconds,
            bytesSent: bytesSent,
            packetsSent: packetsSent,
            framesSent: framesSent,
            framesEncoded: framesEncoded,
            framesDroppedByEncoder: framesDroppedByEncoder,
            totalEncodeTimeSeconds: totalEncodeTimeSeconds,
            totalPacketSendDelaySeconds: totalPacketSendDelaySeconds
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
            targetBitrateBps: optionalSum(outbound, key: "targetBitrate"),
            // The WebRTC stats standard used `framesDroppedByEncoder`; the
            // pinned native framework currently publishes `framesDropped`.
            // Accept both so the diagnostic does not silently disappear when
            // the bundled binary and browser-facing spec use different names.
            framesDroppedByEncoder: optionalUInt64Sum(
                outbound,
                key: "framesDroppedByEncoder"
            ) ?? optionalUInt64Sum(outbound, key: "framesDropped"),
            totalEncodeTimeSeconds: optionalSum(outbound, key: "totalEncodeTime"),
            totalPacketSendDelaySeconds: optionalSum(
                outbound,
                key: "totalPacketSendDelay"
            ),
            qualityLimitationReason: outbound.lazy.compactMap {
                string($0.values["qualityLimitationReason"])
            }.first,
            codec: codecName(for: outbound, in: report),
            route: selectedConnectionRoute(in: report)
        )
    }

    private static func codecName(
        for outbound: [RTCStatistics],
        in report: RTCStatisticsReport
    ) -> String? {
        for statistic in outbound {
            guard let codecID = string(statistic.values["codecId"]),
                  let codec = report.statistics[codecID],
                  let mimeType = string(codec.values["mimeType"]) else {
                continue
            }
            return mimeType.split(separator: "/").last.map(String.init) ?? mimeType
        }
        return nil
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

    private static func optionalUInt64Sum(
        _ statistics: [RTCStatistics],
        key: String
    ) -> UInt64? {
        let values = statistics.compactMap { number($0.values[key])?.uint64Value }
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
        capturedAt: Date,
        h264SubmissionBackpressureDrops: UInt64 = 0
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
                framesPerSecond: rates.framesPerSecond ?? sample.reportedFramesPerSecond,
                targetBitrateBps: sample.targetBitrateBps,
                averageEncodeTimeMilliseconds: rates.averageEncodeTimeMilliseconds,
                averagePacketSendDelayMilliseconds: rates
                    .averagePacketSendDelayMilliseconds,
                encoderDroppedFrames: rates.encoderDroppedFrames,
                qualityLimitationReason: sample.qualityLimitationReason,
                codec: sample.codec
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
            let targetBitrateValues = viewers.compactMap(\.targetBitrateBps)
            let encodeTimeValues = viewers.compactMap(\.averageEncodeTimeMilliseconds)
            let packetDelayValues = viewers.compactMap(
                \.averagePacketSendDelayMilliseconds
            )
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
                aggregateTargetBitrateBps: targetBitrateValues.count == viewers.count
                    && !viewers.isEmpty
                    ? targetBitrateValues.reduce(0, +)
                    : nil,
                averageEncodeTimeMilliseconds: encodeTimeValues.isEmpty
                    ? nil
                    : encodeTimeValues.reduce(0, +) / Double(encodeTimeValues.count),
                averagePacketSendDelayMilliseconds: packetDelayValues.isEmpty
                    ? nil
                    : packetDelayValues.reduce(0, +) / Double(packetDelayValues.count),
                encoderDroppedFrames: viewers.reduce(0) {
                    $0 + ($1.encoderDroppedFrames ?? 0)
                },
                qualityLimitationReasons: Array(Set(viewers.compactMap {
                    $0.qualityLimitationReason
                })).sorted(),
                codecs: Array(Set(viewers.compactMap(\.codec))).sorted(),
                viewers: viewers
            )
        }
        return WebRTCOutboundStatisticsSnapshot(
            capturedAt: capturedAt,
            viewerCount: Set(samples.map(\.viewerID)).count,
            connectedViewerCount: connectedViewerCount,
            slots: slotStatistics,
            h264SubmissionBackpressureDrops: h264SubmissionBackpressureDrops
        )
    }

    private static func rates(
        current: WebRTCRawOutboundStatistics,
        previous: WebRTCOutboundCounter?
    ) -> (
        bitrateBps: Double?,
        framesPerSecond: Double?,
        averageEncodeTimeMilliseconds: Double?,
        averagePacketSendDelayMilliseconds: Double?,
        encoderDroppedFrames: UInt64?
    ) {
        guard let previous,
              current.timestampMicroseconds > previous.timestampMicroseconds,
              current.bytesSent >= previous.bytesSent,
              current.framesSent >= previous.framesSent else {
            return (nil, nil, nil, nil, nil)
        }
        let seconds = (current.timestampMicroseconds - previous.timestampMicroseconds)
            / 1_000_000
        guard seconds > 0 else { return (nil, nil, nil, nil, nil) }
        let encodedFrameDelta = current.framesEncoded >= previous.framesEncoded
            ? current.framesEncoded - previous.framesEncoded
            : 0
        let packetDelta = current.packetsSent >= previous.packetsSent
            ? current.packetsSent - previous.packetsSent
            : 0
        return (
            Double(current.bytesSent - previous.bytesSent) * 8 / seconds,
            Double(current.framesSent - previous.framesSent) / seconds,
            averageDeltaMilliseconds(
                current: current.totalEncodeTimeSeconds,
                previous: previous.totalEncodeTimeSeconds,
                count: encodedFrameDelta
            ),
            averageDeltaMilliseconds(
                current: current.totalPacketSendDelaySeconds,
                previous: previous.totalPacketSendDelaySeconds,
                count: packetDelta
            ),
            counterDelta(
                current: current.framesDroppedByEncoder,
                previous: previous.framesDroppedByEncoder
            )
        )
    }

    private static func averageDeltaMilliseconds(
        current: Double?,
        previous: Double?,
        count: UInt64
    ) -> Double? {
        guard let current, let previous, current >= previous, count > 0 else {
            return nil
        }
        return (current - previous) * 1_000 / Double(count)
    }

    private static func counterDelta(
        current: UInt64?,
        previous: UInt64?
    ) -> UInt64? {
        guard let current, let previous, current >= previous else { return nil }
        return current - previous
    }
}
