import Foundation

/// One source published by a participant over a direct mesh peer link.
public struct ClipLiveShareNativeV3PublishedSource: Codable, Equatable, Hashable,
  Sendable
{
  public let key: ClipLiveShareNativeV3SourceKey
  public let descriptor: ClipLiveShareNativeV3StreamDescriptor

  public init(
    key: ClipLiveShareNativeV3SourceKey,
    descriptor: ClipLiveShareNativeV3StreamDescriptor
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
        ClipLiveShareNativeV3StreamDescriptor.self,
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
/// Transport authentication supplies the sender identity; receivers also
/// require that identity to match `ownerParticipantID`.
public struct ClipLiveShareNativeV3SourceSnapshot: Codable, Equatable, Hashable,
  Sendable
{
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
      (0...ClipLiveShareNativeV3.maximumSourcesPerParticipant).contains(
        maximumSources
      )
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
    guard
      sources.allSatisfy({ $0.key.ownerParticipantID == ownerParticipantID })
    else {
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

/// Deterministic complete-graph topology used by the v4 peer reconciler.
public struct ClipLiveShareNativeV3CompleteMeshTopology: Equatable, Hashable,
  Sendable
{
  public let participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  public let peerLinkKeys: Set<ClipLiveShareNativeV3PeerLinkKey>

  public init(
    participantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
    maximumParticipants: Int = ClipLiveShareNativeV3.maximumProtocolParticipants
  ) throws {
    guard
      (1...ClipLiveShareNativeV3.maximumProtocolParticipants).contains(
        maximumParticipants
      ),
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

  public func isComplete(
    establishedLinks: Set<ClipLiveShareNativeV3PeerLinkKey>
  ) -> Bool {
    establishedLinks == peerLinkKeys
  }

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
