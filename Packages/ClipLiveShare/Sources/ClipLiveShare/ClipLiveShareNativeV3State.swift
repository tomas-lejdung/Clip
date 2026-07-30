import Foundation

/// Product policy is intentionally narrower than the native v3 wire bounds.
/// Raising these values later does not require a protocol-version change.
public struct ClipLiveShareNativeV3AdmissionPolicy: Equatable, Hashable, Sendable {
  public let maximumParticipants: Int
  public let maximumActiveSourcesPerParticipant: Int

  public init(
    maximumParticipants: Int,
    maximumActiveSourcesPerParticipant: Int
  ) throws {
    guard
      (1...ClipLiveShareNativeV3.maximumProtocolParticipants).contains(maximumParticipants)
    else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: ClipLiveShareNativeV3.maximumProtocolParticipants,
        actual: maximumParticipants
      )
    }
    guard
      (1...ClipLiveShareNativeV3.maximumSourcesPerParticipant)
        .contains(maximumActiveSourcesPerParticipant)
    else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 active-source policy exceeds the reserved video slots"
      )
    }
    self.maximumParticipants = maximumParticipants
    self.maximumActiveSourcesPerParticipant = maximumActiveSourcesPerParticipant
  }

  public static var productDefault: Self {
    try! Self(
      maximumParticipants: ClipLiveShareNativeV3.defaultProductAdmissionLimit,
      maximumActiveSourcesPerParticipant:
        ClipLiveShareNativeV3.defaultMaximumActiveSourcesPerParticipant
    )
  }

  public static var protocolMaximum: Self {
    try! Self(
      maximumParticipants: ClipLiveShareNativeV3.maximumProtocolParticipants,
      maximumActiveSourcesPerParticipant: ClipLiveShareNativeV3.maximumSourcesPerParticipant
    )
  }
}

/// Membership and source ordering are separate security domains. A source
/// update can never advance or suppress a membership update.
public struct ClipLiveShareNativeV3MembershipRevisionLedger: Equatable, Sendable {
  public private(set) var latestAcceptedRevision: ClipLiveShareNativeV3MembershipRevision?

  public init(
    latestAcceptedRevision: ClipLiveShareNativeV3MembershipRevision? = nil
  ) {
    self.latestAcceptedRevision = latestAcceptedRevision
  }

  public mutating func accept(
    _ revision: ClipLiveShareNativeV3MembershipRevision
  ) throws {
    if let latestAcceptedRevision, revision <= latestAcceptedRevision {
      throw ClipLiveShareNativeV3Error.staleMembershipRevision(
        expectedGreaterThan: latestAcceptedRevision.rawValue,
        actual: revision.rawValue
      )
    }
    latestAcceptedRevision = revision
  }
}

/// Each publisher owns an independent source revision sequence. A busy
/// publisher therefore cannot make another participant's next update appear
/// stale.
public struct ClipLiveShareNativeV3SourceRevisionLedger: Equatable, Sendable {
  public private(set) var latestAcceptedRevisions:
    [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3SourceRevision]

  public init(
    latestAcceptedRevisions:
      [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3SourceRevision] = [:]
  ) {
    self.latestAcceptedRevisions = latestAcceptedRevisions
  }

  public mutating func accept(
    _ revision: ClipLiveShareNativeV3SourceRevision,
    from participantID: ClipLiveShareNativeV3ParticipantID
  ) throws {
    if let latest = latestAcceptedRevisions[participantID], revision <= latest {
      throw ClipLiveShareNativeV3Error.staleSourceRevision(
        participantID: participantID,
        expectedGreaterThan: latest.rawValue,
        actual: revision.rawValue
      )
    }
    latestAcceptedRevisions[participantID] = revision
  }

  public mutating func retainParticipants(
    _ participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  ) {
    latestAcceptedRevisions = latestAcceptedRevisions.filter {
      participantIDs.contains($0.key)
    }
  }
}

/// Negotiation ordering is independent for every unordered peer-link key.
/// Traffic on A-B therefore cannot make a valid A-C offer appear stale.
public struct ClipLiveShareNativeV3PeerLinkRevisionLedger: Equatable, Sendable {
  public private(set) var latestAcceptedRevisions:
    [ClipLiveShareNativeV3PeerLinkKey: ClipLiveShareNativeV3PeerLinkRevision]

  public init(
    latestAcceptedRevisions:
      [ClipLiveShareNativeV3PeerLinkKey: ClipLiveShareNativeV3PeerLinkRevision] = [:]
  ) {
    self.latestAcceptedRevisions = latestAcceptedRevisions
  }

  public mutating func accept(
    _ revision: ClipLiveShareNativeV3PeerLinkRevision,
    for peerLinkKey: ClipLiveShareNativeV3PeerLinkKey
  ) throws {
    if let latest = latestAcceptedRevisions[peerLinkKey], revision <= latest {
      throw ClipLiveShareNativeV3Error.stalePeerLinkRevision(
        peerLinkKey: peerLinkKey,
        expectedGreaterThan: latest.rawValue,
        actual: revision.rawValue
      )
    }
    latestAcceptedRevisions[peerLinkKey] = revision
  }

  public mutating func retainPeerLinks(
    _ peerLinkKeys: Set<ClipLiveShareNativeV3PeerLinkKey>
  ) {
    latestAcceptedRevisions = latestAcceptedRevisions.filter {
      peerLinkKeys.contains($0.key)
    }
  }
}

public struct ClipLiveShareNativeV3PublishedSource: Codable, Equatable, Hashable, Sendable {
  public let key: ClipLiveShareNativeV3SourceKey
  public let descriptor: ClipLiveShareNativeStreamDescriptor

  public init(
    key: ClipLiveShareNativeV3SourceKey,
    descriptor: ClipLiveShareNativeStreamDescriptor
  ) throws {
    guard key.sourceInstanceID == descriptor.sourceInstanceID else {
      throw ClipLiveShareNativeV3Error.invalidSourceOwnership
    }
    self.key = key
    self.descriptor = descriptor
  }

  var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/published-source"
    )
    encoder.append(key.ownerParticipantID.bytes)
    encoder.append(key.sourceInstanceID.bytes)
    encoder.append(descriptor.canonicalRepresentation)
    return encoder.data
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      key: container.decode(ClipLiveShareNativeV3SourceKey.self, forKey: .key),
      descriptor: container.decode(
        ClipLiveShareNativeStreamDescriptor.self,
        forKey: .descriptor
      )
    )
  }

  private enum CodingKeys: String, CodingKey {
    case key
    case descriptor
  }
}

/// One publisher's complete source view at an independent source revision.
/// Transport authentication supplies the sender identity; `apply` additionally
/// requires that identity to match `ownerParticipantID`.
public struct ClipLiveShareNativeV3SourceSnapshot: Codable, Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let membershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let ownerParticipantID: ClipLiveShareNativeV3ParticipantID
  public let sourceRevision: ClipLiveShareNativeV3SourceRevision
  public let sources: [ClipLiveShareNativeV3PublishedSource]

  public init(
    sessionID: ClipLiveShareSessionID,
    membershipRevision: ClipLiveShareNativeV3MembershipRevision,
    ownerParticipantID: ClipLiveShareNativeV3ParticipantID,
    sourceRevision: ClipLiveShareNativeV3SourceRevision,
    sources: [ClipLiveShareNativeV3PublishedSource],
    maximumSources: Int = ClipLiveShareNativeV3.maximumSourcesPerParticipant
  ) throws {
    guard
      (0...ClipLiveShareNativeV3.maximumSourcesPerParticipant).contains(maximumSources)
    else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 source limit exceeds the reserved video slots"
      )
    }
    guard sources.count <= maximumSources else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 source snapshot exceeds its source limit"
      )
    }
    guard Set(sources.map(\.key)).count == sources.count else {
      throw ClipLiveShareNativeV3Error.duplicateSource
    }
    guard sources.allSatisfy({ $0.key.ownerParticipantID == ownerParticipantID }) else {
      throw ClipLiveShareNativeV3Error.invalidSourceOwnership
    }
    _ = try ClipLiveShareStreamManifest(
      sessionID: sessionID,
      streams: sources.map(\.descriptor.stream),
      maximumStreams: maximumSources
    )
    self.sessionID = sessionID
    self.membershipRevision = membershipRevision
    self.ownerParticipantID = ownerParticipantID
    self.sourceRevision = sourceRevision
    self.sources = sources.sorted { $0.key < $1.key }
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/source-snapshot"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(membershipRevision.rawValue)
    encoder.append(ownerParticipantID.bytes)
    encoder.append(sourceRevision.rawValue)
    encoder.append(UInt64(sources.count))
    for source in sources { encoder.append(source.canonicalRepresentation) }
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case sessionID = "sessionId"
    case membershipRevision
    case ownerParticipantID = "ownerParticipantId"
    case sourceRevision
    case sources
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareNativeV3.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      membershipRevision: container.decode(
        ClipLiveShareNativeV3MembershipRevision.self,
        forKey: .membershipRevision
      ),
      ownerParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .ownerParticipantID
      ),
      sourceRevision: container.decode(
        ClipLiveShareNativeV3SourceRevision.self,
        forKey: .sourceRevision
      ),
      sources: container.decode(
        [ClipLiveShareNativeV3PublishedSource].self,
        forKey: .sources
      )
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV3.version, forKey: .version)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(membershipRevision, forKey: .membershipRevision)
    try container.encode(ownerParticipantID, forKey: .ownerParticipantID)
    try container.encode(sourceRevision, forKey: .sourceRevision)
    try container.encode(sources, forKey: .sources)
  }
}

/// Deterministic complete-graph topology derived only from signed membership.
public struct ClipLiveShareNativeV3CompleteMeshTopology: Equatable, Hashable, Sendable {
  public let participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  public let peerLinkKeys: Set<ClipLiveShareNativeV3PeerLinkKey>

  public init(
    participantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
    maximumParticipants: Int = ClipLiveShareNativeV3.maximumProtocolParticipants
  ) throws {
    guard
      (1...ClipLiveShareNativeV3.maximumProtocolParticipants).contains(maximumParticipants),
      !participantIDs.isEmpty,
      participantIDs.count <= maximumParticipants
    else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: min(
          max(maximumParticipants, 0),
          ClipLiveShareNativeV3.maximumProtocolParticipants
        ),
        actual: participantIDs.count
      )
    }
    let orderedParticipants = participantIDs.sorted()
    var links = Set<ClipLiveShareNativeV3PeerLinkKey>()
    for lowerIndex in orderedParticipants.indices {
      for upperIndex in orderedParticipants.indices where upperIndex > lowerIndex {
        links.insert(
          try ClipLiveShareNativeV3PeerLinkKey(
            orderedParticipants[lowerIndex],
            orderedParticipants[upperIndex]
          )
        )
      }
    }
    self.participantIDs = participantIDs
    peerLinkKeys = links
    try validateCompleteMesh()
  }

  public func peers(
    for participantID: ClipLiveShareNativeV3ParticipantID
  ) throws -> Set<ClipLiveShareNativeV3ParticipantID> {
    guard participantIDs.contains(participantID) else {
      throw ClipLiveShareNativeV3Error.unknownParticipant(participantID)
    }
    return Set(participantIDs.filter { $0 != participantID })
  }

  public func validateCompleteMesh() throws {
    let expectedLinkCount = participantIDs.count * (participantIDs.count - 1) / 2
    guard
      peerLinkKeys.count == expectedLinkCount,
      peerLinkKeys.allSatisfy({ link in
        participantIDs.isSuperset(of: link.participantIDs)
      }),
      participantIDs.allSatisfy({ participantID in
        peerLinkKeys.filter { $0.contains(participantID) }.count
          == participantIDs.count - 1
      })
    else {
      throw ClipLiveShareNativeV3Error.invalidTopology
    }
  }

  /// True only when every edge in the complete graph has been established.
  /// Unknown links make the result false rather than being ignored.
  public func isComplete(
    establishedLinks: Set<ClipLiveShareNativeV3PeerLinkKey>
  ) -> Bool {
    establishedLinks == peerLinkKeys
  }

  /// Membership is committed locally only after this participant has a direct
  /// link to every other member. Remote-to-remote edges are learned from the
  /// signed topology but do not block this participant's transaction.
  public func isLocallyReady(
    participantID: ClipLiveShareNativeV3ParticipantID,
    establishedLinks: Set<ClipLiveShareNativeV3PeerLinkKey>
  ) -> Bool {
    guard
      participantIDs.contains(participantID),
      establishedLinks.isSubset(of: peerLinkKeys)
    else {
      return false
    }
    let required = Set(peerLinkKeys.filter { $0.contains(participantID) })
    return required.isSubset(of: establishedLinks)
  }
}

public enum ClipLiveShareNativeV3PeerLinkPhase: String, Codable, Equatable, Hashable, Sendable {
  case awaitingOffer = "awaiting-offer"
  case negotiating
  case connected
  case failed
}

public struct ClipLiveShareNativeV3PeerLinkState: Equatable, Hashable, Sendable {
  public let key: ClipLiveShareNativeV3PeerLinkKey
  public var phase: ClipLiveShareNativeV3PeerLinkPhase

  public init(
    key: ClipLiveShareNativeV3PeerLinkKey,
    phase: ClipLiveShareNativeV3PeerLinkPhase = .awaitingOffer
  ) {
    self.key = key
    self.phase = phase
  }
}

/// In-memory authoritative native-v3 state. It accepts only leader-signed,
/// increasing membership snapshots and independently increasing per-publisher
/// source snapshots.
public struct ClipLiveShareNativeV3MeshState: Equatable, Sendable {
  public let localParticipantID: ClipLiveShareNativeV3ParticipantID
  public let expectedSessionID: ClipLiveShareSessionID
  public let expectedLeaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let expectedLeaderIdentity: ClipLiveShareIdentityPublicKey
  public let localCapabilities: ClipLiveShareNativeV3Capabilities
  public let admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy

  public private(set) var signedMembership:
    ClipLiveShareSignedNativeV3MembershipSnapshot
  public private(set) var topology: ClipLiveShareNativeV3CompleteMeshTopology
  public private(set) var peerLinks:
    [ClipLiveShareNativeV3PeerLinkKey: ClipLiveShareNativeV3PeerLinkState]
  public private(set) var sources:
    [ClipLiveShareNativeV3SourceKey: ClipLiveShareNativeV3PublishedSource]
  public private(set) var membershipLedger:
    ClipLiveShareNativeV3MembershipRevisionLedger
  public private(set) var sourceLedger: ClipLiveShareNativeV3SourceRevisionLedger
  public private(set) var peerLinkLedger:
    ClipLiveShareNativeV3PeerLinkRevisionLedger

  public init(
    localParticipantID: ClipLiveShareNativeV3ParticipantID,
    signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    expectedSessionID: ClipLiveShareSessionID,
    expectedLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    expectedLeaderIdentity: ClipLiveShareIdentityPublicKey,
    localCapabilities: ClipLiveShareNativeV3Capabilities = .current,
    admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy = .productDefault,
    establishedLinks: Set<ClipLiveShareNativeV3PeerLinkKey>,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try signedMembership.verify(
      expectedSessionID: expectedSessionID,
      expectedLeaderParticipantID: expectedLeaderParticipantID,
      expectedLeaderIdentity: expectedLeaderIdentity,
      localCapabilities: localCapabilities,
      at: now
    )
    let snapshot = signedMembership.snapshot
    guard snapshot.participantIDs.contains(localParticipantID) else {
      throw ClipLiveShareNativeV3Error.unknownParticipant(localParticipantID)
    }
    guard snapshot.participants.count <= admissionPolicy.maximumParticipants else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: admissionPolicy.maximumParticipants,
        actual: snapshot.participants.count
      )
    }

    self.localParticipantID = localParticipantID
    self.expectedSessionID = expectedSessionID
    self.expectedLeaderParticipantID = expectedLeaderParticipantID
    self.expectedLeaderIdentity = expectedLeaderIdentity
    self.localCapabilities = localCapabilities
    self.admissionPolicy = admissionPolicy
    self.signedMembership = signedMembership
    let initialTopology = try ClipLiveShareNativeV3CompleteMeshTopology(
      participantIDs: snapshot.participantIDs,
      maximumParticipants: admissionPolicy.maximumParticipants
    )
    guard
      initialTopology.isLocallyReady(
        participantID: localParticipantID,
        establishedLinks: establishedLinks
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidTopology
    }
    topology = initialTopology
    peerLinks = Dictionary(
      uniqueKeysWithValues: topology.peerLinkKeys.map {
        (
          $0,
          ClipLiveShareNativeV3PeerLinkState(
            key: $0,
            phase: establishedLinks.contains($0) ? .connected : .awaitingOffer
          )
        )
      }
    )
    sources = [:]
    membershipLedger = ClipLiveShareNativeV3MembershipRevisionLedger(
      latestAcceptedRevision: snapshot.membershipRevision
    )
    sourceLedger = ClipLiveShareNativeV3SourceRevisionLedger()
    peerLinkLedger = ClipLiveShareNativeV3PeerLinkRevisionLedger()
  }

  public mutating func applyMembershipSnapshot(
    _ incoming: ClipLiveShareSignedNativeV3MembershipSnapshot,
    establishedLinks: Set<ClipLiveShareNativeV3PeerLinkKey>,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try incoming.verify(
      expectedSessionID: expectedSessionID,
      expectedLeaderParticipantID: expectedLeaderParticipantID,
      expectedLeaderIdentity: expectedLeaderIdentity,
      localCapabilities: localCapabilities,
      at: now
    )
    let snapshot = incoming.snapshot
    guard snapshot.participantIDs.contains(localParticipantID) else {
      throw ClipLiveShareNativeV3Error.unknownParticipant(localParticipantID)
    }
    guard snapshot.participants.count <= admissionPolicy.maximumParticipants else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: admissionPolicy.maximumParticipants,
        actual: snapshot.participants.count
      )
    }
    let existingIdentityByParticipant = Dictionary(
      uniqueKeysWithValues: signedMembership.snapshot.participants.map {
        ($0.participantID, $0.identity)
      }
    )
    for participant in snapshot.participants {
      if let existingIdentity = existingIdentityByParticipant[participant.participantID],
        existingIdentity != participant.identity
      {
        throw ClipLiveShareNativeV3Error.participantIdentityChanged(
          participant.participantID
        )
      }
    }

    var nextMembershipLedger = membershipLedger
    try nextMembershipLedger.accept(snapshot.membershipRevision)
    let nextTopology = try ClipLiveShareNativeV3CompleteMeshTopology(
      participantIDs: snapshot.participantIDs,
      maximumParticipants: admissionPolicy.maximumParticipants
    )
    guard
      nextTopology.isLocallyReady(
        participantID: localParticipantID,
        establishedLinks: establishedLinks
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidTopology
    }
    let nextPeerLinks = Dictionary(
      uniqueKeysWithValues: nextTopology.peerLinkKeys.map { key in
        if establishedLinks.contains(key) {
          return (
            key,
            ClipLiveShareNativeV3PeerLinkState(key: key, phase: .connected)
          )
        }
        return (
          key,
          peerLinks[key] ?? ClipLiveShareNativeV3PeerLinkState(key: key)
        )
      }
    )
    let nextSources = sources.filter {
      snapshot.participantIDs.contains($0.key.ownerParticipantID)
    }
    var nextSourceLedger = sourceLedger
    nextSourceLedger.retainParticipants(snapshot.participantIDs)
    var nextPeerLinkLedger = peerLinkLedger
    nextPeerLinkLedger.retainPeerLinks(nextTopology.peerLinkKeys)

    signedMembership = incoming
    topology = nextTopology
    peerLinks = nextPeerLinks
    sources = nextSources
    membershipLedger = nextMembershipLedger
    sourceLedger = nextSourceLedger
    peerLinkLedger = nextPeerLinkLedger
  }

  public mutating func applySourceSnapshot(
    _ snapshot: ClipLiveShareNativeV3SourceSnapshot,
    from authenticatedParticipantID: ClipLiveShareNativeV3ParticipantID
  ) throws {
    guard
      snapshot.sessionID == expectedSessionID,
      snapshot.membershipRevision == signedMembership.snapshot.membershipRevision
    else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    guard snapshot.ownerParticipantID == authenticatedParticipantID else {
      throw ClipLiveShareNativeV3Error.invalidSourceOwnership
    }
    guard topology.participantIDs.contains(authenticatedParticipantID) else {
      throw ClipLiveShareNativeV3Error.unknownParticipant(authenticatedParticipantID)
    }
    guard
      snapshot.sources.count
        <= admissionPolicy.maximumActiveSourcesPerParticipant
    else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 source snapshot exceeds the active product limit"
      )
    }

    var nextSourceLedger = sourceLedger
    try nextSourceLedger.accept(
      snapshot.sourceRevision,
      from: authenticatedParticipantID
    )
    var nextSources = sources.filter {
      $0.key.ownerParticipantID != authenticatedParticipantID
    }
    for source in snapshot.sources { nextSources[source.key] = source }

    sources = nextSources
    sourceLedger = nextSourceLedger
  }

  public mutating func setPeerLinkPhase(
    _ phase: ClipLiveShareNativeV3PeerLinkPhase,
    for key: ClipLiveShareNativeV3PeerLinkKey,
    negotiationRevision: ClipLiveShareNativeV3PeerLinkRevision
  ) throws {
    guard peerLinks[key] != nil else {
      throw ClipLiveShareNativeV3Error.invalidTopology
    }
    var nextLedger = peerLinkLedger
    try nextLedger.accept(negotiationRevision, for: key)
    peerLinks[key]?.phase = phase
    peerLinkLedger = nextLedger
  }

  public func sources(
    ownedBy participantID: ClipLiveShareNativeV3ParticipantID
  ) -> [ClipLiveShareNativeV3PublishedSource] {
    sources.values
      .filter { $0.key.ownerParticipantID == participantID }
      .sorted { $0.key < $1.key }
  }
}
