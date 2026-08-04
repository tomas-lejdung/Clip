import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Clip Live Share native v3 collaboration")
struct ClipLiveShareNativeV3CollaborationTests {
  @Test("closed collaboration codec round trips every message and rejects unknown cases")
  func closedCodec() throws {
    let fixture = try CollaborationFixture()
    let events: [ClipLiveShareNativeV3CollaborationEvent] = [
      .pointer(
        ClipLiveShareNativeV3PointerEvent(
          context: try fixture.context(sequence: 1),
          position: try .init(x: 0.25, y: 0.75)
        )
      ),
      .ping(
        try ClipLiveShareNativeV3PingEvent(
          context: try fixture.context(sequence: 2),
          position: try .init(x: 0.5, y: 0.5),
          color: fixture.color,
          expiresAt: try fixture.now.adding(milliseconds: 1_000)
        )
      ),
      .strokeBegin(
        try ClipLiveShareNativeV3StrokeBeginEvent(
          context: try fixture.context(sequence: 3),
          strokeID: fixture.strokeID,
          point: try .init(x: 0.1, y: 0.2),
          color: fixture.color,
          expiresAt: try fixture.now.adding(milliseconds: 5_000)
        )
      ),
      .strokePoints(
        try ClipLiveShareNativeV3StrokePointsEvent(
          context: try fixture.context(sequence: 4),
          strokeID: fixture.strokeID,
          points: [
            try .init(x: 0.2, y: 0.3),
            try .init(x: 0.3, y: 0.4),
          ]
        )
      ),
      .strokeEnd(
        ClipLiveShareNativeV3StrokeEndEvent(
          context: try fixture.context(sequence: 5),
          strokeID: fixture.strokeID
        )
      ),
      .clear(
        try ClipLiveShareNativeV3ClearEvent(
          context: try fixture.context(sequence: 6),
          clearEpoch: 1,
          scope: .participant
        )
      ),
    ]

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    for event in events {
      let data = try encoder.encode(event)
      #expect(
        try decoder.decode(
          ClipLiveShareNativeV3CollaborationEvent.self,
          from: data
        ) == event
      )
      let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
      )
      #expect(object["version"] as? Int == 3)
      #expect(
        String(decoding: data, as: UTF8.self).contains("sourceGeneration")
          == false
      )
    }

    let unknown = Data(
      #"{"payload":{},"type":"future-pointer-kind","version":3}"#.utf8
    )
    #expect(
      throws: ClipLiveShareNativeV3CollaborationError.unknownMessageType(
        "future-pointer-kind"
      )
    ) {
      _ = try decoder.decode(
        ClipLiveShareNativeV3CollaborationEvent.self,
        from: unknown
      )
    }
  }

  @Test("pointer, ping and stroke state apply transactionally")
  func transactionalState() throws {
    let fixture = try CollaborationFixture()
    var state = fixture.state()

    try state.apply(
      .pointer(
        ClipLiveShareNativeV3PointerEvent(
          context: try fixture.context(sequence: 1),
          position: try .init(x: 0.4, y: 0.6)
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )
    try state.apply(
      .ping(
        try ClipLiveShareNativeV3PingEvent(
          context: try fixture.context(sequence: 2),
          position: try .init(x: 0.4, y: 0.6),
          color: fixture.color,
          expiresAt: try fixture.now.adding(milliseconds: 2_000)
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )
    try state.apply(
      .strokeBegin(
        try ClipLiveShareNativeV3StrokeBeginEvent(
          context: try fixture.context(sequence: 3),
          strokeID: fixture.strokeID,
          point: try .init(x: 0.1, y: 0.1),
          color: fixture.color,
          expiresAt: try fixture.now.adding(milliseconds: 3_000)
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )
    try state.apply(
      .strokePoints(
        try ClipLiveShareNativeV3StrokePointsEvent(
          context: try fixture.context(sequence: 4),
          strokeID: fixture.strokeID,
          points: [
            try .init(x: 0.2, y: 0.2),
            try .init(x: 0.3, y: 0.3),
          ]
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )
    try state.apply(
      .strokeEnd(
        ClipLiveShareNativeV3StrokeEndEvent(
          context: try fixture.context(sequence: 5),
          strokeID: fixture.strokeID
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )

    #expect(state.pointers[fixture.viewer]?.position == (try .init(x: 0.4, y: 0.6)))
    #expect(state.pings.count == 1)
    #expect(state.strokes[fixture.strokeID]?.points.count == 3)
    #expect(state.strokes[fixture.strokeID]?.isComplete == true)

    let before = state
    #expect(
      throws: ClipLiveShareNativeV3CollaborationError.staleSequence(
        expectedGreaterThan: 5,
        actual: 5
      )
    ) {
      try state.apply(
        .ping(
          try ClipLiveShareNativeV3PingEvent(
            context: try fixture.context(sequence: 5),
            position: try .init(x: 0.5, y: 0.5),
            color: fixture.color,
            expiresAt: try fixture.now.adding(milliseconds: 2_000)
          )
        ),
        authenticatedParticipantID: fixture.viewer,
        at: fixture.now
      )
    }
    #expect(state == before)

    // Stale replaceable samples are ignored instead of destabilizing a peer.
    try state.apply(
      .pointer(.init(
        context: try fixture.context(sequence: 1),
        position: nil
      )),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )
    #expect(state == before)
  }

  @Test("replaceable pointers cannot invalidate reliable annotation ordering")
  func pointerAndDurableSequenceLanesAreIndependent() throws {
    let fixture = try CollaborationFixture()
    var state = fixture.state()

    // A high pointer sequence may arrive after earlier samples were dropped.
    try state.apply(
      .pointer(.init(
        context: try fixture.context(sequence: 100),
        position: try .init(x: 0.2, y: 0.4)
      )),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )

    // The reliable lane starts independently, so its first ping remains valid.
    try state.apply(
      .ping(try .init(
        context: try fixture.context(sequence: 1),
        position: try .init(x: 0.3, y: 0.5),
        color: fixture.color,
        expiresAt: try fixture.now.adding(milliseconds: 2_000)
      )),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )

    #expect(state.pointers[fixture.viewer] != nil)
    #expect(state.pings.count == 1)
  }

  @Test("authenticated sender and source instance cannot be forged")
  func authenticatedContext() throws {
    let fixture = try CollaborationFixture()
    var state = fixture.state()
    let event = ClipLiveShareNativeV3CollaborationEvent.pointer(
      ClipLiveShareNativeV3PointerEvent(
        context: try fixture.context(sequence: 1),
        position: try .init(x: 0.5, y: 0.5)
      )
    )

    #expect(
      throws: ClipLiveShareNativeV3CollaborationError.participantMismatch
    ) {
      try state.apply(
        event,
        authenticatedParticipantID: fixture.publisher,
        at: fixture.now
      )
    }
    #expect(state.pointers.isEmpty)

    let otherSource = ClipLiveShareNativeV3SourceKey(
      ownerParticipantID: fixture.publisher,
      sourceInstanceID: .random()
    )
    let wrongSource = ClipLiveShareNativeV3CollaborationEvent.pointer(
      ClipLiveShareNativeV3PointerEvent(
        context: try fixture.context(sourceKey: otherSource, sequence: 1),
        position: try .init(x: 0.5, y: 0.5)
      )
    )
    #expect(throws: ClipLiveShareNativeV3CollaborationError.sourceMismatch) {
      try state.apply(
        wrongSource,
        authenticatedParticipantID: fixture.viewer,
        at: fixture.now
      )
    }
    #expect(state.pointers.isEmpty)
  }

  @Test("stroke chunks and active state are bounded")
  func bounds() throws {
    let fixture = try CollaborationFixture()
    let point = try ClipLiveShareNativeV3NormalizedPoint(x: 0.5, y: 0.5)
    #expect(
      throws: ClipLiveShareNativeV3CollaborationError.pointLimit(
        maximum:
          ClipLiveShareNativeV3CollaborationLimits.maximumPointsPerStrokeChunk,
        actual:
          ClipLiveShareNativeV3CollaborationLimits.maximumPointsPerStrokeChunk + 1
      )
    ) {
      _ = try ClipLiveShareNativeV3StrokePointsEvent(
        context: try fixture.context(sequence: 1),
        strokeID: fixture.strokeID,
        points: Array(
          repeating: point,
          count:
            ClipLiveShareNativeV3CollaborationLimits.maximumPointsPerStrokeChunk + 1
        )
      )
    }

    var state = fixture.state()
    for index in 0..<ClipLiveShareNativeV3CollaborationLimits.maximumActiveStrokesPerSource {
      try state.apply(
        .strokeBegin(
          try ClipLiveShareNativeV3StrokeBeginEvent(
            context: try fixture.context(sequence: UInt64(index + 1)),
            strokeID: .init(),
            point: point,
            color: fixture.color,
            expiresAt: try fixture.now.adding(milliseconds: 10_000)
          )
        ),
        authenticatedParticipantID: fixture.viewer,
        at: fixture.now
      )
    }
    let before = state
    #expect(
      throws: ClipLiveShareNativeV3CollaborationError.strokeLimit(
        maximum:
          ClipLiveShareNativeV3CollaborationLimits.maximumActiveStrokesPerSource,
        actual:
          ClipLiveShareNativeV3CollaborationLimits.maximumActiveStrokesPerSource
            + 1
      )
    ) {
      try state.apply(
        .strokeBegin(
          try ClipLiveShareNativeV3StrokeBeginEvent(
            context: try fixture.context(
              sequence: UInt64(
                ClipLiveShareNativeV3CollaborationLimits
                  .maximumActiveStrokesPerSource + 1
              )
            ),
            strokeID: .init(),
            point: point,
            color: fixture.color,
            expiresAt: try fixture.now.adding(milliseconds: 10_000)
          )
        ),
        authenticatedParticipantID: fixture.viewer,
        at: fixture.now
      )
    }
    #expect(state == before)
  }

  @Test("participant clear and membership removal affect only owned state")
  func clearAndMembershipRemoval() throws {
    let fixture = try CollaborationFixture()
    let other = try participantID(3)
    var state = fixture.state()
    try state.apply(
      .pointer(
        ClipLiveShareNativeV3PointerEvent(
          context: try fixture.context(sequence: 1),
          position: try .init(x: 0.1, y: 0.1)
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )
    try state.apply(
      .pointer(
        ClipLiveShareNativeV3PointerEvent(
          context: try fixture.context(
            participantID: other,
            sequence: 1
          ),
          position: try .init(x: 0.9, y: 0.9)
        )
      ),
      authenticatedParticipantID: other,
      at: fixture.now
    )
    try state.apply(
      .clear(
        try ClipLiveShareNativeV3ClearEvent(
          context: try fixture.context(sequence: 2),
          clearEpoch: 1,
          scope: .participant
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )
    #expect(state.pointers[fixture.viewer] == nil)
    #expect(state.pointers[other] != nil)

    state.retainParticipants([fixture.viewer])
    #expect(state.pointers.isEmpty)
  }

  @Test("expired transient state is removed")
  func expiry() throws {
    let fixture = try CollaborationFixture()
    var state = fixture.state()
    try state.apply(
      .ping(
        try ClipLiveShareNativeV3PingEvent(
          context: try fixture.context(sequence: 1),
          position: try .init(x: 0.5, y: 0.5),
          color: fixture.color,
          expiresAt: try fixture.now.adding(milliseconds: 100)
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )
    state.pruneExpired(at: try fixture.now.adding(milliseconds: 101))
    #expect(state.pings.isEmpty)
  }

  @Test("stationary pointer expires defensively after two seconds")
  func pointerInactivityExpiry() throws {
    let fixture = try CollaborationFixture()
    var state = fixture.state()
    // The receiver clock is deliberately ahead of the sender. The activity
    // lease starts at local observation time, not at a cross-device wall clock.
    let observedAt = try fixture.now.adding(milliseconds: 10_000)
    try state.apply(
      .pointer(.init(
        context: try fixture.context(sequence: 1),
        position: try .init(x: 0.25, y: 0.75)
      )),
      authenticatedParticipantID: fixture.viewer,
      at: observedAt
    )

    let beforeExpiry = try observedAt.adding(
      milliseconds:
        ClipLiveShareNativeV3CollaborationLimits
          .pointerInactivityTimeoutMilliseconds - 1
    )
    #expect(state.pruneExpired(at: beforeExpiry) == false)
    #expect(state.pointers[fixture.viewer] != nil)

    let atExpiry = try observedAt.adding(
      milliseconds:
        ClipLiveShareNativeV3CollaborationLimits
          .pointerInactivityTimeoutMilliseconds
    )
    let didExpirePointer = state.pruneExpired(at: atExpiry)
    #expect(didExpirePointer)
    #expect(state.pointers.isEmpty)

    // Expiry removes only presentation state. The sequence ledger remains so
    // a delayed older pointer sample cannot resurrect the cursor.
    try state.apply(
      .pointer(.init(
        context: try fixture.context(sequence: 1),
        position: try .init(x: 0.5, y: 0.5)
      )),
      authenticatedParticipantID: fixture.viewer,
      at: atExpiry
    )
    #expect(state.pointers.isEmpty)
  }

  @Test("a fresh source instance owns a fresh sequence ledger")
  func sourceInstanceResetsSequenceLedger() throws {
    let fixture = try CollaborationFixture()
    var original = fixture.state()
    try original.apply(
      .pointer(
        .init(
          context: try fixture.context(sequence: 1),
          position: try .init(x: 0.25, y: 0.75)
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )

    let replacementSource = ClipLiveShareNativeV3SourceKey(
      ownerParticipantID: fixture.publisher,
      sourceInstanceID: .random()
    )
    var replacement = ClipLiveShareNativeV3CollaborationState(
      sessionID: fixture.sessionID,
      sourceKey: replacementSource
    )
    try replacement.apply(
      .pointer(
        .init(
          context: try fixture.context(
            sourceKey: replacementSource,
            sequence: 1
          ),
          position: try .init(x: 0.5, y: 0.5)
        )
      ),
      authenticatedParticipantID: fixture.viewer,
      at: fixture.now
    )

    #expect(replacement.pointers[fixture.viewer] != nil)
  }
}

private struct CollaborationFixture {
  let sessionID = ClipLiveShareSessionID.random()
  let publisher: ClipLiveShareNativeV3ParticipantID
  let viewer: ClipLiveShareNativeV3ParticipantID
  let sourceKey: ClipLiveShareNativeV3SourceKey
  let now: ClipLiveShareNativeTimestamp
  let color: ClipLiveShareNativeV3CollaborationColor
  let strokeID = ClipLiveShareNativeV3StrokeID(
    rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
  )

  init() throws {
    publisher = try participantID(1)
    viewer = try participantID(2)
    sourceKey = ClipLiveShareNativeV3SourceKey(
      ownerParticipantID: publisher,
      sourceInstanceID: try ClipLiveShareSourceInstanceID(
        bytes: Data(
          repeating: 7,
          count: 16
        )
      )
    )
    now = try ClipLiveShareNativeTimestamp(millisecondsSince1970: 1_000_000)
    color = try ClipLiveShareNativeV3CollaborationColor(
      red: 120,
      green: 80,
      blue: 230
    )
  }

  func context(
    participantID: ClipLiveShareNativeV3ParticipantID? = nil,
    sourceKey: ClipLiveShareNativeV3SourceKey? = nil,
    sequence: UInt64
  ) throws -> ClipLiveShareNativeV3CollaborationContext {
    try ClipLiveShareNativeV3CollaborationContext(
      sessionID: sessionID,
      participantID: participantID ?? viewer,
      sourceKey: sourceKey ?? self.sourceKey,
      sequence: sequence,
      sentAt: now
    )
  }

  func state() -> ClipLiveShareNativeV3CollaborationState {
    ClipLiveShareNativeV3CollaborationState(
      sessionID: sessionID,
      sourceKey: sourceKey
    )
  }
}

private func participantID(
  _ byte: UInt8
) throws -> ClipLiveShareNativeV3ParticipantID {
  try ClipLiveShareNativeV3ParticipantID(
    bytes: Data(
      repeating: byte,
      count: ClipLiveShareNativeV3.participantIDByteCount
    )
  )
}
