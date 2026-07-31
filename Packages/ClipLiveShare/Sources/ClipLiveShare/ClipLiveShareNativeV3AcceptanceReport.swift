import Foundation

/// A private, machine-readable observation emitted by one signed Clip process
/// during the native-v3 multi-process acceptance lane.
///
/// The report deliberately embeds the locally committed, leader-signed
/// membership. This binds the process's session-scoped participant identifier
/// to its persistent signing identity and lets the launcher reject a report
/// produced by an unrelated process or a stale room.
public struct ClipLiveShareNativeV3AcceptanceReportPayload:
  Codable, Equatable, Sendable
{
  public static let schemaVersion = 1

  public enum Phase: String, Codable, Equatable, Sendable {
    case connecting
    case live
    case reconnecting
    case electingLeader = "electing-leader"
    case leaderlessLocked = "leaderless-locked"
    case ending
    case ended
    case failed
  }

  public enum PeerConnectionState: String, Codable, Equatable, Sendable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
  }

  public enum PeerRoute: String, Codable, Equatable, Sendable {
    case direct
    case relay
    case unknown
    case disconnected
  }

  public struct PeerLink: Codable, Equatable, Sendable {
    public let remoteParticipantID: ClipLiveShareNativeV3ParticipantID
    public let connectionState: PeerConnectionState
    public let isReady: Bool
    public let route: PeerRoute

    public init(
      remoteParticipantID: ClipLiveShareNativeV3ParticipantID,
      connectionState: PeerConnectionState,
      isReady: Bool,
      route: PeerRoute
    ) {
      self.remoteParticipantID = remoteParticipantID
      self.connectionState = connectionState
      self.isReady = isReady
      self.route = route
    }
  }

  public struct RemoteMedia: Codable, Equatable, Sendable {
    public let participantID: ClipLiveShareNativeV3ParticipantID
    public let sourceCount: Int
    public let audioTrackCount: Int

    public init(
      participantID: ClipLiveShareNativeV3ParticipantID,
      sourceCount: Int,
      audioTrackCount: Int
    ) throws {
      guard
        (0...ClipLiveShareNativeV3.maximumSourcesPerParticipant)
          .contains(sourceCount),
        (0...1).contains(audioTrackCount)
      else {
        throw ClipLiveShareNativeV3AcceptanceReportError.invalidMediaCount
      }
      self.participantID = participantID
      self.sourceCount = sourceCount
      self.audioTrackCount = audioTrackCount
    }
  }

  public let runIdentifier: String
  public let processLabel: String
  public let reportedAt: ClipLiveShareNativeTimestamp
  public let roomName: String
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let sessionID: ClipLiveShareSessionID
  public let membershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let committedMemberCount: Int
  public let expectedPeerLinkCount: Int
  public let signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot
  public let currentLeaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let leadershipTerm: ClipLiveShareNativeV3LeadershipTerm
  public let phase: Phase
  public let peerLinks: [PeerLink]
  public let localSourceCount: Int
  public let localAudioTrackCount: Int
  public let remoteMedia: [RemoteMedia]
  public let hadReachedReady: Bool
  public let failures: [String]
  public let cleanTeardown: Bool

  public init(
    runIdentifier: String,
    processLabel: String,
    reportedAt: ClipLiveShareNativeTimestamp,
    roomName: String,
    participantID: ClipLiveShareNativeV3ParticipantID,
    signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    leadershipTerm: ClipLiveShareNativeV3LeadershipTerm,
    phase: Phase,
    peerLinks: [PeerLink],
    localSourceCount: Int,
    localAudioTrackCount: Int,
    remoteMedia: [RemoteMedia],
    hadReachedReady: Bool,
    failures: [String],
    cleanTeardown: Bool
  ) throws {
    try Self.validateRunIdentifier(runIdentifier)
    try Self.validateProcessLabel(processLabel)
    try validateNativeV3Text(
      roomName,
      name: "acceptance room name",
      maximumUTF8Bytes: 128
    )
    guard
      (0...ClipLiveShareNativeV3.maximumSourcesPerParticipant)
        .contains(localSourceCount),
      (0...1).contains(localAudioTrackCount),
      failures.count <= 32,
      failures.allSatisfy({ $0.utf8.count <= 1_024 })
    else {
      throw ClipLiveShareNativeV3AcceptanceReportError.invalidMediaCount
    }

    let membership = signedMembership.snapshot
    let participantIDs = membership.participantIDs
    guard participantIDs.contains(participantID) else {
      throw ClipLiveShareNativeV3AcceptanceReportError
        .participantMissingFromMembership
    }
    let expectedRemoteIDs = participantIDs.subtracting([participantID])
    let sortedPeerLinks = peerLinks.sorted {
      $0.remoteParticipantID < $1.remoteParticipantID
    }
    let sortedRemoteMedia = remoteMedia.sorted {
      $0.participantID < $1.participantID
    }
    guard
      Set(sortedPeerLinks.map(\.remoteParticipantID)).count
        == sortedPeerLinks.count,
      Set(sortedPeerLinks.map(\.remoteParticipantID)) == expectedRemoteIDs,
      Set(sortedRemoteMedia.map(\.participantID)).count
        == sortedRemoteMedia.count,
      Set(sortedRemoteMedia.map(\.participantID)) == expectedRemoteIDs
    else {
      throw ClipLiveShareNativeV3AcceptanceReportError
        .incompleteParticipantTopology
    }

    self.runIdentifier = runIdentifier
    self.processLabel = processLabel
    self.reportedAt = reportedAt
    self.roomName = roomName
    self.participantID = participantID
    sessionID = membership.sessionID
    membershipRevision = membership.membershipRevision
    committedMemberCount = participantIDs.count
    expectedPeerLinkCount = expectedRemoteIDs.count
    self.signedMembership = signedMembership
    currentLeaderParticipantID = membership.leaderParticipantID
    self.leadershipTerm = leadershipTerm
    self.phase = phase
    self.peerLinks = sortedPeerLinks
    self.localSourceCount = localSourceCount
    self.localAudioTrackCount = localAudioTrackCount
    self.remoteMedia = sortedRemoteMedia
    self.hadReachedReady = hadReachedReady
    self.failures = failures
    self.cleanTeardown = cleanTeardown
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case runIdentifier
    case processLabel
    case reportedAt
    case roomName
    case participantID
    case sessionID
    case membershipRevision
    case committedMemberCount
    case expectedPeerLinkCount
    case signedMembership
    case currentLeaderParticipantID
    case leadershipTerm
    case phase
    case peerLinks
    case localSourceCount
    case localAudioTrackCount
    case remoteMedia
    case hadReachedReady
    case failures
    case cleanTeardown
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == Self.schemaVersion else {
      throw ClipLiveShareProtocolError.unsupportedVersion(schemaVersion)
    }

    let decodedSessionID = try container.decode(
      ClipLiveShareSessionID.self,
      forKey: .sessionID
    )
    let decodedRevision = try container.decode(
      ClipLiveShareNativeV3MembershipRevision.self,
      forKey: .membershipRevision
    )
    let decodedMemberCount = try container.decode(
      Int.self,
      forKey: .committedMemberCount
    )
    let decodedPeerCount = try container.decode(
      Int.self,
      forKey: .expectedPeerLinkCount
    )
    let decodedLeader = try container.decode(
      ClipLiveShareNativeV3ParticipantID.self,
      forKey: .currentLeaderParticipantID
    )

    try self.init(
      runIdentifier: container.decode(String.self, forKey: .runIdentifier),
      processLabel: container.decode(String.self, forKey: .processLabel),
      reportedAt: container.decode(
        ClipLiveShareNativeTimestamp.self,
        forKey: .reportedAt
      ),
      roomName: container.decode(String.self, forKey: .roomName),
      participantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .participantID
      ),
      signedMembership: container.decode(
        ClipLiveShareSignedNativeV3MembershipSnapshot.self,
        forKey: .signedMembership
      ),
      leadershipTerm: container.decode(
        ClipLiveShareNativeV3LeadershipTerm.self,
        forKey: .leadershipTerm
      ),
      phase: container.decode(Phase.self, forKey: .phase),
      peerLinks: container.decode([PeerLink].self, forKey: .peerLinks),
      localSourceCount: container.decode(
        Int.self,
        forKey: .localSourceCount
      ),
      localAudioTrackCount: container.decode(
        Int.self,
        forKey: .localAudioTrackCount
      ),
      remoteMedia: container.decode(
        [RemoteMedia].self,
        forKey: .remoteMedia
      ),
      hadReachedReady: container.decode(
        Bool.self,
        forKey: .hadReachedReady
      ),
      failures: container.decode([String].self, forKey: .failures),
      cleanTeardown: container.decode(Bool.self, forKey: .cleanTeardown)
    )

    guard
      sessionID == decodedSessionID,
      membershipRevision == decodedRevision,
      committedMemberCount == decodedMemberCount,
      expectedPeerLinkCount == decodedPeerCount,
      currentLeaderParticipantID == decodedLeader
    else {
      throw ClipLiveShareNativeV3AcceptanceReportError
        .derivedMembershipFieldsMismatch
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(runIdentifier, forKey: .runIdentifier)
    try container.encode(processLabel, forKey: .processLabel)
    try container.encode(reportedAt, forKey: .reportedAt)
    try container.encode(roomName, forKey: .roomName)
    try container.encode(participantID, forKey: .participantID)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(membershipRevision, forKey: .membershipRevision)
    try container.encode(
      committedMemberCount,
      forKey: .committedMemberCount
    )
    try container.encode(
      expectedPeerLinkCount,
      forKey: .expectedPeerLinkCount
    )
    try container.encode(signedMembership, forKey: .signedMembership)
    try container.encode(
      currentLeaderParticipantID,
      forKey: .currentLeaderParticipantID
    )
    try container.encode(leadershipTerm, forKey: .leadershipTerm)
    try container.encode(phase, forKey: .phase)
    try container.encode(peerLinks, forKey: .peerLinks)
    try container.encode(localSourceCount, forKey: .localSourceCount)
    try container.encode(
      localAudioTrackCount,
      forKey: .localAudioTrackCount
    )
    try container.encode(remoteMedia, forKey: .remoteMedia)
    try container.encode(hadReachedReady, forKey: .hadReachedReady)
    try container.encode(failures, forKey: .failures)
    try container.encode(cleanTeardown, forKey: .cleanTeardown)
  }

  fileprivate var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/acceptance-report"
    )
    encoder.append(UInt64(Self.schemaVersion))
    encoder.append(runIdentifier)
    encoder.append(processLabel)
    encoder.append(reportedAt.millisecondsSince1970)
    encoder.append(roomName)
    encoder.append(participantID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(membershipRevision.rawValue)
    encoder.append(UInt64(committedMemberCount))
    encoder.append(UInt64(expectedPeerLinkCount))
    encoder.append(signedMembership.snapshot.canonicalRepresentation)
    encoder.append(signedMembership.signature.rawRepresentation)
    encoder.append(currentLeaderParticipantID.bytes)
    encoder.append(leadershipTerm.rawValue)
    encoder.append(phase.rawValue)
    encoder.append(UInt64(peerLinks.count))
    for link in peerLinks {
      encoder.append(link.remoteParticipantID.bytes)
      encoder.append(link.connectionState.rawValue)
      encoder.append(link.isReady)
      encoder.append(link.route.rawValue)
    }
    encoder.append(UInt64(localSourceCount))
    encoder.append(UInt64(localAudioTrackCount))
    encoder.append(UInt64(remoteMedia.count))
    for media in remoteMedia {
      encoder.append(media.participantID.bytes)
      encoder.append(UInt64(media.sourceCount))
      encoder.append(UInt64(media.audioTrackCount))
    }
    encoder.append(hadReachedReady)
    encoder.append(UInt64(failures.count))
    for failure in failures {
      encoder.append(failure)
    }
    encoder.append(cleanTeardown)
    return encoder.data
  }

  private static func validateRunIdentifier(_ value: String) throws {
    let allowed = CharacterSet(
      charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
    )
    guard
      (16...128).contains(value.count),
      value.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw ClipLiveShareNativeV3AcceptanceReportError.invalidRunIdentifier
    }
  }

  private static func validateProcessLabel(_ value: String) throws {
    let letters = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )
    let alphanumeric = letters.union(
      CharacterSet(charactersIn: "0123456789")
    )
    let allowed = alphanumeric.union(CharacterSet(charactersIn: "-"))
    guard
      (1...32).contains(value.count),
      value.unicodeScalars.first.map(letters.contains) == true,
      value.unicodeScalars.last.map(alphanumeric.contains) == true,
      value.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw ClipLiveShareNativeV3AcceptanceReportError.invalidProcessLabel
    }
  }
}

public struct ClipLiveShareSignedNativeV3AcceptanceReport:
  Codable, Equatable, Sendable
{
  public let payload: ClipLiveShareNativeV3AcceptanceReportPayload
  public let signature: ClipLiveShareIdentitySignature

  public init(
    payload: ClipLiveShareNativeV3AcceptanceReportPayload,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.payload = payload
    self.signature = signature
  }

  public init(
    signing payload: ClipLiveShareNativeV3AcceptanceReportPayload,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard
      payload.signedMembership.snapshot.participants.contains(where: {
        $0.participantID == payload.participantID
          && $0.identity == signer.publicKey
      })
    else {
      throw ClipLiveShareNativeV3AcceptanceReportError
        .participantIdentityMismatch
    }
    self.payload = payload
    signature = try signer.signature(for: payload.canonicalRepresentation)
  }

  public func verify(expectedRunIdentifier: String) throws {
    guard payload.runIdentifier == expectedRunIdentifier else {
      throw ClipLiveShareNativeV3AcceptanceReportError.runIdentifierMismatch
    }
    let membership = payload.signedMembership.snapshot
    try payload.signedMembership.verifyAsEstablished(
      expectedSessionID: membership.sessionID,
      expectedLeaderParticipantID: membership.leaderParticipantID,
      expectedLeaderIdentity: membership.leaderIdentity
    )
    guard
      let participant = membership.participants.first(where: {
        $0.participantID == payload.participantID
      }),
      participant.identity.isValidSignature(
        signature,
        for: payload.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3AcceptanceReportError.invalidSignature
    }
  }
}

public enum ClipLiveShareNativeV3AcceptanceValidationStage:
  String, Codable, Equatable, Sendable
{
  case ready
  case final
}

public struct ClipLiveShareNativeV3AcceptanceRunSummary:
  Codable, Equatable, Sendable
{
  public let runIdentifier: String
  public let sessionID: ClipLiveShareSessionID
  public let membershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let participantCount: Int
  public let totalPeerLinkReports: Int
  public let currentLeaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let leadershipTerm: ClipLiveShareNativeV3LeadershipTerm
  public let stage: ClipLiveShareNativeV3AcceptanceValidationStage
}

public enum ClipLiveShareNativeV3AcceptanceRunValidator {
  public static func validate(
    _ reports: [ClipLiveShareSignedNativeV3AcceptanceReport],
    expectedRunIdentifier: String,
    expectedProcessLabels: Set<String>,
    expectedLocalAudioTrackCount: Int,
    stage: ClipLiveShareNativeV3AcceptanceValidationStage
  ) throws -> ClipLiveShareNativeV3AcceptanceRunSummary {
    guard (3...4).contains(expectedProcessLabels.count) else {
      throw ClipLiveShareNativeV3AcceptanceReportError.invalidParticipantCount
    }
    guard (0...1).contains(expectedLocalAudioTrackCount) else {
      throw ClipLiveShareNativeV3AcceptanceReportError.invalidMediaCount
    }
    guard reports.count == expectedProcessLabels.count else {
      throw ClipLiveShareNativeV3AcceptanceReportError.missingReport
    }
    for report in reports {
      try report.verify(expectedRunIdentifier: expectedRunIdentifier)
    }

    let payloads = reports.map(\.payload)
    guard Set(payloads.map(\.processLabel)) == expectedProcessLabels else {
      throw ClipLiveShareNativeV3AcceptanceReportError
        .processLabelSetMismatch
    }
    let first = payloads[0]
    let membership = first.signedMembership
    let participantIDs = membership.snapshot.participantIDs
    guard
      participantIDs.count == expectedProcessLabels.count,
      Set(payloads.map(\.participantID)) == participantIDs,
      payloads.allSatisfy({
        $0.signedMembership == membership
          && $0.sessionID == first.sessionID
          && $0.membershipRevision == first.membershipRevision
          && $0.committedMemberCount == first.committedMemberCount
          && $0.currentLeaderParticipantID
            == first.currentLeaderParticipantID
          && $0.leadershipTerm == first.leadershipTerm
          && $0.roomName == first.roomName
      })
    else {
      throw ClipLiveShareNativeV3AcceptanceReportError
        .inconsistentMembership
    }

    let payloadByParticipant = Dictionary(
      uniqueKeysWithValues: payloads.map { ($0.participantID, $0) }
    )
    for payload in payloads {
      let expectedRemoteIDs = participantIDs.subtracting([
        payload.participantID
      ])
      guard
        payload.expectedPeerLinkCount == expectedRemoteIDs.count,
        Set(payload.peerLinks.map(\.remoteParticipantID))
          == expectedRemoteIDs,
        Set(payload.remoteMedia.map(\.participantID))
          == expectedRemoteIDs,
        payload.peerLinks.allSatisfy({
          $0.isReady
            && $0.connectionState == .connected
            && $0.route != .unknown
            && $0.route != .disconnected
        }),
        payload.localSourceCount >= 1,
        payload.localAudioTrackCount == expectedLocalAudioTrackCount,
        payload.hadReachedReady,
        payload.failures.isEmpty
      else {
        throw ClipLiveShareNativeV3AcceptanceReportError
          .participantNotReady(payload.participantID)
      }

      for remote in payload.remoteMedia {
        guard let remotePayload = payloadByParticipant[remote.participantID],
          remote.sourceCount == remotePayload.localSourceCount,
          remote.audioTrackCount == remotePayload.localAudioTrackCount
        else {
          throw ClipLiveShareNativeV3AcceptanceReportError
            .inconsistentMediaCounts
        }
      }

      for link in payload.peerLinks {
        guard
          let opposite = payloadByParticipant[link.remoteParticipantID]?
            .peerLinks.first(where: {
              $0.remoteParticipantID == payload.participantID
            }),
          opposite.isReady,
          opposite.connectionState == .connected,
          opposite.route == link.route
        else {
          throw ClipLiveShareNativeV3AcceptanceReportError
            .inconsistentPeerLink
        }
      }
    }

    switch stage {
    case .ready:
      guard payloads.allSatisfy({
        $0.phase == .live && !$0.cleanTeardown
      }) else {
        throw ClipLiveShareNativeV3AcceptanceReportError.invalidStage
      }
    case .final:
      guard payloads.allSatisfy({
        $0.phase == .ended && $0.cleanTeardown
      }) else {
        throw ClipLiveShareNativeV3AcceptanceReportError.invalidStage
      }
    }

    return ClipLiveShareNativeV3AcceptanceRunSummary(
      runIdentifier: expectedRunIdentifier,
      sessionID: first.sessionID,
      membershipRevision: first.membershipRevision,
      participantCount: payloads.count,
      totalPeerLinkReports: payloads.reduce(0) {
        $0 + $1.peerLinks.count
      },
      currentLeaderParticipantID: first.currentLeaderParticipantID,
      leadershipTerm: first.leadershipTerm,
      stage: stage
    )
  }
}

public enum ClipLiveShareNativeV3AcceptanceReportError:
  Error, Equatable, Sendable, LocalizedError
{
  case invalidRunIdentifier
  case invalidProcessLabel
  case invalidMediaCount
  case participantMissingFromMembership
  case participantIdentityMismatch
  case incompleteParticipantTopology
  case derivedMembershipFieldsMismatch
  case runIdentifierMismatch
  case invalidSignature
  case invalidParticipantCount
  case missingReport
  case processLabelSetMismatch
  case inconsistentMembership
  case participantNotReady(ClipLiveShareNativeV3ParticipantID)
  case inconsistentMediaCounts
  case inconsistentPeerLink
  case invalidStage

  public var errorDescription: String? {
    switch self {
    case .invalidRunIdentifier:
      "The native-v3 acceptance run identifier is invalid."
    case .invalidProcessLabel:
      "The native-v3 acceptance process label is invalid."
    case .invalidMediaCount:
      "The native-v3 acceptance media count is invalid."
    case .participantMissingFromMembership:
      "The reporting participant is missing from its committed membership."
    case .participantIdentityMismatch:
      "The report signer does not match the reporting participant."
    case .incompleteParticipantTopology:
      "The report does not describe every remote participant exactly once."
    case .derivedMembershipFieldsMismatch:
      "The report's membership summary does not match its signed membership."
    case .runIdentifierMismatch:
      "The report belongs to another acceptance run."
    case .invalidSignature:
      "The native-v3 acceptance report signature is invalid."
    case .invalidParticipantCount:
      "Native-v3 multi-process acceptance requires three or four participants."
    case .missingReport:
      "One or more native-v3 acceptance reports are missing."
    case .processLabelSetMismatch:
      "The native-v3 acceptance process labels do not match the launched set."
    case .inconsistentMembership:
      "The native-v3 acceptance processes do not agree on one membership."
    case let .participantNotReady(participantID):
      "Native-v3 participant \(participantID) did not report a complete ready mesh."
    case .inconsistentMediaCounts:
      "The native-v3 participants disagree about published media."
    case .inconsistentPeerLink:
      "The native-v3 participants disagree about a peer-link route or readiness."
    case .invalidStage:
      "The native-v3 acceptance reports do not match the requested stage."
    }
  }
}
