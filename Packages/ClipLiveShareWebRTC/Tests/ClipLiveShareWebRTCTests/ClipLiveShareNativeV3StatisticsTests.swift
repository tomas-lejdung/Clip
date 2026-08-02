import Foundation
import Testing

@testable import ClipLiveShareWebRTC

@Suite("Native-v3 per-source WebRTC statistics")
struct ClipLiveShareNativeV3StatisticsTests {
  @Test("parser keeps honest directional source measurements")
  func parsesDirectionalVideoSources() throws {
    let capturedAt = Date(timeIntervalSince1970: 100)
    let statistics = ClipLiveShareNativeV3WebRTCStatisticsParser.parse(
      [
        sample(
          "codec-out",
          "codec",
          ["mimeType": "video/H264"]
        ),
        sample(
          "codec-in",
          "codec",
          ["mimeType": "video/VP9"]
        ),
        sample(
          "source-out",
          "media-source",
          ["trackIdentifier": "outgoing-track"]
        ),
        sample(
          "outbound",
          "outbound-rtp",
          [
            "kind": "video",
            "mediaSourceId": "source-out",
            "codecId": "codec-out",
            "frameWidth": 1920,
            "frameHeight": 1080,
            "framesPerSecond": 29.8,
            "bytesSent": 10_000,
            "packetsSent": 90,
            "framesEncoded": 30,
            "framesDropped": 2,
            "framesDiscardedOnSend": 3,
            "totalEncodeTime": 1.5,
            "qualityLimitationReason": "bandwidth",
          ]
        ),
        sample(
          "remote-inbound",
          "remote-inbound-rtp",
          [
            "localId": "outbound",
            "packetsLost": 4,
          ]
        ),
        sample(
          "inbound",
          "inbound-rtp",
          [
            "kind": "video",
            "mid": "1",
            "codecId": "codec-in",
            "frameWidth": 1280,
            "frameHeight": 720,
            "framesPerSecond": 24.5,
            "bytesReceived": 8_000,
            "packetsReceived": 80,
            "packetsLost": 5,
            "framesDecoded": 30,
            "framesDropped": 6,
            "jitterBufferDelay": 0.9,
            "jitterBufferEmittedCount": 30,
          ]
        ),
        sample(
          "selected-pair",
          "candidate-pair",
          [
            "selected": true,
            "localCandidateId": "local-candidate",
            "remoteCandidateId": "remote-candidate",
            "currentRoundTripTime": 0.075,
            "availableOutgoingBitrate": 2_000_000,
          ]
        ),
        sample(
          "local-candidate",
          "local-candidate",
          ["candidateType": "host"]
        ),
        sample(
          "remote-candidate",
          "remote-candidate",
          ["candidateType": "relay"]
        ),
      ],
      capturedAt: capturedAt,
      trackIdentifiersByMID: .init(
        incoming: ["1": "incoming-track"]
      )
    )

    #expect(statistics.capturedAt == capturedAt)
    #expect(statistics.route == .relay)
    #expect(statistics.bytesSent == 10_000)
    #expect(statistics.bytesReceived == 8_000)
    #expect(statistics.currentRoundTripTimeMilliseconds == 75)
    #expect(statistics.videoSources.count == 2)

    let outgoing = try #require(
      statistics.videoSources.first { $0.direction == .outgoing }
    )
    #expect(outgoing.trackIdentifier == "outgoing-track")
    #expect(outgoing.codec == "H264")
    #expect(outgoing.width == 1920)
    #expect(outgoing.height == 1080)
    #expect(outgoing.framesPerSecond == 29.8)
    #expect(outgoing.bytes == 10_000)
    #expect(outgoing.frames == 30)
    #expect(outgoing.droppedFrames == 2)
    #expect(outgoing.queuePressureDrops == 3)
    #expect(outgoing.packetsLost == 4)
    #expect(outgoing.processingLatencyMilliseconds == 50)
    #expect(outgoing.queuePressureReason == "bandwidth")

    let incoming = try #require(
      statistics.videoSources.first { $0.direction == .incoming }
    )
    #expect(incoming.trackIdentifier == "incoming-track")
    #expect(incoming.codec == "VP9")
    #expect(incoming.width == 1280)
    #expect(incoming.height == 720)
    #expect(incoming.framesPerSecond == 24.5)
    #expect(incoming.droppedFrames == 6)
    #expect(incoming.queuePressureDrops == 0)
    #expect(incoming.packetsLost == 5)
    #expect(incoming.processingLatencyMilliseconds == 30)
    #expect(incoming.queuePressureReason == nil)
  }

  @Test("MID mappings override generated RTP track identifiers")
  func authoritativeMIDMappingsOverrideGeneratedTrackIdentifiers() throws {
    let statistics = ClipLiveShareNativeV3WebRTCStatisticsParser.parse(
      [
        sample(
          "outbound",
          "outbound-rtp",
          [
            "kind": "video",
            "mid": "0",
            "trackIdentifier": "generated-sender-track",
          ]
        ),
        sample(
          "inbound",
          "inbound-rtp",
          [
            "kind": "video",
            "mid": "1",
            "trackIdentifier": "generated-receiver-track",
          ]
        ),
      ],
      capturedAt: Date(timeIntervalSince1970: 101),
      trackIdentifiersByMID: .init(
        outgoing: ["0": "stable-outgoing-track"],
        incoming: ["1": "stable-incoming-track"]
      )
    )

    #expect(
      statistics.videoSources.first { $0.direction == .outgoing }?
        .trackIdentifier == "stable-outgoing-track"
    )
    #expect(
      statistics.videoSources.first { $0.direction == .incoming }?
        .trackIdentifier == "stable-incoming-track"
    )
  }

  @Test("standard transport stats select the active candidate pair")
  func transportSelectedCandidatePairDeterminesRoute() {
    let statistics = ClipLiveShareNativeV3WebRTCStatisticsParser.parse(
      [
        sample(
          "transport",
          "transport",
          ["selectedCandidatePairId": "active-pair"]
        ),
        sample(
          "active-pair",
          "candidate-pair",
          [
            "localCandidateId": "local-candidate",
            "remoteCandidateId": "remote-candidate",
            "currentRoundTripTime": 0.012,
          ]
        ),
        sample(
          "local-candidate",
          "local-candidate",
          ["candidateType": "host"]
        ),
        sample(
          "remote-candidate",
          "remote-candidate",
          ["candidateType": "relay"]
        ),
      ],
      capturedAt: Date(timeIntervalSince1970: 102)
    )

    #expect(statistics.route == .relay)
    #expect(statistics.currentRoundTripTimeMilliseconds == 12)
  }

  @Test("transport snapshot bounds and deduplicates each direction")
  func boundsDirectionalSources() {
    let outgoing = (0..<8).map {
      source(.outgoing, trackIdentifier: "out-\($0)")
    }
    let incoming = (0..<8).map {
      source(.incoming, trackIdentifier: "in-\($0)")
    }
    let statistics = ClipLiveShareNativeV3PeerLinkTransportStatistics(
      capturedAt: Date(timeIntervalSince1970: 0),
      videoSources: outgoing + [outgoing[0]] + incoming + [incoming[0]]
    )

    #expect(
      statistics.videoSources.count(where: { $0.direction == .outgoing })
        == 4
    )
    #expect(
      statistics.videoSources.count(where: { $0.direction == .incoming })
        == 4
    )
    #expect(Set(statistics.videoSources.map(\.trackIdentifier)).count == 8)
  }

  private func source(
    _ direction: ClipLiveShareNativeV3MediaStatisticsDirection,
    trackIdentifier: String
  ) -> ClipLiveShareNativeV3VideoSourceStatistics {
    .init(
      direction: direction,
      trackIdentifier: trackIdentifier
    )
  }

  private func sample(
    _ id: String,
    _ type: String,
    _ values: [String: Any]
  ) -> ClipLiveShareNativeV3WebRTCStatisticSample {
    .init(
      id: id,
      type: type,
      values: values.mapValues { value in
        if let value = value as? NSObject { return value }
        preconditionFailure("RTC test statistic values must bridge to NSObject")
      }
    )
  }
}
