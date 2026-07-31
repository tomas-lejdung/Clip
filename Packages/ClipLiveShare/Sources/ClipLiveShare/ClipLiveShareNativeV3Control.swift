import Foundation

/// Closed native-v3 control vocabulary. Adding a case is an explicit protocol
/// change inside version 3; arbitrary `Encodable` values and messages from
/// other protocols cannot pass through this boundary.
public enum ClipLiveShareNativeV3ControlMessageKind: String, Codable, CaseIterable,
  Equatable, Hashable, Sendable
{
  case membershipSnapshot = "membership-snapshot"
  case sourceSnapshot = "source-snapshot"
  case possessionChallenge = "possession-challenge"
  case possessionProof = "possession-proof"
  case peerLinkOffer = "peer-link-offer"
  case peerLinkAnswer = "peer-link-answer"
  case peerLinkICE = "peer-link-ice"
  case peerLinkRenegotiationRequest = "peer-link-renegotiation-request"
  case roomAuthority = "room-authority"
  case leadershipTransferRequest = "leadership-transfer-request"
  case leadershipProposal = "leadership-proposal"
  case leadershipVote = "leadership-vote"
  case leadershipCertificate = "leadership-certificate"
  case participantLeaveRequest = "participant-leave-request"
  case roomTermination = "room-termination"
  case sourceCursor = "source-cursor"
  case collaboration = "collaboration"
  case bootstrapForward = "bootstrap-forward"
}

/// Ephemeral native cursor context for one exact published source.
///
/// Source instance and stream identity prevent a late cursor update from
/// moving a replacement window. The direct peer link authenticates the sender;
/// receivers still verify that `participantID` owns `sourceKey`.
public struct ClipLiveShareNativeV3SourceCursor: Codable, Equatable, Hashable,
  Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let sourceKey: ClipLiveShareNativeV3SourceKey
  public let streamID: ClipLiveShareStreamID
  public let sequence: UInt64
  public let position: ClipLiveShareNativeV3NormalizedPoint?

  public init(
    sessionID: ClipLiveShareSessionID,
    participantID: ClipLiveShareNativeV3ParticipantID,
    sourceKey: ClipLiveShareNativeV3SourceKey,
    streamID: ClipLiveShareStreamID,
    sequence: UInt64,
    position: ClipLiveShareNativeV3NormalizedPoint?
  ) throws {
    guard participantID == sourceKey.ownerParticipantID, sequence > 0 else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    self.sessionID = sessionID
    self.participantID = participantID
    self.sourceKey = sourceKey
    self.streamID = streamID
    self.sequence = sequence
    self.position = position
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case participantID = "participantId"
    case sourceKey
    case streamID = "streamId"
    case sequence
    case position
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      participantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .participantID
      ),
      sourceKey: container.decode(
        ClipLiveShareNativeV3SourceKey.self,
        forKey: .sourceKey
      ),
      streamID: container.decode(ClipLiveShareStreamID.self, forKey: .streamID),
      sequence: container.decode(UInt64.self, forKey: .sequence),
      position: container.decodeIfPresent(
        ClipLiveShareNativeV3NormalizedPoint.self,
        forKey: .position
      )
    )
  }
}

/// One narrowly scoped native-v3 admission message forwarded across an
/// already authenticated participant link.
///
/// This is not an arbitrary byte tunnel. Its payload is the closed bootstrap
/// vocabulary, is bound to one session and provisional-admission digest, and
/// identifies both the original participant and final recipient. Runtime and
/// admission state enforce that only the current leader can relay it and that
/// it is accepted only during the single active admission transaction.
public struct ClipLiveShareNativeV3BootstrapForward: Codable, Equatable,
  Hashable, Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let admissionDigest: ClipLiveShareNativeDigest
  public let originParticipantID: ClipLiveShareNativeV3ParticipantID
  public let targetParticipantID: ClipLiveShareNativeV3ParticipantID
  public let envelope: ClipLiveShareNativeV3BootstrapEnvelope

  public init(
    sessionID: ClipLiveShareSessionID,
    admissionDigest: ClipLiveShareNativeDigest,
    originParticipantID: ClipLiveShareNativeV3ParticipantID,
    targetParticipantID: ClipLiveShareNativeV3ParticipantID,
    envelope: ClipLiveShareNativeV3BootstrapEnvelope
  ) throws {
    guard originParticipantID != targetParticipantID else {
      throw ClipLiveShareNativeV3BootstrapError.invalidRelay
    }

    switch envelope {
    case let .hello(value):
      guard
        value.hello.sessionID == sessionID,
        value.hello.participantID == originParticipantID
      else {
        throw ClipLiveShareNativeV3BootstrapError.invalidRelay
      }
    case let .provisionalAdmission(value):
      guard
        value.admission.sessionID == sessionID,
        value.admission.digest == admissionDigest,
        value.admission.currentMembership.snapshot.leaderParticipantID
          == originParticipantID,
        value.admission.proposedParticipantIDs.contains(targetParticipantID)
      else {
        throw ClipLiveShareNativeV3BootstrapError.invalidRelay
      }
    case let .relay(value):
      guard
        value.sessionID == sessionID,
        value.admissionDigest == admissionDigest,
        value.originParticipantID == originParticipantID,
        value.targetParticipantID == targetParticipantID
      else {
        throw ClipLiveShareNativeV3BootstrapError.invalidRelay
      }
    case let .linkReadiness(value):
      guard
        value.readiness.sessionID == sessionID,
        value.readiness.admissionDigest == admissionDigest,
        value.readiness.reporterParticipantID == originParticipantID
      else {
        throw ClipLiveShareNativeV3BootstrapError.invalidRelay
      }
    case let .admitted(value):
      guard
        value.snapshot.sessionID == sessionID,
        value.snapshot.leaderParticipantID == originParticipantID,
        value.snapshot.participantIDs.contains(targetParticipantID)
      else {
        throw ClipLiveShareNativeV3BootstrapError.invalidRelay
      }
    case let .rejected(value):
      guard value.sessionID == sessionID else {
        throw ClipLiveShareNativeV3BootstrapError.invalidRelay
      }
    }

    self.sessionID = sessionID
    self.admissionDigest = admissionDigest
    self.originParticipantID = originParticipantID
    self.targetParticipantID = targetParticipantID
    self.envelope = envelope
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case admissionDigest
    case originParticipantID = "originParticipantId"
    case targetParticipantID = "targetParticipantId"
    case envelope
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      sessionID: container.decode(
        ClipLiveShareSessionID.self,
        forKey: .sessionID
      ),
      admissionDigest: container.decode(
        ClipLiveShareNativeDigest.self,
        forKey: .admissionDigest
      ),
      originParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .originParticipantID
      ),
      targetParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .targetParticipantID
      ),
      envelope: container.decode(
        ClipLiveShareNativeV3BootstrapEnvelope.self,
        forKey: .envelope
      )
    )
  }
}

public enum ClipLiveShareNativeV3ControlEnvelope: Codable, Equatable, Hashable, Sendable {
  case membershipSnapshot(ClipLiveShareSignedNativeV3MembershipSnapshot)
  case sourceSnapshot(ClipLiveShareNativeV3SourceSnapshot)
  case possessionChallenge(ClipLiveShareNativeV3PossessionChallenge)
  case possessionProof(ClipLiveShareSignedNativeV3PossessionProof)
  case peerLinkOffer(ClipLiveShareSignedNativeV3PeerLinkOffer)
  case peerLinkAnswer(ClipLiveShareSignedNativeV3PeerLinkAnswer)
  case peerLinkICE(ClipLiveShareSignedNativeV3PeerLinkICECandidate)
  case peerLinkRenegotiationRequest(
    ClipLiveShareSignedNativeV3PeerLinkRenegotiationRequest
  )
  case roomAuthority(ClipLiveShareNativeV3RoomAuthorityChain)
  case leadershipTransferRequest(
    ClipLiveShareSignedNativeV3LeadershipTransferRequest
  )
  case leadershipProposal(ClipLiveShareSignedNativeV3LeadershipProposal)
  case leadershipVote(ClipLiveShareSignedNativeV3LeadershipVote)
  case leadershipCertificate(ClipLiveShareNativeV3LeadershipCertificate)
  case participantLeaveRequest(
    ClipLiveShareSignedNativeV3ParticipantLeaveRequest
  )
  case roomTermination(ClipLiveShareSignedNativeV3RoomTermination)
  case sourceCursor(ClipLiveShareNativeV3SourceCursor)
  case collaboration(ClipLiveShareNativeV3CollaborationEvent)
  case bootstrapForward(ClipLiveShareNativeV3BootstrapForward)

  public var kind: ClipLiveShareNativeV3ControlMessageKind {
    switch self {
    case .membershipSnapshot: .membershipSnapshot
    case .sourceSnapshot: .sourceSnapshot
    case .possessionChallenge: .possessionChallenge
    case .possessionProof: .possessionProof
    case .peerLinkOffer: .peerLinkOffer
    case .peerLinkAnswer: .peerLinkAnswer
    case .peerLinkICE: .peerLinkICE
    case .peerLinkRenegotiationRequest: .peerLinkRenegotiationRequest
    case .roomAuthority: .roomAuthority
    case .leadershipTransferRequest: .leadershipTransferRequest
    case .leadershipProposal: .leadershipProposal
    case .leadershipVote: .leadershipVote
    case .leadershipCertificate: .leadershipCertificate
    case .participantLeaveRequest: .participantLeaveRequest
    case .roomTermination: .roomTermination
    case .sourceCursor: .sourceCursor
    case .collaboration: .collaboration
    case .bootstrapForward: .bootstrapForward
    }
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case type
    case payload
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareNativeV3.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    let rawType = try container.decode(String.self, forKey: .type)
    guard let kind = ClipLiveShareNativeV3ControlMessageKind(rawValue: rawType) else {
      throw ClipLiveShareNativeV3Error.unknownControlMessageType(rawType)
    }
    switch kind {
    case .membershipSnapshot:
      self = .membershipSnapshot(
        try container.decode(
          ClipLiveShareSignedNativeV3MembershipSnapshot.self,
          forKey: .payload
        )
      )
    case .sourceSnapshot:
      self = .sourceSnapshot(
        try container.decode(
          ClipLiveShareNativeV3SourceSnapshot.self,
          forKey: .payload
        )
      )
    case .possessionChallenge:
      self = .possessionChallenge(
        try container.decode(
          ClipLiveShareNativeV3PossessionChallenge.self,
          forKey: .payload
        )
      )
    case .possessionProof:
      self = .possessionProof(
        try container.decode(
          ClipLiveShareSignedNativeV3PossessionProof.self,
          forKey: .payload
        )
      )
    case .peerLinkOffer:
      self = .peerLinkOffer(
        try container.decode(
          ClipLiveShareSignedNativeV3PeerLinkOffer.self,
          forKey: .payload
        )
      )
    case .peerLinkAnswer:
      self = .peerLinkAnswer(
        try container.decode(
          ClipLiveShareSignedNativeV3PeerLinkAnswer.self,
          forKey: .payload
        )
      )
    case .peerLinkICE:
      self = .peerLinkICE(
        try container.decode(
          ClipLiveShareSignedNativeV3PeerLinkICECandidate.self,
          forKey: .payload
        )
      )
    case .peerLinkRenegotiationRequest:
      self = .peerLinkRenegotiationRequest(
        try container.decode(
          ClipLiveShareSignedNativeV3PeerLinkRenegotiationRequest.self,
          forKey: .payload
        )
      )
    case .roomAuthority:
      self = .roomAuthority(
        try container.decode(
          ClipLiveShareNativeV3RoomAuthorityChain.self,
          forKey: .payload
        )
      )
    case .leadershipTransferRequest:
      self = .leadershipTransferRequest(
        try container.decode(
          ClipLiveShareSignedNativeV3LeadershipTransferRequest.self,
          forKey: .payload
        )
      )
    case .leadershipProposal:
      self = .leadershipProposal(
        try container.decode(
          ClipLiveShareSignedNativeV3LeadershipProposal.self,
          forKey: .payload
        )
      )
    case .leadershipVote:
      self = .leadershipVote(
        try container.decode(
          ClipLiveShareSignedNativeV3LeadershipVote.self,
          forKey: .payload
        )
      )
    case .leadershipCertificate:
      self = .leadershipCertificate(
        try container.decode(
          ClipLiveShareNativeV3LeadershipCertificate.self,
          forKey: .payload
        )
      )
    case .participantLeaveRequest:
      self = .participantLeaveRequest(
        try container.decode(
          ClipLiveShareSignedNativeV3ParticipantLeaveRequest.self,
          forKey: .payload
        )
      )
    case .roomTermination:
      self = .roomTermination(
        try container.decode(
          ClipLiveShareSignedNativeV3RoomTermination.self,
          forKey: .payload
        )
      )
    case .sourceCursor:
      self = .sourceCursor(
        try container.decode(
          ClipLiveShareNativeV3SourceCursor.self,
          forKey: .payload
        )
      )
    case .collaboration:
      self = .collaboration(
        try container.decode(
          ClipLiveShareNativeV3CollaborationEvent.self,
          forKey: .payload
        )
      )
    case .bootstrapForward:
      self = .bootstrapForward(
        try container.decode(
          ClipLiveShareNativeV3BootstrapForward.self,
          forKey: .payload
        )
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV3.version, forKey: .version)
    try container.encode(kind.rawValue, forKey: .type)
    switch self {
    case let .membershipSnapshot(value):
      try container.encode(value, forKey: .payload)
    case let .sourceSnapshot(value):
      try container.encode(value, forKey: .payload)
    case let .possessionChallenge(value):
      try container.encode(value, forKey: .payload)
    case let .possessionProof(value):
      try container.encode(value, forKey: .payload)
    case let .peerLinkOffer(value):
      try container.encode(value, forKey: .payload)
    case let .peerLinkAnswer(value):
      try container.encode(value, forKey: .payload)
    case let .peerLinkICE(value):
      try container.encode(value, forKey: .payload)
    case let .peerLinkRenegotiationRequest(value):
      try container.encode(value, forKey: .payload)
    case let .roomAuthority(value):
      try container.encode(value, forKey: .payload)
    case let .leadershipTransferRequest(value):
      try container.encode(value, forKey: .payload)
    case let .leadershipProposal(value):
      try container.encode(value, forKey: .payload)
    case let .leadershipVote(value):
      try container.encode(value, forKey: .payload)
    case let .leadershipCertificate(value):
      try container.encode(value, forKey: .payload)
    case let .participantLeaveRequest(value):
      try container.encode(value, forKey: .payload)
    case let .roomTermination(value):
      try container.encode(value, forKey: .payload)
    case let .sourceCursor(value):
      try container.encode(value, forKey: .payload)
    case let .collaboration(value):
      try container.encode(value, forKey: .payload)
    case let .bootstrapForward(value):
      try container.encode(value, forKey: .payload)
    }
  }
}

/// The only public native-v3 JSON boundary. It additionally enforces an exact
/// top-level schema before Codable runs, preventing version/type smuggling
/// through ignored JSON members.
public enum ClipLiveShareNativeV3ControlCodec {
  public static func encode(
    _ envelope: ClipLiveShareNativeV3ControlEnvelope,
    maximumBytes: Int = ClipLiveShareNativeV3.maximumControlMessageBytes
  ) throws -> Data {
    guard maximumBytes > 0 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 control message size limit must be positive"
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(envelope)
    guard data.count <= maximumBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: maximumBytes,
        actual: data.count
      )
    }
    return data
  }

  public static func decode(
    _ data: Data,
    maximumBytes: Int = ClipLiveShareNativeV3.maximumControlMessageBytes
  ) throws -> ClipLiveShareNativeV3ControlEnvelope {
    guard maximumBytes > 0 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 control message size limit must be positive"
      )
    }
    guard data.count <= maximumBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: maximumBytes,
        actual: data.count
      )
    }
    let object = try JSONSerialization.jsonObject(
      with: data,
      options: [.fragmentsAllowed]
    )
    guard let dictionary = object as? [String: Any] else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 control envelope must be a JSON object"
      )
    }
    let expectedKeys: Set<String> = ["version", "type", "payload"]
    guard Set(dictionary.keys) == expectedKeys else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 control envelope has unexpected fields"
      )
    }
    guard
      let version = dictionary["version"] as? NSNumber,
      version.intValue == ClipLiveShareNativeV3.version,
      version.doubleValue == Double(version.intValue)
    else {
      let unsupportedVersion = (dictionary["version"] as? NSNumber)?.intValue ?? -1
      throw ClipLiveShareProtocolError.unsupportedVersion(unsupportedVersion)
    }
    guard let rawType = dictionary["type"] as? String else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 control envelope type is invalid"
      )
    }
    guard ClipLiveShareNativeV3ControlMessageKind(rawValue: rawType) != nil else {
      throw ClipLiveShareNativeV3Error.unknownControlMessageType(rawType)
    }
    return try JSONDecoder().decode(
      ClipLiveShareNativeV3ControlEnvelope.self,
      from: data
    )
  }
}
