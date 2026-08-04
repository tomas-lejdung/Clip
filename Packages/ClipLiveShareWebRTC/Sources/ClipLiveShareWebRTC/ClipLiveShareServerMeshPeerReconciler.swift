import ClipLiveShare
import Foundation

/// A complete, service-ordered view of the admitted room participants.
///
/// This deliberately depends only on the stable participant identifiers that
/// the concrete WebRTC manager already understands. The room-session layer can
/// adapt its opaque server roster into this value after decrypting and
/// verifying every admitted descriptor; no server protocol or admission state
/// leaks into the media package.
public struct ClipLiveShareServerMeshRosterSnapshot: Equatable, Sendable {
  public let revision: ClipLiveShareServerRoomV4RosterRevision
  public let participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  /// Exactly one deterministic pair binding for every admitted remote member.
  /// Both endpoints receive the same pair ID and epoch from the verified room
  /// session; this layer never invents a process-local negotiation identity.
  public let localPairs: Set<ClipLiveShareServerMeshDesiredPair>

  public init(
    revision: ClipLiveShareServerRoomV4RosterRevision,
    participantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
    localPairs: Set<ClipLiveShareServerMeshDesiredPair>
  ) {
    self.revision = revision
    self.participantIDs = participantIDs
    self.localPairs = localPairs
  }
}

/// Server-room identity for one desired local pair.
///
/// The room session derives `pairID` and `epoch` identically at both endpoints
/// from the encrypted admitted descriptors/incarnations. Roster revision is
/// deliberately absent: an unrelated join or leave must not replace this
/// binding.
public struct ClipLiveShareServerMeshDesiredPair:
  Equatable, Hashable, Sendable, Identifiable
{
  public let pairID: ClipLiveShareServerRoomV4PairID
  public let epoch: ClipLiveShareServerRoomV4PairEpoch
  public let remoteParticipantID: ClipLiveShareNativeV3ParticipantID

  public init(
    pairID: ClipLiveShareServerRoomV4PairID,
    epoch: ClipLiveShareServerRoomV4PairEpoch,
    remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) {
    self.pairID = pairID
    self.epoch = epoch
    self.remoteParticipantID = remoteParticipantID
  }

  public var id: ClipLiveShareServerRoomV4PairID { pairID }
}

public struct ClipLiveShareServerMeshPairSnapshot:
  Equatable, Sendable, Identifiable
{
  public let pairID: ClipLiveShareServerRoomV4PairID
  public let epoch: ClipLiveShareServerRoomV4PairEpoch
  public let link: ClipLiveShareNativeV3PeerLinkSnapshot

  public var id: ClipLiveShareNativeV3PeerLinkKey { link.key }
}

public struct ClipLiveShareServerMeshPairFailure:
  Equatable, Sendable, Identifiable
{
  public let pairID: ClipLiveShareServerRoomV4PairID
  public let epoch: ClipLiveShareServerRoomV4PairEpoch
  public let peerLinkKey: ClipLiveShareNativeV3PeerLinkKey
  public let remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  public let rosterRevision: ClipLiveShareServerRoomV4RosterRevision
  public let attempt: Int
  public let message: String

  public var id: ClipLiveShareNativeV3PeerLinkKey { peerLinkKey }
}

public struct ClipLiveShareServerMeshPeerReconcilerSnapshot:
  Equatable, Sendable
{
  /// The newest authoritative roster accepted from the room service.
  public let rosterRevision: ClipLiveShareServerRoomV4RosterRevision?
  public let rosterParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  /// Participants with a currently allocated local WebRTC transport. This can
  /// temporarily be smaller than `rosterParticipantIDs` after a pair-scoped
  /// creation failure; unaffected pairs remain usable while that pair retries.
  public let connectedParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  public let pairs: [ClipLiveShareServerMeshPairSnapshot]
  public let failedPairs: [ClipLiveShareServerMeshPairFailure]
  public let isClosed: Bool

  public var isLocallyComplete: Bool {
    !isClosed
      && failedPairs.isEmpty
      && connectedParticipantIDs == rosterParticipantIDs
      && pairs.count == max(0, rosterParticipantIDs.count - 1)
  }
}

public enum ClipLiveShareServerMeshRosterDisposition:
  Equatable, Sendable
{
  case applied
  case ignoredDuplicate
  case ignoredStale
}

public struct ClipLiveShareServerMeshReconciliationResult:
  Equatable, Sendable
{
  public let disposition: ClipLiveShareServerMeshRosterDisposition
  public let addedPairs: [ClipLiveShareServerMeshPairSnapshot]
  public let retainedPairs: [ClipLiveShareServerMeshPairSnapshot]
  public let removedPairKeys: [ClipLiveShareNativeV3PeerLinkKey]
  public let failedPairs: [ClipLiveShareServerMeshPairFailure]
  public let snapshot: ClipLiveShareServerMeshPeerReconcilerSnapshot
}

public enum ClipLiveShareServerMeshPeerReconcilerError:
  Error, Equatable, Sendable, LocalizedError
{
  case reconcilerClosed
  case reconciliationInProgress
  case localParticipantMissing
  case invalidLocalPairSet
  case conflictingRosterRevision(ClipLiveShareServerRoomV4RosterRevision)
  case peerNotInRoster(ClipLiveShareNativeV3ParticipantID)
  case pairRecreationFailed(ClipLiveShareNativeV3ParticipantID, String)

  public var errorDescription: String? {
    switch self {
    case .reconcilerClosed:
      "The server-coordinated mesh reconciler is closed."
    case .reconciliationInProgress:
      "A server roster reconciliation is already in progress."
    case .localParticipantMissing:
      "The server roster does not contain the local participant."
    case .invalidLocalPairSet:
      "The server roster does not contain exactly one pair binding per remote participant."
    case let .conflictingRosterRevision(revision):
      "Server roster revision \(revision) was reused with different members."
    case .peerNotInRoster:
      "The requested participant is not in the authoritative server roster."
    case let .pairRecreationFailed(_, message):
      "The participant connection could not be recreated: \(message)"
    }
  }
}

/// Reconciles an authoritative admitted roster into independent local pairs.
///
/// The existing peer-link manager remains the concrete owner of transports,
/// media, control channels and ICE recovery. This actor intentionally adds no
/// provisional admission or negotiation-handoff phase: every input member has
/// already been admitted by the room session, and every new transport starts
/// with outbound media enabled.
///
/// Each pair is added in its own manager transaction. A factory/start failure
/// for A-C is recorded against only A-C and cannot roll back an already live
/// A-B transport or prevent A-D from being attempted. Retained pairs are never
/// passed through a replacement path merely because the roster revision or an
/// unrelated member changed.
public actor ClipLiveShareServerMeshPeerReconciler {
  public nonisolated let localParticipantID:
    ClipLiveShareNativeV3ParticipantID

  private let peerLinkManager: ClipLiveShareNativeV3MeshPeerLinkManager
  private var rosterRevision: ClipLiveShareServerRoomV4RosterRevision?
  private var rosterParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  private var desiredPairs:
    [ClipLiveShareNativeV3ParticipantID: ClipLiveShareServerMeshDesiredPair] = [:]
  private var connectedParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  private var activePairs:
    [ClipLiveShareNativeV3ParticipantID: ClipLiveShareServerMeshDesiredPair] = [:]
  private var attemptCounts:
    [ClipLiveShareNativeV3ParticipantID: Int] = [:]
  private var failures:
    [ClipLiveShareNativeV3PeerLinkKey: ClipLiveShareServerMeshPairFailure] = [:]
  private var isReconciling = false
  private var isClosed = false

  public init(
    localParticipantID: ClipLiveShareNativeV3ParticipantID,
    peerLinkManager: ClipLiveShareNativeV3MeshPeerLinkManager
  ) {
    self.localParticipantID = localParticipantID
    self.peerLinkManager = peerLinkManager
    rosterParticipantIDs = [localParticipantID]
    connectedParticipantIDs = [localParticipantID]
  }

  /// Returns the concrete manager event stream used by the existing media and
  /// signaling adapters. Roster ownership stays with this reconciler; callers
  /// should not invoke the manager's membership reconciliation separately.
  public func peerLinkEvents() async
    -> AsyncStream<ClipLiveShareNativeV3MeshPeerLinkManagerEvent>
  {
    await peerLinkManager.events()
  }

  public func applyRoster(
    _ roster: ClipLiveShareServerMeshRosterSnapshot
  ) async throws -> ClipLiveShareServerMeshReconciliationResult {
    try beginOperation()
    defer { isReconciling = false }

    guard roster.participantIDs.contains(localParticipantID) else {
      throw ClipLiveShareServerMeshPeerReconcilerError.localParticipantMissing
    }
    _ = try ClipLiveShareNativeV3CompleteMeshTopology(
      participantIDs: roster.participantIDs
    )
    let remoteParticipantIDs = roster.participantIDs.subtracting([
      localParticipantID
    ])
    let localPairsByParticipant = Dictionary(
      grouping: roster.localPairs,
      by: \.remoteParticipantID
    )
    guard
      Set(localPairsByParticipant.keys) == remoteParticipantIDs,
      localPairsByParticipant.values.allSatisfy({ $0.count == 1 }),
      Set(roster.localPairs.map(\.pairID)).count == roster.localPairs.count
    else {
      throw ClipLiveShareServerMeshPeerReconcilerError.invalidLocalPairSet
    }
    let incomingPairs = localPairsByParticipant.mapValues { $0[0] }

    if let currentRevision = rosterRevision {
      if roster.revision < currentRevision {
        return await result(disposition: .ignoredStale)
      }
      if roster.revision == currentRevision {
        guard
          roster.participantIDs == rosterParticipantIDs,
          incomingPairs == desiredPairs
        else {
          throw ClipLiveShareServerMeshPeerReconcilerError
            .conflictingRosterRevision(roster.revision)
        }
        return await result(disposition: .ignoredDuplicate)
      }
    }

    let previousPairs = await pairSnapshotsByKey()
    let desiredPeers = remoteParticipantIDs
    let connectedPeers = connectedParticipantIDs.subtracting([
      localParticipantID
    ])
    let replacedPeers = connectedPeers.filter {
      guard let incomingPair = incomingPairs[$0] else { return false }
      return activePairs[$0] != incomingPair
    }
    let removedPeers = connectedPeers.subtracting(desiredPeers)
      .union(replacedPeers).sorted()

    // Remove obsolete pairs one at a time. Closing one transport cannot alter
    // the transport or epoch of any retained pair.
    for remoteParticipantID in removedPeers {
      var desiredConnected = connectedParticipantIDs
      desiredConnected.remove(remoteParticipantID)
      try await peerLinkManager.reconcileParticipants(desiredConnected)
      connectedParticipantIDs = desiredConnected
      let key = try ClipLiveShareNativeV3PeerLinkKey(
        localParticipantID,
        remoteParticipantID
      )
      activePairs[remoteParticipantID] = nil
      failures[key] = nil
      attemptCounts[remoteParticipantID] = nil
    }
    for remoteParticipantID in Set(desiredPairs.keys).subtracting(desiredPeers) {
      let key = try ClipLiveShareNativeV3PeerLinkKey(
        localParticipantID,
        remoteParticipantID
      )
      activePairs[remoteParticipantID] = nil
      failures[key] = nil
      attemptCounts[remoteParticipantID] = nil
    }

    rosterRevision = roster.revision
    rosterParticipantIDs = roster.participantIDs
    desiredPairs = incomingPairs

    // Re-attempt every desired peer that currently lacks a transport. Each
    // call creates at most one transport, so one failure cannot roll back a
    // different pair created earlier in this same roster application.
    for remoteParticipantID in desiredPeers.sorted()
    where !connectedParticipantIDs.contains(remoteParticipantID) {
      await attemptPair(
        incomingPairs[remoteParticipantID]!,
        rosterRevision: roster.revision
      )
    }

    let currentPairs = await pairSnapshotsByKey()
    let previousKeys = Set(previousPairs.keys)
    let currentKeys = Set(currentPairs.keys)
    let replacedKeys = previousKeys.intersection(currentKeys).filter { key in
      guard let previous = previousPairs[key], let current = currentPairs[key]
      else { return false }
      return previous.pairID != current.pairID
        || previous.epoch != current.epoch
    }
    let retainedKeys = currentKeys.intersection(previousKeys)
      .subtracting(replacedKeys)
    let addedKeys = currentKeys.subtracting(previousKeys).union(replacedKeys)
    let removedKeys = previousKeys.subtracting(currentKeys).union(replacedKeys)
    return ClipLiveShareServerMeshReconciliationResult(
      disposition: .applied,
      addedPairs: addedKeys.sorted().compactMap {
        currentPairs[$0]
      },
      retainedPairs: retainedKeys.sorted().compactMap {
        currentPairs[$0]
      },
      removedPairKeys: removedKeys.sorted(),
      failedPairs: failures.values.sorted {
        $0.peerLinkKey < $1.peerLinkKey
      },
      snapshot: await makeSnapshot()
    )
  }

  /// Explicitly retries one admitted pair without requiring a synthetic roster
  /// revision. This is intended for a bounded pair-local retry policy.
  @discardableResult
  public func retryPair(
    with remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws -> ClipLiveShareServerMeshPeerReconcilerSnapshot {
    try beginOperation()
    defer { isReconciling = false }
    guard let desiredPair = desiredPairs[remoteParticipantID] else {
      throw ClipLiveShareServerMeshPeerReconcilerError.peerNotInRoster(
        remoteParticipantID
      )
    }
    guard remoteParticipantID != localParticipantID else {
      throw ClipLiveShareServerMeshPeerReconcilerError.peerNotInRoster(
        remoteParticipantID
      )
    }
    if !connectedParticipantIDs.contains(remoteParticipantID) {
      await attemptPair(
        desiredPair,
        rosterRevision: rosterRevision!
      )
    }
    return await makeSnapshot()
  }

  /// Replaces exactly one structurally inconsistent peer connection while
  /// preserving the authoritative roster and every unrelated edge. ICE restart
  /// is insufficient after libwebrtc rejects an SDP media section because that
  /// peer connection can retain a mismatched Unified Plan transceiver layout.
  @discardableResult
  public func recreatePair(
    with remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws -> ClipLiveShareServerMeshPeerReconcilerSnapshot {
    try beginOperation()
    defer { isReconciling = false }
    guard remoteParticipantID != localParticipantID,
      let desiredPair = desiredPairs[remoteParticipantID],
      let rosterRevision
    else {
      throw ClipLiveShareServerMeshPeerReconcilerError.peerNotInRoster(
        remoteParticipantID
      )
    }

    if connectedParticipantIDs.contains(remoteParticipantID) {
      try await peerLinkManager.disconnectParticipant(remoteParticipantID)
      connectedParticipantIDs.remove(remoteParticipantID)
    }
    let key = try ClipLiveShareNativeV3PeerLinkKey(
      localParticipantID,
      remoteParticipantID
    )
    activePairs[remoteParticipantID] = nil
    failures[key] = nil
    attemptCounts[remoteParticipantID] = nil

    await attemptPair(desiredPair, rosterRevision: rosterRevision)
    if let failure = failures[key] {
      throw ClipLiveShareServerMeshPeerReconcilerError.pairRecreationFailed(
        remoteParticipantID,
        failure.message
      )
    }
    return await makeSnapshot()
  }

  public func snapshot() async
    -> ClipLiveShareServerMeshPeerReconcilerSnapshot
  {
    await makeSnapshot()
  }

  public func close() async {
    guard !isClosed else { return }
    isClosed = true
    await peerLinkManager.close()
  }

  private func beginOperation() throws {
    guard !isClosed else {
      throw ClipLiveShareServerMeshPeerReconcilerError.reconcilerClosed
    }
    guard !isReconciling else {
      throw ClipLiveShareServerMeshPeerReconcilerError
        .reconciliationInProgress
    }
    isReconciling = true
  }

  private func attemptPair(
    _ desiredPair: ClipLiveShareServerMeshDesiredPair,
    rosterRevision: ClipLiveShareServerRoomV4RosterRevision
  ) async {
    let remoteParticipantID = desiredPair.remoteParticipantID
    let key: ClipLiveShareNativeV3PeerLinkKey
    do {
      key = try ClipLiveShareNativeV3PeerLinkKey(
        localParticipantID,
        remoteParticipantID
      )
    } catch {
      return
    }
    let attempt = (attemptCounts[remoteParticipantID] ?? 0) + 1
    attemptCounts[remoteParticipantID] = attempt
    var desiredConnected = connectedParticipantIDs
    desiredConnected.insert(remoteParticipantID)
    do {
      try await peerLinkManager.reconcileParticipants(desiredConnected)
      activePairs[remoteParticipantID] = desiredPair
      connectedParticipantIDs = desiredConnected
      failures[key] = nil
    } catch {
      failures[key] = .init(
        pairID: desiredPair.pairID,
        epoch: desiredPair.epoch,
        peerLinkKey: key,
        remoteParticipantID: remoteParticipantID,
        rosterRevision: rosterRevision,
        attempt: attempt,
        message: String(String(describing: error).prefix(512))
      )
    }
  }

  private func pairSnapshotsByKey() async
    -> [ClipLiveShareNativeV3PeerLinkKey: ClipLiveShareServerMeshPairSnapshot]
  {
    let managerSnapshot = await peerLinkManager.snapshot()
    return Dictionary(
      uniqueKeysWithValues: managerSnapshot.links.compactMap { link in
        guard let activePair = activePairs[link.remoteParticipantID] else {
          return nil
        }
        return (
          link.key,
          .init(
            pairID: activePair.pairID,
            epoch: activePair.epoch,
            link: link
          )
        )
      }
    )
  }

  private func makeSnapshot() async
    -> ClipLiveShareServerMeshPeerReconcilerSnapshot
  {
    let pairsByKey = await pairSnapshotsByKey()
    return .init(
      rosterRevision: rosterRevision,
      rosterParticipantIDs: rosterParticipantIDs,
      connectedParticipantIDs: connectedParticipantIDs,
      pairs: pairsByKey.values.sorted { $0.id < $1.id },
      failedPairs: failures.values.sorted {
        $0.peerLinkKey < $1.peerLinkKey
      },
      isClosed: isClosed
    )
  }

  private func result(
    disposition: ClipLiveShareServerMeshRosterDisposition
  ) async -> ClipLiveShareServerMeshReconciliationResult {
    let snapshot = await makeSnapshot()
    return .init(
      disposition: disposition,
      addedPairs: [],
      retainedPairs: snapshot.pairs,
      removedPairKeys: [],
      failedPairs: snapshot.failedPairs,
      snapshot: snapshot
    )
  }
}
