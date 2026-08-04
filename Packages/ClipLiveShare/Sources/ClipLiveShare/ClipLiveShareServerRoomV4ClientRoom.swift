import CryptoKit
import Foundation

public enum ClipLiveShareServerRoomV4ClientRoomError: Error, Equatable,
  Sendable, LocalizedError
{
  case creatorOperationRequired
  case participantOperationRequired
  case invalidLocalIdentity
  case invalidLocalPairIdentity
  case invalidAccessWord
  case admissionDenied
  case conflictingCandidateRequest
  case candidateNotPending
  case roomIsFull
  case localMemberIsUnknown
  case localMemberMismatch
  case creatorMismatch
  case staleRoster
  case conflictingRosterRevision
  case memberDescriptorChanged
  case duplicateParticipantID
  case duplicatePersistentIdentity
  case duplicatePairIdentity
  case pairUnavailable
  case invalidReconnectCredential

  public var errorDescription: String? {
    switch self {
    case .creatorOperationRequired:
      "This operation is available only to the room creator."
    case .participantOperationRequired:
      "This operation is available only to an admitted participant."
    case .invalidLocalIdentity:
      "The local descriptor does not match its identity signer."
    case .invalidLocalPairIdentity:
      "The local descriptor does not match its pair-signaling key."
    case .invalidAccessWord:
      "The room access word proof is invalid."
    case .admissionDenied:
      "The room admission policy denied this participant."
    case .conflictingCandidateRequest:
      "This candidate handle was reused for a different join request."
    case .candidateNotPending:
      "This candidate has no pending join request."
    case .roomIsFull:
      "The room already contains the maximum number of participants."
    case .localMemberIsUnknown:
      "The service has not admitted this local participant yet."
    case .localMemberMismatch:
      "The roster does not bind the local handle to the local identity."
    case .creatorMismatch:
      "The roster does not preserve the invited room creator."
    case .staleRoster:
      "The roster revision is older than the applied room state."
    case .conflictingRosterRevision:
      "The same roster revision was reused for different room state."
    case .memberDescriptorChanged:
      "An admitted member descriptor changed without leaving the room."
    case .duplicateParticipantID:
      "The roster contains a duplicate room participant identifier."
    case .duplicatePersistentIdentity:
      "The roster contains a duplicate persistent identity."
    case .duplicatePairIdentity:
      "The roster contains a duplicate pair-signaling identity."
    case .pairUnavailable:
      "The requested direct peer pair is not available."
    case .invalidReconnectCredential:
      "The reconnect credential does not belong to this room."
    }
  }
}

public enum ClipLiveShareServerRoomV4ClientRole: String, Codable, Equatable,
  Hashable, Sendable
{
  case creator
  case participant
}

/// Creator-controlled policy evaluated after the room cipher and candidate
/// identity signature have already been verified. The verifier is injected so
/// app-owned policy can evolve without changing the stable invitation format.
public struct ClipLiveShareServerRoomV4AdmissionPolicy: Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public typealias AccessWordVerifier =
    @Sendable (ClipLiveShareServerRoomV4JoinKnock) -> Bool

  public let askBeforeJoining: Bool
  private let accessWordVerifier: AccessWordVerifier

  public init(
    askBeforeJoining: Bool,
    accessWordVerifier: @escaping AccessWordVerifier
  ) {
    self.askBeforeJoining = askBeforeJoining
    self.accessWordVerifier = accessWordVerifier
  }

  public static func open(askBeforeJoining: Bool = false) -> Self {
    Self(askBeforeJoining: askBeforeJoining) { _ in true }
  }

  public static func requiringAccessWord(
    _ accessWord: String,
    askBeforeJoining: Bool = false
  ) throws -> Self {
    let normalized = try normalizeAccessWord(accessWord)
    return Self(askBeforeJoining: askBeforeJoining) { knock in
      guard let supplied = knock.accessWordProof else { return false }
      return supplied
        == accessWordProof(
          normalizedAccessWord: normalized,
          roomID: knock.roomID,
          sessionID: knock.sessionID,
          descriptor: knock.descriptor,
          admissionCapability: knock.admissionCapability
        )
    }
  }

  public static func makeAccessWordProof(
    _ accessWord: String,
    invite: ClipLiveShareServerRoomV4Invite,
    descriptor: ClipLiveShareServerRoomV4MemberDescriptor
  ) throws -> ClipLiveShareNativeDigest {
    accessWordProof(
      normalizedAccessWord: try normalizeAccessWord(accessWord),
      roomID: invite.roomID,
      sessionID: invite.sessionID,
      descriptor: descriptor,
      admissionCapability: invite.admissionCapability
    )
  }

  func verify(_ knock: ClipLiveShareServerRoomV4JoinKnock) throws {
    guard accessWordVerifier(knock) else {
      throw ClipLiveShareServerRoomV4ClientRoomError.invalidAccessWord
    }
  }

  public var description: String {
    "ClipLiveShareServerRoomV4AdmissionPolicy(askBeforeJoining: "
      + "\(askBeforeJoining), accessWordVerifier: <redacted>)"
  }
  public var debugDescription: String { description }

  private static func normalizeAccessWord(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalized.isEmpty, normalized.utf8.count <= 256 else {
      throw ClipLiveShareServerRoomV4ClientRoomError.invalidAccessWord
    }
    return normalized
  }

  private static func accessWordProof(
    normalizedAccessWord: String,
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    descriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability
  ) -> ClipLiveShareNativeDigest {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/access-word-proof"
    )
    encoder.append(roomID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(descriptor.participantID.bytes)
    encoder.append(descriptor.identity.x963Representation)
    encoder.append(admissionCapability.keyMaterial)
    let authenticationCode = HMAC<SHA256>.authenticationCode(
      for: encoder.data,
      using: SymmetricKey(data: Data(normalizedAccessWord.utf8))
    )
    return try! ClipLiveShareNativeDigest(bytes: Data(authenticationCode))
  }
}

public struct ClipLiveShareServerRoomV4ReconnectCredential: Codable,
  Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let memberHandle: ClipLiveShareServerRoomV4MemberHandle
  public let reconnectCapability: ClipLiveShareServerRoomV4ReconnectCapability

  public init(
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    memberHandle: ClipLiveShareServerRoomV4MemberHandle,
    reconnectCapability: ClipLiveShareServerRoomV4ReconnectCapability
  ) {
    self.roomID = roomID
    self.sessionID = sessionID
    self.memberHandle = memberHandle
    self.reconnectCapability = reconnectCapability
  }

  public var description: String {
    "ClipLiveShareServerRoomV4ReconnectCredential(room: <redacted>, "
      + "member: <redacted>, capability: <redacted>)"
  }
  public var debugDescription: String { description }
}

public struct ClipLiveShareServerRoomV4PendingJoin: Equatable, Hashable,
  Sendable
{
  public let candidateHandle: ClipLiveShareServerRoomV4CandidateHandle
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let displayName: String
  public let deviceName: String
}

public struct ClipLiveShareServerRoomV4AdmissionCommand: Equatable, Sendable {
  public let candidateHandle: ClipLiveShareServerRoomV4CandidateHandle
  public let descriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord

  public var memberHandle: ClipLiveShareServerRoomV4MemberHandle {
    candidateHandle.admittedMemberHandle
  }

  public var wireMessage: ClipLiveShareServerRoomV4WireMessage {
    .admitCandidate(candidateHandle: candidateHandle, descriptor: descriptor)
  }
}

public enum ClipLiveShareServerRoomV4JoinDecision: Equatable, Sendable {
  case pendingApproval(ClipLiveShareServerRoomV4PendingJoin)
  case admit(ClipLiveShareServerRoomV4AdmissionCommand)
}

public struct ClipLiveShareServerRoomV4RosterTransition: Equatable, Sendable {
  public let revision: ClipLiveShareServerRoomV4RosterRevision
  public let addedPeers: Set<ClipLiveShareServerRoomV4MemberHandle>
  public let retainedPeers: Set<ClipLiveShareServerRoomV4MemberHandle>
  public let removedPeers: Set<ClipLiveShareServerRoomV4MemberHandle>
}

public struct ClipLiveShareServerRoomV4MemberSnapshot: Equatable, Sendable {
  public let handle: ClipLiveShareServerRoomV4MemberHandle
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let displayName: String
  public let deviceName: String
  public let connected: Bool
  public let isLocal: Bool
  public let isCreator: Bool
}

public struct ClipLiveShareServerRoomV4PairSnapshot: Equatable, Sendable {
  public let remoteHandle: ClipLiveShareServerRoomV4MemberHandle
  public let pairID: ClipLiveShareServerRoomV4PairID
  public let epoch: ClipLiveShareServerRoomV4PairEpoch
  public let initialOfferer: ClipLiveShareServerRoomV4MemberHandle
  public let lastOutboundSequence: UInt64
  public let lastInboundSequence: UInt64
}

/// Neutral, equatable observation of the client state. Private signing and key
/// agreement objects never escape through snapshots or descriptions.
public struct ClipLiveShareServerRoomV4ClientRoomSnapshot: Equatable, Sendable {
  public let role: ClipLiveShareServerRoomV4ClientRole
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let localHandle: ClipLiveShareServerRoomV4MemberHandle?
  public let rosterRevision: ClipLiveShareServerRoomV4RosterRevision?
  public let members: [ClipLiveShareServerRoomV4MemberSnapshot]
  public let pairs: [ClipLiveShareServerRoomV4PairSnapshot]
  public let pendingApprovals: [ClipLiveShareServerRoomV4PendingJoin]
}

/// One creator-authenticated member exposed to the app integration layer.
/// The descriptor contains public identity and pair-agreement keys only.
public struct ClipLiveShareServerRoomV4ClientVerifiedMember: Codable,
  Equatable, Sendable
{
  public let handle: ClipLiveShareServerRoomV4MemberHandle
  public let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
  public let connected: Bool
  public let isCreator: Bool
  public let isLocal: Bool
}

/// One retained direct pair from the local member to a verified remote member.
public struct ClipLiveShareServerRoomV4ClientVerifiedPair: Codable, Equatable,
  Sendable
{
  public let remoteHandle: ClipLiveShareServerRoomV4MemberHandle
  public let context: ClipLiveShareServerRoomV4PairContext
  public let epoch: ClipLiveShareServerRoomV4PairEpoch
}

/// Complete app-facing projection after a roster has passed room decryption,
/// creator signature checks, identity uniqueness checks, and local binding.
///
/// This value deliberately contains no room agreement secret, admission,
/// owner, or reconnect capability, persistent signer, or private pair key. It
/// can therefore cross the package/app boundary without requiring callers to
/// re-open private roster records.
public struct ClipLiveShareServerRoomV4ClientVerifiedRoomState: Codable,
  Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  public let role: ClipLiveShareServerRoomV4ClientRole
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let rosterRevision: ClipLiveShareServerRoomV4RosterRevision
  public let creatorHandle: ClipLiveShareServerRoomV4MemberHandle
  public let localHandle: ClipLiveShareServerRoomV4MemberHandle
  public let members: [ClipLiveShareServerRoomV4ClientVerifiedMember]
  public let pairs: [ClipLiveShareServerRoomV4ClientVerifiedPair]

  public var description: String {
    "ClipLiveShareServerRoomV4ClientVerifiedRoomState(identifiers: <redacted>, "
      + "members: \(members.count), pairs: \(pairs.count))"
  }
  public var debugDescription: String { description }
}

public struct ClipLiveShareServerRoomV4CreatorBootstrap: Sendable {
  public let room: ClipLiveShareServerRoomV4ClientRoom
  public let createRequest: ClipLiveShareServerRoomV4CreateRequest
  public let invite: ClipLiveShareServerRoomV4Invite
}

public struct ClipLiveShareServerRoomV4CandidateBootstrap: Sendable {
  public let room: ClipLiveShareServerRoomV4ClientRoom
  public let joinKnock: ClipLiveShareServerRoomV4OpaqueJoinKnock
}

/// Client-only state machine above opaque service transport and below WebRTC.
/// It treats each complete roster snapshot as the sole membership authority,
/// while every identity binding remains creator-signed and room-encrypted.
public struct ClipLiveShareServerRoomV4ClientRoom: Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let role: ClipLiveShareServerRoomV4ClientRole
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let creatorIdentity: ClipLiveShareIdentityPublicKey
  public let localDescriptor: ClipLiveShareServerRoomV4MemberDescriptor

  public private(set) var localHandle: ClipLiveShareServerRoomV4MemberHandle?
  public private(set) var reconnectCapability: ClipLiveShareServerRoomV4ReconnectCapability?
  public private(set) var admissionPolicy: ClipLiveShareServerRoomV4AdmissionPolicy

  private let roomCipher: ClipLiveShareServerRoomV4RoomCipher
  private let localSigner: any ClipLiveShareIdentitySigner
  private let localPairIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity
  private var inviteIssuer: ClipLiveShareServerRoomV4InviteIssuer?
  private var pinnedCreatorHandle: ClipLiveShareServerRoomV4MemberHandle?
  private var appliedRoster: ClipLiveShareServerRoomV4RosterSnapshot?
  private var verifiedMembers: [ClipLiveShareServerRoomV4MemberHandle: VerifiedMember] = [:]
  private var pairRuntimes: [ClipLiveShareServerRoomV4MemberHandle: PairRuntime] = [:]
  private var pendingKnocks:
    [ClipLiveShareServerRoomV4CandidateHandle:
      ClipLiveShareServerRoomV4SignedJoinKnock] = [:]
  private var issuedAdmissions:
    [ClipLiveShareServerRoomV4MemberHandle:
      IssuedAdmission] = [:]
  private var deniedKnocks:
    [ClipLiveShareServerRoomV4CandidateHandle:
      ClipLiveShareServerRoomV4SignedJoinKnock] = [:]
  private var deniedKnockOrder: [ClipLiveShareServerRoomV4CandidateHandle] = []

  public static func makeCreator(
    serviceEndpoint: URL,
    roomID: ClipLiveShareServerRoomV4RoomID,
    memberHandle: ClipLiveShareServerRoomV4MemberHandle,
    sessionID: ClipLiveShareSessionID,
    ownerCapability: ClipLiveShareServerRoomV4OwnerCapability,
    roomAgreementSecret: ClipLiveShareServerRoomV4RoomAgreementSecret,
    admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability,
    pairKeyIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity,
    localDescriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    signer: any ClipLiveShareIdentitySigner,
    roomCode: ClipLiveShareServerRoomV4RoomCode = .random(),
    admissionPolicy: ClipLiveShareServerRoomV4AdmissionPolicy = .open()
  ) throws -> ClipLiveShareServerRoomV4CreatorBootstrap {
    try validateLocalMaterial(
      descriptor: localDescriptor,
      signer: signer,
      pairKeyIdentity: pairKeyIdentity
    )
    let invite = try ClipLiveShareServerRoomV4Invite(
      serviceEndpoint: serviceEndpoint,
      roomID: roomID,
      sessionID: sessionID,
      creatorIdentity: signer.publicKey,
      roomAgreementSecret: roomAgreementSecret,
      admissionCapability: admissionCapability,
      roomCode: roomCode
    )
    let cipher = ClipLiveShareServerRoomV4RoomCipher(
      roomID: roomID,
      sessionID: sessionID,
      roomAgreementSecret: roomAgreementSecret
    )
    let record = ClipLiveShareServerRoomV4AdmissionRecord(
      roomID: roomID,
      sessionID: sessionID,
      memberHandle: memberHandle,
      descriptor: localDescriptor
    )
    let sealedRecord = try cipher.sealAdmissionRecord(
      ClipLiveShareServerRoomV4SignedAdmissionRecord(
        signing: record,
        with: signer
      )
    )
    let room = Self(
      role: .creator,
      invite: invite,
      localHandle: memberHandle,
      reconnectCapability: nil,
      localDescriptor: localDescriptor,
      signer: signer,
      pairKeyIdentity: pairKeyIdentity,
      admissionPolicy: admissionPolicy,
      inviteIssuer: .init(currentInvite: invite),
      pinnedCreatorHandle: memberHandle
    )
    return ClipLiveShareServerRoomV4CreatorBootstrap(
      room: room,
      createRequest: .init(
        ownerToken: ownerCapability,
        creatorHandle: memberHandle,
        descriptor: sealedRecord
      ),
      invite: invite
    )
  }

  public static func makeCandidate(
    invite: ClipLiveShareServerRoomV4Invite,
    pairKeyIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity,
    localDescriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    signer: any ClipLiveShareIdentitySigner,
    accessWord: String? = nil,
    requiresCreatorApproval: Bool = false
  ) throws -> ClipLiveShareServerRoomV4CandidateBootstrap {
    try validateLocalMaterial(
      descriptor: localDescriptor,
      signer: signer,
      pairKeyIdentity: pairKeyIdentity
    )
    let proof = try accessWord.map {
      try ClipLiveShareServerRoomV4AdmissionPolicy.makeAccessWordProof(
        $0,
        invite: invite,
        descriptor: localDescriptor
      )
    }
    let knock = try ClipLiveShareServerRoomV4JoinKnock(
      roomID: invite.roomID,
      sessionID: invite.sessionID,
      descriptor: localDescriptor,
      admissionCapability: invite.admissionCapability,
      accessWordProof: proof,
      requiresCreatorApproval: requiresCreatorApproval
    )
    let cipher = ClipLiveShareServerRoomV4RoomCipher(
      roomID: invite.roomID,
      sessionID: invite.sessionID,
      roomAgreementSecret: invite.roomAgreementSecret
    )
    return ClipLiveShareServerRoomV4CandidateBootstrap(
      room: Self(
        role: .participant,
        invite: invite,
        localHandle: nil,
        reconnectCapability: nil,
        localDescriptor: localDescriptor,
        signer: signer,
        pairKeyIdentity: pairKeyIdentity,
        admissionPolicy: .open(),
        inviteIssuer: nil,
        pinnedCreatorHandle: nil
      ),
      joinKnock: try cipher.sealJoinKnock(
        ClipLiveShareServerRoomV4SignedJoinKnock(
          signing: knock,
          with: signer
        )
      )
    )
  }

  public static func makeReconnectingParticipant(
    invite: ClipLiveShareServerRoomV4Invite,
    credential: ClipLiveShareServerRoomV4ReconnectCredential,
    pairKeyIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity,
    localDescriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    signer: any ClipLiveShareIdentitySigner
  ) throws -> Self {
    try validateLocalMaterial(
      descriptor: localDescriptor,
      signer: signer,
      pairKeyIdentity: pairKeyIdentity
    )
    guard
      credential.roomID == invite.roomID,
      credential.sessionID == invite.sessionID
    else {
      throw ClipLiveShareServerRoomV4ClientRoomError.invalidReconnectCredential
    }
    return Self(
      role: .participant,
      invite: invite,
      localHandle: credential.memberHandle,
      reconnectCapability: credential.reconnectCapability,
      localDescriptor: localDescriptor,
      signer: signer,
      pairKeyIdentity: pairKeyIdentity,
      admissionPolicy: .open(),
      inviteIssuer: nil,
      pinnedCreatorHandle: nil
    )
  }

  private init(
    role: ClipLiveShareServerRoomV4ClientRole,
    invite: ClipLiveShareServerRoomV4Invite,
    localHandle: ClipLiveShareServerRoomV4MemberHandle?,
    reconnectCapability: ClipLiveShareServerRoomV4ReconnectCapability?,
    localDescriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    signer: any ClipLiveShareIdentitySigner,
    pairKeyIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity,
    admissionPolicy: ClipLiveShareServerRoomV4AdmissionPolicy,
    inviteIssuer: ClipLiveShareServerRoomV4InviteIssuer?,
    pinnedCreatorHandle: ClipLiveShareServerRoomV4MemberHandle?
  ) {
    self.role = role
    roomID = invite.roomID
    sessionID = invite.sessionID
    creatorIdentity = invite.creatorIdentity
    self.localHandle = localHandle
    self.reconnectCapability = reconnectCapability
    self.localDescriptor = localDescriptor
    localSigner = signer
    localPairIdentity = pairKeyIdentity
    self.admissionPolicy = admissionPolicy
    self.inviteIssuer = inviteIssuer
    self.pinnedCreatorHandle = pinnedCreatorHandle
    roomCipher = .init(
      roomID: invite.roomID,
      sessionID: invite.sessionID,
      roomAgreementSecret: invite.roomAgreementSecret
    )
  }

  public var currentInvite: ClipLiveShareServerRoomV4Invite? {
    inviteIssuer?.currentInvite
  }

  public mutating func setAdmissionPolicy(
    _ policy: ClipLiveShareServerRoomV4AdmissionPolicy
  ) throws {
    guard role == .creator else {
      throw ClipLiveShareServerRoomV4ClientRoomError.creatorOperationRequired
    }
    admissionPolicy = policy
  }

  @discardableResult
  public mutating func rotateInvite(
    to capability: ClipLiveShareServerRoomV4AdmissionCapability = .random()
  ) throws -> ClipLiveShareServerRoomV4Invite {
    guard role == .creator, var issuer = inviteIssuer else {
      throw ClipLiveShareServerRoomV4ClientRoomError.creatorOperationRequired
    }
    let invite = try issuer.rotateInvite(to: capability)
    inviteIssuer = issuer
    pendingKnocks.removeAll()
    deniedKnocks.removeAll()
    deniedKnockOrder.removeAll()
    return invite
  }

  public mutating func consumeForwardedJoinKnock(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle,
    payload: ClipLiveShareServerRoomV4OpaqueJoinKnock
  ) throws -> ClipLiveShareServerRoomV4JoinDecision {
    guard role == .creator, let issuer = inviteIssuer else {
      throw ClipLiveShareServerRoomV4ClientRoomError.creatorOperationRequired
    }
    let signed = try roomCipher.openJoinKnock(payload)
    try signed.verify(
      roomID: roomID,
      sessionID: sessionID,
      admissionCapability: issuer.currentInvite.admissionCapability
    )

    // Candidate messages are transported over a reconnecting socket. A send
    // can therefore succeed even when either side observes a timeout. Keep the
    // first authenticated request as the candidate-handle idempotency key:
    // exact replays reproduce the prior result, while handle reuse with a
    // different signed knock is rejected before it can affect room state.
    if let pending = pendingKnocks[candidateHandle] {
      guard pending == signed else {
        throw ClipLiveShareServerRoomV4ClientRoomError.conflictingCandidateRequest
      }
      return .pendingApproval(
        pendingSnapshot(candidateHandle: candidateHandle, signed: pending)
      )
    }
    if let issued = issuedAdmissions[candidateHandle.admittedMemberHandle] {
      guard issued.signedKnock == signed else {
        throw ClipLiveShareServerRoomV4ClientRoomError.conflictingCandidateRequest
      }
      return .admit(
        .init(candidateHandle: candidateHandle, descriptor: issued.sealed)
      )
    }
    if let denied = deniedKnocks[candidateHandle] {
      guard denied == signed else {
        throw ClipLiveShareServerRoomV4ClientRoomError.conflictingCandidateRequest
      }
      throw ClipLiveShareServerRoomV4ClientRoomError.admissionDenied
    }

    var reservedHandles = Set(verifiedMembers.keys)
    reservedHandles.formUnion(issuedAdmissions.keys)
    reservedHandles.formUnion(pendingKnocks.keys.map(\.admittedMemberHandle))
    if let localHandle { reservedHandles.insert(localHandle) }
    let admittedCount = reservedHandles.count
    guard admittedCount < ClipLiveShareServerRoomV4.maximumParticipants else {
      throw ClipLiveShareServerRoomV4ClientRoomError.roomIsFull
    }
    try admissionPolicy.verify(signed.knock)
    try validateCandidateDescriptor(
      signed.knock.descriptor,
      candidateHandle: candidateHandle
    )
    if admissionPolicy.askBeforeJoining || signed.knock.requiresCreatorApproval {
      pendingKnocks[candidateHandle] = signed
      return .pendingApproval(
        pendingSnapshot(candidateHandle: candidateHandle, signed: signed)
      )
    }
    return .admit(
      try issueAdmission(candidateHandle: candidateHandle, signed: signed)
    )
  }

  public mutating func approve(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle
  ) throws -> ClipLiveShareServerRoomV4AdmissionCommand {
    guard role == .creator else {
      throw ClipLiveShareServerRoomV4ClientRoomError.creatorOperationRequired
    }
    if let issued = issuedAdmissions[candidateHandle.admittedMemberHandle] {
      return .init(candidateHandle: candidateHandle, descriptor: issued.sealed)
    }
    if deniedKnocks[candidateHandle] != nil {
      throw ClipLiveShareServerRoomV4ClientRoomError.admissionDenied
    }
    guard let signed = pendingKnocks.removeValue(forKey: candidateHandle) else {
      throw ClipLiveShareServerRoomV4ClientRoomError.candidateNotPending
    }
    try validateCandidateDescriptor(
      signed.knock.descriptor,
      candidateHandle: candidateHandle
    )
    return try issueAdmission(candidateHandle: candidateHandle, signed: signed)
  }

  @discardableResult
  public mutating func deny(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle
  ) throws -> ClipLiveShareServerRoomV4CandidateHandle {
    guard role == .creator else {
      throw ClipLiveShareServerRoomV4ClientRoomError.creatorOperationRequired
    }
    if deniedKnocks[candidateHandle] != nil {
      return candidateHandle
    }
    if issuedAdmissions[candidateHandle.admittedMemberHandle] != nil {
      throw ClipLiveShareServerRoomV4ClientRoomError.admissionDenied
    }
    guard let signed = pendingKnocks.removeValue(forKey: candidateHandle) else {
      throw ClipLiveShareServerRoomV4ClientRoomError.candidateNotPending
    }
    rememberDenied(signed, candidateHandle: candidateHandle)
    return candidateHandle
  }

  /// Forgets one candidate whose server-side socket or admission transaction
  /// was definitively abandoned. The server remains authoritative for that
  /// lifetime, so repeated detach/rollback notifications are idempotent. Both
  /// a pending approval and an issued-but-not-rostered admission are removed,
  /// allowing the same identity to reconnect under a fresh candidate handle.
  @discardableResult
  public mutating func forgetCandidate(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle
  ) throws -> Bool {
    guard role == .creator else {
      throw ClipLiveShareServerRoomV4ClientRoomError.creatorOperationRequired
    }
    let removedPending = pendingKnocks.removeValue(forKey: candidateHandle) != nil
    let removedAdmission =
      issuedAdmissions.removeValue(
        forKey: candidateHandle.admittedMemberHandle
      ) != nil
    let removedDenial = deniedKnocks.removeValue(forKey: candidateHandle) != nil
    if removedDenial {
      deniedKnockOrder.removeAll { $0 == candidateHandle }
    }
    return removedPending || removedAdmission || removedDenial
  }

  public mutating func consumeMemberAdmitted(
    memberHandle: ClipLiveShareServerRoomV4MemberHandle,
    reconnectCapability: ClipLiveShareServerRoomV4ReconnectCapability?,
    roster: ClipLiveShareServerRoomV4RosterSnapshot
  ) throws -> ClipLiveShareServerRoomV4RosterTransition {
    if let existing = localHandle, existing != memberHandle {
      throw ClipLiveShareServerRoomV4ClientRoomError.localMemberMismatch
    }
    if role == .participant,
      self.reconnectCapability == nil,
      reconnectCapability == nil
    {
      throw ClipLiveShareServerRoomV4ClientRoomError.invalidReconnectCredential
    }
    let transition = try stagedRosterTransition(
      roster,
      expectedLocalHandle: memberHandle
    )
    localHandle = memberHandle
    if let reconnectCapability {
      self.reconnectCapability = reconnectCapability
    }
    commit(transition)
    return transition.publicValue
  }

  public mutating func consumeRosterSnapshot(
    _ roster: ClipLiveShareServerRoomV4RosterSnapshot
  ) throws -> ClipLiveShareServerRoomV4RosterTransition {
    guard let localHandle else {
      throw ClipLiveShareServerRoomV4ClientRoomError.localMemberIsUnknown
    }
    let transition = try stagedRosterTransition(
      roster,
      expectedLocalHandle: localHandle
    )
    commit(transition)
    return transition.publicValue
  }

  public func exportReconnectCredential() throws
    -> ClipLiveShareServerRoomV4ReconnectCredential
  {
    guard role == .participant, let localHandle, let reconnectCapability else {
      throw ClipLiveShareServerRoomV4ClientRoomError.participantOperationRequired
    }
    return .init(
      roomID: roomID,
      sessionID: sessionID,
      memberHandle: localHandle,
      reconnectCapability: reconnectCapability
    )
  }

  public mutating func sealPairSignal(
    to remoteHandle: ClipLiveShareServerRoomV4MemberHandle,
    payload: ClipLiveShareServerRoomV4PairSignalPayload
  ) throws -> ClipLiveShareServerRoomV4PairSignalEnvelope {
    guard var runtime = pairRuntimes[remoteHandle] else {
      throw ClipLiveShareServerRoomV4ClientRoomError.pairUnavailable
    }
    let envelope = try runtime.channel.seal(payload)
    pairRuntimes[remoteHandle] = runtime
    return envelope
  }

  public mutating func openPairSignal(
    _ envelope: ClipLiveShareServerRoomV4PairSignalEnvelope
  ) throws -> ClipLiveShareServerRoomV4PairSignalPayload {
    guard let sender = envelope.from, var runtime = pairRuntimes[sender] else {
      throw ClipLiveShareServerRoomV4ClientRoomError.pairUnavailable
    }
    let payload = try runtime.channel.open(envelope)
    pairRuntimes[sender] = runtime
    return payload
  }

  public var snapshot: ClipLiveShareServerRoomV4ClientRoomSnapshot {
    let members = verifiedMembers.values.sorted { $0.handle < $1.handle }.map {
      ClipLiveShareServerRoomV4MemberSnapshot(
        handle: $0.handle,
        participantID: $0.descriptor.participantID,
        displayName: $0.descriptor.displayName,
        deviceName: $0.descriptor.deviceName,
        connected: $0.connected,
        isLocal: $0.handle == localHandle,
        isCreator: $0.handle == pinnedCreatorHandle
      )
    }
    let pairs = pairRuntimes.values.sorted {
      $0.channel.remoteHandle < $1.channel.remoteHandle
    }.map {
      ClipLiveShareServerRoomV4PairSnapshot(
        remoteHandle: $0.channel.remoteHandle,
        pairID: $0.negotiation.context.pairID,
        epoch: $0.negotiation.epoch,
        initialOfferer: $0.negotiation.context.initialOfferer,
        lastOutboundSequence: $0.channel.lastOutboundSequence,
        lastInboundSequence: $0.channel.lastInboundSequence
      )
    }
    let pending = pendingKnocks.map {
      pendingSnapshot(candidateHandle: $0.key, signed: $0.value)
    }.sorted { $0.candidateHandle < $1.candidateHandle }
    return .init(
      role: role,
      roomID: roomID,
      sessionID: sessionID,
      localHandle: localHandle,
      rosterRevision: appliedRoster?.revision,
      members: members,
      pairs: pairs,
      pendingApprovals: pending
    )
  }

  /// The last completely verified room projection, or `nil` before the first
  /// authoritative roster has identified the local participant.
  public var clientVerifiedState: ClipLiveShareServerRoomV4ClientVerifiedRoomState? {
    guard let appliedRoster, let localHandle, let pinnedCreatorHandle else {
      return nil
    }
    let members = verifiedMembers.values.sorted {
      $0.handle.rawValue < $1.handle.rawValue
    }.map {
      ClipLiveShareServerRoomV4ClientVerifiedMember(
        handle: $0.handle,
        descriptor: $0.descriptor,
        connected: $0.connected,
        isCreator: $0.handle == pinnedCreatorHandle,
        isLocal: $0.handle == localHandle
      )
    }
    let pairs = pairRuntimes.values.sorted {
      $0.channel.remoteHandle.rawValue < $1.channel.remoteHandle.rawValue
    }.map {
      ClipLiveShareServerRoomV4ClientVerifiedPair(
        remoteHandle: $0.channel.remoteHandle,
        context: $0.negotiation.context,
        epoch: $0.negotiation.epoch
      )
    }
    return .init(
      role: role,
      roomID: roomID,
      sessionID: sessionID,
      rosterRevision: appliedRoster.revision,
      creatorHandle: pinnedCreatorHandle,
      localHandle: localHandle,
      members: members,
      pairs: pairs
    )
  }

  public var description: String {
    "ClipLiveShareServerRoomV4ClientRoom(role: \(role.rawValue), "
      + "room: <redacted>, localHandle: <redacted>, secrets: <redacted>)"
  }
  public var debugDescription: String { description }

  private static func validateLocalMaterial(
    descriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    signer: any ClipLiveShareIdentitySigner,
    pairKeyIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity
  ) throws {
    guard descriptor.identity == signer.publicKey else {
      throw ClipLiveShareServerRoomV4ClientRoomError.invalidLocalIdentity
    }
    guard descriptor.pairSignalingPublicKey == pairKeyIdentity.publicKey else {
      throw ClipLiveShareServerRoomV4ClientRoomError.invalidLocalPairIdentity
    }
  }

  private func pendingSnapshot(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle,
    signed: ClipLiveShareServerRoomV4SignedJoinKnock
  ) -> ClipLiveShareServerRoomV4PendingJoin {
    .init(
      candidateHandle: candidateHandle,
      participantID: signed.knock.descriptor.participantID,
      displayName: signed.knock.descriptor.displayName,
      deviceName: signed.knock.descriptor.deviceName
    )
  }

  private mutating func issueAdmission(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle,
    signed: ClipLiveShareServerRoomV4SignedJoinKnock
  ) throws -> ClipLiveShareServerRoomV4AdmissionCommand {
    let memberHandle = candidateHandle.admittedMemberHandle
    if let existing = issuedAdmissions[memberHandle] {
      guard existing.signedKnock == signed else {
        throw ClipLiveShareServerRoomV4ClientRoomError.conflictingCandidateRequest
      }
      return .init(candidateHandle: candidateHandle, descriptor: existing.sealed)
    }
    let record = ClipLiveShareServerRoomV4AdmissionRecord(
      roomID: roomID,
      sessionID: sessionID,
      memberHandle: memberHandle,
      descriptor: signed.knock.descriptor
    )
    let sealed = try roomCipher.sealAdmissionRecord(
      ClipLiveShareServerRoomV4SignedAdmissionRecord(
        signing: record,
        with: localSigner
      )
    )
    issuedAdmissions[memberHandle] = .init(
      descriptor: signed.knock.descriptor,
      signedKnock: signed,
      sealed: sealed
    )
    return .init(candidateHandle: candidateHandle, descriptor: sealed)
  }

  private func validateCandidateDescriptor(
    _ descriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle
  ) throws {
    guard candidateHandle.admittedMemberHandle != localHandle else {
      throw ClipLiveShareServerRoomV4ClientRoomError.admissionDenied
    }
    let allDescriptors =
      verifiedMembers.values.map(\.descriptor)
      + issuedAdmissions.values.map(\.descriptor)
      + pendingKnocks.filter { $0.key != candidateHandle }.map(\.value.knock.descriptor)
    guard !allDescriptors.contains(where: { $0.participantID == descriptor.participantID }) else {
      throw ClipLiveShareServerRoomV4ClientRoomError.duplicateParticipantID
    }
    guard !allDescriptors.contains(where: { $0.identity == descriptor.identity }) else {
      throw ClipLiveShareServerRoomV4ClientRoomError.duplicatePersistentIdentity
    }
    guard
      !allDescriptors.contains(where: {
        $0.pairSignalingPublicKey == descriptor.pairSignalingPublicKey
      })
    else {
      throw ClipLiveShareServerRoomV4ClientRoomError.duplicatePairIdentity
    }
  }

  private func stagedRosterTransition(
    _ roster: ClipLiveShareServerRoomV4RosterSnapshot,
    expectedLocalHandle: ClipLiveShareServerRoomV4MemberHandle
  ) throws -> StagedRosterTransition {
    if let appliedRoster {
      if roster.revision < appliedRoster.revision {
        throw ClipLiveShareServerRoomV4ClientRoomError.staleRoster
      }
      if roster.revision == appliedRoster.revision {
        guard roster == appliedRoster else {
          throw ClipLiveShareServerRoomV4ClientRoomError.conflictingRosterRevision
        }
        return .init(
          roster: roster,
          creatorHandle: pinnedCreatorHandle ?? roster.creatorHandle,
          members: verifiedMembers,
          pairs: pairRuntimes,
          publicValue: .init(
            revision: roster.revision,
            addedPeers: [],
            retainedPeers: Set(pairRuntimes.keys),
            removedPeers: []
          )
        )
      }
    }

    var members: [ClipLiveShareServerRoomV4MemberHandle: VerifiedMember] = [:]
    var participantIDs = Set<ClipLiveShareNativeV3ParticipantID>()
    var identities = Set<ClipLiveShareIdentityPublicKey>()
    var pairIdentities = Set<ClipLiveShareKeyAgreementPublicKey>()
    for rosterMember in roster.members {
      let signed = try roomCipher.openAdmissionRecord(rosterMember.descriptor)
      try signed.verify(
        creatorIdentity: creatorIdentity,
        roomID: roomID,
        sessionID: sessionID,
        expectedHandle: rosterMember.handle
      )
      let descriptor = signed.record.descriptor
      guard participantIDs.insert(descriptor.participantID).inserted else {
        throw ClipLiveShareServerRoomV4ClientRoomError.duplicateParticipantID
      }
      guard identities.insert(descriptor.identity).inserted else {
        throw ClipLiveShareServerRoomV4ClientRoomError.duplicatePersistentIdentity
      }
      guard pairIdentities.insert(descriptor.pairSignalingPublicKey).inserted else {
        throw ClipLiveShareServerRoomV4ClientRoomError.duplicatePairIdentity
      }
      if let prior = verifiedMembers[rosterMember.handle], prior.descriptor != descriptor {
        throw ClipLiveShareServerRoomV4ClientRoomError.memberDescriptorChanged
      }
      members[rosterMember.handle] = .init(
        handle: rosterMember.handle,
        descriptor: descriptor,
        connected: rosterMember.connected
      )
    }

    guard
      let creator = members[roster.creatorHandle],
      creator.descriptor.identity == creatorIdentity,
      pinnedCreatorHandle.map({ $0 == roster.creatorHandle }) ?? true
    else {
      throw ClipLiveShareServerRoomV4ClientRoomError.creatorMismatch
    }
    guard
      let local = members[expectedLocalHandle],
      local.descriptor == localDescriptor
    else {
      throw ClipLiveShareServerRoomV4ClientRoomError.localMemberMismatch
    }

    let plan = try ClipLiveShareServerRoomV4PairReconciliationPlan(
      existingPeers: Set(pairRuntimes.keys),
      localHandle: expectedLocalHandle,
      snapshot: roster
    )
    var pairs: [ClipLiveShareServerRoomV4MemberHandle: PairRuntime] = [:]
    for remoteHandle in plan.retained {
      guard let runtime = pairRuntimes[remoteHandle] else {
        throw ClipLiveShareServerRoomV4ClientRoomError.pairUnavailable
      }
      pairs[remoteHandle] = runtime
    }
    for remoteHandle in plan.added {
      guard let remote = members[remoteHandle] else {
        throw ClipLiveShareServerRoomV4ClientRoomError.pairUnavailable
      }
      let context = try ClipLiveShareServerRoomV4PairContext(
        roomID: roomID,
        sessionID: sessionID,
        firstHandle: expectedLocalHandle,
        firstParticipantID: localDescriptor.participantID,
        secondHandle: remoteHandle,
        secondParticipantID: remote.descriptor.participantID
      )
      pairs[remoteHandle] = try .init(
        negotiation: .init(context: context, epoch: .init(rawValue: 1)),
        channel: .init(
          context: context,
          localHandle: expectedLocalHandle,
          localKeyAgreementIdentity: localPairIdentity,
          localIdentitySigner: localSigner,
          remoteKeyAgreementPublicKey: remote.descriptor.pairSignalingPublicKey,
          remoteIdentity: remote.descriptor.identity
        )
      )
    }
    return .init(
      roster: roster,
      creatorHandle: roster.creatorHandle,
      members: members,
      pairs: pairs,
      publicValue: .init(
        revision: roster.revision,
        addedPeers: plan.added,
        retainedPeers: plan.retained,
        removedPeers: plan.removed
      )
    )
  }

  private mutating func commit(_ transition: StagedRosterTransition) {
    appliedRoster = transition.roster
    pinnedCreatorHandle = transition.creatorHandle
    verifiedMembers = transition.members
    pairRuntimes = transition.pairs
    issuedAdmissions = issuedAdmissions.filter {
      transition.members[$0.key] == nil
    }
  }

  private mutating func rememberDenied(
    _ signed: ClipLiveShareServerRoomV4SignedJoinKnock,
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle
  ) {
    deniedKnocks[candidateHandle] = signed
    deniedKnockOrder.removeAll { $0 == candidateHandle }
    deniedKnockOrder.append(candidateHandle)
    while deniedKnockOrder.count > Self.maximumRememberedDenials {
      deniedKnocks.removeValue(forKey: deniedKnockOrder.removeFirst())
    }
  }

  // Denial records exist only to bridge an ambiguous transport outcome. Keep
  // them bounded so untrusted candidate churn cannot grow creator memory for
  // the lifetime of a room.
  private static let maximumRememberedDenials =
    ClipLiveShareServerRoomV4.maximumParticipants * 4

  private struct VerifiedMember: Sendable {
    let handle: ClipLiveShareServerRoomV4MemberHandle
    let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
    let connected: Bool
  }

  private struct PairRuntime: Sendable {
    var negotiation: ClipLiveShareServerRoomV4PairNegotiationState
    var channel: ClipLiveShareServerRoomV4EncryptedPairSignalingChannel
  }

  private struct IssuedAdmission: Sendable {
    let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
    let signedKnock: ClipLiveShareServerRoomV4SignedJoinKnock
    let sealed: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
  }

  private struct StagedRosterTransition: Sendable {
    let roster: ClipLiveShareServerRoomV4RosterSnapshot
    let creatorHandle: ClipLiveShareServerRoomV4MemberHandle
    let members: [ClipLiveShareServerRoomV4MemberHandle: VerifiedMember]
    let pairs: [ClipLiveShareServerRoomV4MemberHandle: PairRuntime]
    let publicValue: ClipLiveShareServerRoomV4RosterTransition
  }
}
