import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Native-v3 signed multi-process acceptance reports")
struct ClipLiveShareNativeV3AcceptanceReportTests {
  @Test("signed report round-trips and verifies its participant identity")
  func signedReportRoundTrip() throws {
    let fixture = try NativeV3AcceptanceReportFixture(participantCount: 3)
    let report = try fixture.report(for: 0, stage: .ready)
    let encoded = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(
      ClipLiveShareSignedNativeV3AcceptanceReport.self,
      from: encoded
    )

    #expect(decoded == report)
    try decoded.verify(expectedRunIdentifier: fixture.runIdentifier)
    #expect(decoded.payload.committedMemberCount == 3)
    #expect(decoded.payload.expectedPeerLinkCount == 2)
    #expect(decoded.payload.peerLinks.count == 2)
    #expect(decoded.payload.remoteMedia.count == 2)
  }

  @Test("ready and final stages validate one exact three-participant mesh")
  func completeThreeParticipantRun() throws {
    let fixture = try NativeV3AcceptanceReportFixture(participantCount: 3)
    let labels = Set(fixture.labels)
    let readyReports = try fixture.reports(stage: .ready)
    let ready = try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
      readyReports,
      expectedRunIdentifier: fixture.runIdentifier,
      expectedProcessLabels: labels,
      expectedLocalAudioTrackCount: 0,
      stage: .ready
    )
    #expect(ready.participantCount == 3)
    #expect(ready.totalPeerLinkReports == 6)
    #expect(ready.membershipRevision.rawValue == 1)
    #expect(ready.stage == .ready)

    let finalReports = try fixture.reports(stage: .final)
    let final = try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
      finalReports,
      expectedRunIdentifier: fixture.runIdentifier,
      expectedProcessLabels: labels,
      expectedLocalAudioTrackCount: 0,
      stage: .final
    )
    #expect(final.participantCount == 3)
    #expect(final.totalPeerLinkReports == 6)
    #expect(final.stage == .final)
  }

  @Test("four participants report all twelve local peer-link views")
  func completeFourParticipantRun() throws {
    let fixture = try NativeV3AcceptanceReportFixture(participantCount: 4)
    let summary = try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
      fixture.reports(stage: .ready),
      expectedRunIdentifier: fixture.runIdentifier,
      expectedProcessLabels: Set(fixture.labels),
      expectedLocalAudioTrackCount: 0,
      stage: .ready
    )
    #expect(summary.participantCount == 4)
    #expect(summary.totalPeerLinkReports == 12)
  }

  @Test("parser rejects a forged derived membership count")
  func forgedDerivedCount() throws {
    let fixture = try NativeV3AcceptanceReportFixture(participantCount: 3)
    let payload = try fixture.report(for: 0, stage: .ready).payload
    let encoded = try JSONEncoder().encode(payload)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["committedMemberCount"] = 4
    let forged = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ClipLiveShareNativeV3AcceptanceReportError.self) {
      try JSONDecoder().decode(
        ClipLiveShareNativeV3AcceptanceReportPayload.self,
        from: forged
      )
    }
  }

  @Test("validator rejects wrong run and participant signatures")
  func wrongRunAndSignature() throws {
    let fixture = try NativeV3AcceptanceReportFixture(participantCount: 3)
    let report = try fixture.report(for: 0, stage: .ready)
    #expect(
      throws: ClipLiveShareNativeV3AcceptanceReportError
        .runIdentifierMismatch
    ) {
      try report.verify(
        expectedRunIdentifier: "another-acceptance-run"
      )
    }

    let forged = ClipLiveShareSignedNativeV3AcceptanceReport(
      payload: report.payload,
      signature: try fixture.signers[1].signature(
        for: Data("not-the-report".utf8)
      )
    )
    #expect(
      throws: ClipLiveShareNativeV3AcceptanceReportError.invalidSignature
    ) {
      try forged.verify(expectedRunIdentifier: fixture.runIdentifier)
    }
  }

  @Test("validator fails on missing, inconsistent, or non-ready reports")
  func inconsistentRun() throws {
    let fixture = try NativeV3AcceptanceReportFixture(participantCount: 3)
    let reports = try fixture.reports(stage: .ready)
    let labels = Set(fixture.labels)

    #expect(
      throws: ClipLiveShareNativeV3AcceptanceReportError.missingReport
    ) {
      try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
        Array(reports.dropLast()),
        expectedRunIdentifier: fixture.runIdentifier,
        expectedProcessLabels: labels,
        expectedLocalAudioTrackCount: 0,
        stage: .ready
      )
    }

    var wrongMedia = fixture.mediaCounts
    wrongMedia[1] = (sourceCount: 4, audioTrackCount: 1)
    let inconsistent = [
      try fixture.report(
        for: 0,
        stage: .ready,
        observedMediaCounts: wrongMedia
      ),
      reports[1],
      reports[2],
    ]
    #expect(
      throws:
        ClipLiveShareNativeV3AcceptanceReportError.inconsistentMediaCounts
    ) {
      try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
        inconsistent,
        expectedRunIdentifier: fixture.runIdentifier,
        expectedProcessLabels: labels,
        expectedLocalAudioTrackCount: 0,
        stage: .ready
      )
    }

    let failed = try fixture.report(
      for: 0,
      stage: .ready,
      isReady: false
    )
    #expect(
      throws: ClipLiveShareNativeV3AcceptanceReportError.self
    ) {
      try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
        [failed, reports[1], reports[2]],
        expectedRunIdentifier: fixture.runIdentifier,
        expectedProcessLabels: labels,
        expectedLocalAudioTrackCount: 0,
        stage: .ready
      )
    }
  }

  @Test("real publication requires a source from every participant")
  func rejectsAllZeroSourceRoom() throws {
    let fixture = try NativeV3AcceptanceReportFixture(
      participantCount: 3,
      sourceCount: 0
    )

    #expect(
      throws: ClipLiveShareNativeV3AcceptanceReportError.self
    ) {
      try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
        fixture.reports(stage: .ready),
        expectedRunIdentifier: fixture.runIdentifier,
        expectedProcessLabels: Set(fixture.labels),
        expectedLocalAudioTrackCount: 0,
        stage: .ready
      )
    }
  }

  @Test("audio publication is an explicit per-run expectation")
  func explicitAudioExpectation() throws {
    let fixture = try NativeV3AcceptanceReportFixture(
      participantCount: 3,
      audioTrackCount: 1
    )

    let summary = try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
      fixture.reports(stage: .ready),
      expectedRunIdentifier: fixture.runIdentifier,
      expectedProcessLabels: Set(fixture.labels),
      expectedLocalAudioTrackCount: 1,
      stage: .ready
    )
    #expect(summary.participantCount == 3)

    #expect(
      throws: ClipLiveShareNativeV3AcceptanceReportError.self
    ) {
      try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
        fixture.reports(stage: .ready),
        expectedRunIdentifier: fixture.runIdentifier,
        expectedProcessLabels: Set(fixture.labels),
        expectedLocalAudioTrackCount: 0,
        stage: .ready
      )
    }
  }
}

private struct NativeV3AcceptanceReportFixture {
  enum Stage {
    case ready
    case final
  }

  let runIdentifier = "native-v3-report-run-0001"
  let labels: [String]
  let signers: [ClipLiveShareSoftwareIdentitySigner]
  let participants: [ClipLiveShareNativeV3Participant]
  let membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  let origin: ClipLiveShareNativeTimestamp
  let mediaCounts: [(sourceCount: Int, audioTrackCount: Int)]

  init(
    participantCount: Int,
    sourceCount: Int? = nil,
    audioTrackCount: Int = 0
  ) throws {
    precondition((3...4).contains(participantCount))
    let originValue = try ClipLiveShareNativeTimestamp(
      millisecondsSince1970: 1_750_000_000_000
    )
    let labelValues = (0..<participantCount).map {
      "participant-\(UnicodeScalar(97 + $0)!)"
    }
    let signerValues = try (0..<participantCount).map {
      try ClipLiveShareSoftwareIdentitySigner(
        rawRepresentation: Data(
          repeating: UInt8($0 + 1),
          count: 32
        )
      )
    }
    let participantValues = try signerValues.enumerated().map {
      index, signer in
      try ClipLiveShareNativeV3Participant(
        participantID: ClipLiveShareNativeV3ParticipantID(
          bytes: Data(repeating: UInt8(index + 0x21), count: 16)
        ),
        identity: signer.publicKey,
        displayName: "Participant \(index + 1)",
        capabilities: .current
      )
    }
    let mediaCountValues = (0..<participantCount).map {
      (
        sourceCount: sourceCount ?? ($0 + 1),
        audioTrackCount: audioTrackCount
      )
    }

    let sessionID = try ClipLiveShareSessionID(
      rawValue: ClipLiveShareBase64URL.encode(
        Data(repeating: 0xA5, count: 16)
      )
    )
    let revision = try ClipLiveShareNativeV3MembershipRevision(rawValue: 1)
    let leader = participantValues[0]
    let credentials = try participantValues.map { participant in
      let credential = try ClipLiveShareNativeV3MembershipCredential(
        sessionID: sessionID,
        leaderParticipantID: leader.participantID,
        leaderIdentity: leader.identity,
        participant: participant,
        membershipRevision: revision,
        issuedAt: originValue,
        expiresAt: originValue.adding(milliseconds: 180_000)
      )
      return try ClipLiveShareSignedNativeV3MembershipCredential(
        signing: credential,
        with: signerValues[0]
      )
    }
    let snapshot = try ClipLiveShareNativeV3MembershipSnapshot(
      sessionID: sessionID,
      leaderParticipantID: leader.participantID,
      leaderIdentity: leader.identity,
      membershipRevision: revision,
      credentials: credentials,
      issuedAt: originValue,
      expiresAt: originValue.adding(milliseconds: 120_000),
      maximumParticipants: 4
    )
    let membershipValue = try ClipLiveShareSignedNativeV3MembershipSnapshot(
      signing: snapshot,
      with: signerValues[0]
    )
    origin = originValue
    labels = labelValues
    signers = signerValues
    participants = participantValues
    mediaCounts = mediaCountValues
    membership = membershipValue
  }

  func reports(
    stage: Stage
  ) throws -> [ClipLiveShareSignedNativeV3AcceptanceReport] {
    try participants.indices.map { try report(for: $0, stage: stage) }
  }

  func report(
    for index: Int,
    stage: Stage,
    observedMediaCounts:
      [(sourceCount: Int, audioTrackCount: Int)]? = nil,
    isReady: Bool = true
  ) throws -> ClipLiveShareSignedNativeV3AcceptanceReport {
    let local = participants[index]
    let observedMediaCounts = observedMediaCounts ?? mediaCounts
    let remoteIndices = participants.indices.filter { $0 != index }
    let links = remoteIndices.map {
      ClipLiveShareNativeV3AcceptanceReportPayload.PeerLink(
        remoteParticipantID: participants[$0].participantID,
        connectionState: isReady ? .connected : .connecting,
        isReady: isReady,
        route: isReady ? .direct : .unknown
      )
    }
    let remotes = try remoteIndices.map {
      try ClipLiveShareNativeV3AcceptanceReportPayload.RemoteMedia(
        participantID: participants[$0].participantID,
        sourceCount: observedMediaCounts[$0].sourceCount,
        audioTrackCount: observedMediaCounts[$0].audioTrackCount
      )
    }
    let payload = try ClipLiveShareNativeV3AcceptanceReportPayload(
      runIdentifier: runIdentifier,
      processLabel: labels[index],
      reportedAt: origin.adding(milliseconds: 1_000),
      roomName: "Acceptance Room",
      participantID: local.participantID,
      signedMembership: membership,
      leadershipTerm: ClipLiveShareNativeV3LeadershipTerm(rawValue: 1),
      phase: stage == .ready ? .live : .ended,
      peerLinks: links,
      localSourceCount: mediaCounts[index].sourceCount,
      localAudioTrackCount: mediaCounts[index].audioTrackCount,
      remoteMedia: remotes,
      hadReachedReady: isReady,
      failures: [],
      cleanTeardown: stage == .final
    )
    return try ClipLiveShareSignedNativeV3AcceptanceReport(
      signing: payload,
      with: signers[index]
    )
  }
}
