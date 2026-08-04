import ClipLiveShare
import ClipLiveShareWebRTC
import Darwin
import Foundation

private struct AcceptanceFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private struct AcceptanceReport: Codable {
  let protocolVersion: Int
  let participantCount: Int
  let stableInviteAcrossJoins: Bool
  let authoritativeRosterSizes: [Int]
  let unorderedPairCounts: [Int]
  let directedEncryptedSignals: Int
  let acceptedGappedSequence: UInt64
  let existingSocketReconnects: Int
  let memberLeaveRemainingParticipants: Int
  let memberLeaveRemainingPairs: Int
  let sameInviteRejoinParticipants: Int
  let sameInviteRejoinPairs: Int
  let sameInviteRejoinDirectedSignals: Int
  let creatorLeaveRoomEndedRecipients: Int
  let friendHandshakeCommitted: Bool
  let creatorFriendPresencePublished: Bool
  let friendPresenceReusableInvite: Bool
  let ordinaryParticipantPresenceAbsent: Bool
  let auditedServerVisibleRecords: Int
  let privateValuesExposed: Int
}

private struct FriendPresenceAcceptanceResult: Sendable {
  let privateNeedles: [String]
}

private struct ParticipantMaterial: Sendable {
  let signer: ClipLiveShareSoftwareIdentitySigner
  let pairIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity
  let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
  let privateNeedles: [String]

  init(index: Int) throws {
    signer = .init()
    pairIdentity = .init()
    let displayName = "V4-PRIVATE-DISPLAY-NAME-\(index)-C4E8D9"
    let deviceName = "V4-PRIVATE-DEVICE-NAME-\(index)-A7F2B1"
    descriptor = try .init(
      participantID: .random(),
      identity: signer.publicKey,
      pairSignalingPublicKey: pairIdentity.publicKey,
      displayName: displayName,
      deviceName: deviceName
    )
    privateNeedles = [
      signer.publicKey.rawValue,
      displayName,
      deviceName,
    ]
  }

  private init(
    signer: ClipLiveShareSoftwareIdentitySigner,
    pairIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity,
    descriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    privateNeedles: [String]
  ) {
    self.signer = signer
    self.pairIdentity = pairIdentity
    self.descriptor = descriptor
    self.privateNeedles = privateNeedles
  }

  func rejoining() throws -> Self {
    let freshPairIdentity =
      ClipLiveShareServerRoomV4KeyAgreementIdentity()
    return try .init(
      signer: signer,
      pairIdentity: freshPairIdentity,
      descriptor: .init(
        participantID: .random(),
        identity: signer.publicKey,
        pairSignalingPublicKey: freshPairIdentity.publicKey,
        displayName: descriptor.displayName,
        deviceName: descriptor.deviceName
      ),
      privateNeedles: privateNeedles
    )
  }
}

private struct OpenedSignal: Equatable, Sendable {
  let from: ClipLiveShareServerRoomV4MemberHandle
  let payload: ClipLiveShareServerRoomV4PairSignalPayload
}

private struct ParticipantConnectionSummary: Equatable, Sendable {
  let connected: Int
  let reconnecting: Int
  let closed: Int
}

private actor AcceptanceParticipant {
  let label: String
  private var room: ClipLiveShareServerRoomV4ClientRoom
  private let transport: ClipLiveShareServerRoomV4Transport
  private let candidateKnock: ClipLiveShareServerRoomV4OpaqueJoinKnock?
  private let target: ClipLiveShareServerRoomV4Target
  private let capabilities: ClipLiveShareServerRoomV4Capabilities
  private let ownerCapability: ClipLiveShareServerRoomV4OwnerCapability?

  private var listener: Task<Void, Never>?
  private var wireRosters: [ClipLiveShareServerRoomV4RosterSnapshot] = []
  private var openedSignals: [OpenedSignal] = []
  private var transportEvents: [ClipLiveShareServerRoomV4TransportEvent] = []
  private var roomEndedReasons: [String] = []
  private var failureDescription: String?

  init(
    label: String,
    room: ClipLiveShareServerRoomV4ClientRoom,
    candidateKnock: ClipLiveShareServerRoomV4OpaqueJoinKnock?,
    target: ClipLiveShareServerRoomV4Target,
    capabilities: ClipLiveShareServerRoomV4Capabilities,
    ownerCapability: ClipLiveShareServerRoomV4OwnerCapability?,
    webSocketFactory: any ClipLiveShareWebSocketFactory
  ) {
    self.label = label
    self.room = room
    self.candidateKnock = candidateKnock
    self.target = target
    self.capabilities = capabilities
    self.ownerCapability = ownerCapability
    transport = ClipLiveShareServerRoomV4Transport(
      webSocketFactory: webSocketFactory,
      reconnectPolicy: .boundedExponential
    )
  }

  func start() async throws {
    let stream = await transport.events()
    listener = Task { [weak self] in
      for await event in stream {
        await self?.consume(event)
      }
    }
    if let ownerCapability {
      try await transport.connect(
        to: target,
        capabilities: capabilities,
        authentication: .creator(ownerCapability: ownerCapability)
      )
    } else {
      try await transport.connect(
        to: target,
        capabilities: capabilities,
        authentication: .freshCandidate
      )
    }
  }

  func snapshot() -> ClipLiveShareServerRoomV4ClientRoomSnapshot { room.snapshot }
  func lastWireRoster() -> ClipLiveShareServerRoomV4RosterSnapshot? {
    wireRosters.last
  }
  func failure() -> String? { failureDescription }
  func localHandle() -> ClipLiveShareServerRoomV4MemberHandle? {
    room.localHandle
  }
  func hasOpened(
    from: ClipLiveShareServerRoomV4MemberHandle,
    payload: ClipLiveShareServerRoomV4PairSignalPayload
  ) -> Bool {
    openedSignals.contains(.init(from: from, payload: payload))
  }
  func roomEnded(reason: String) -> Bool { roomEndedReasons.contains(reason) }
  func connectionSummary() -> ParticipantConnectionSummary {
    .init(
      connected: transportEvents.filter {
        if case .connected = $0 { true } else { false }
      }.count,
      reconnecting: transportEvents.filter {
        if case .reconnecting = $0 { true } else { false }
      }.count,
      closed: transportEvents.filter { $0 == .closed }.count
    )
  }

  func discardSealedSignal(
    to remote: ClipLiveShareServerRoomV4MemberHandle,
    payload: ClipLiveShareServerRoomV4PairSignalPayload
  ) throws -> UInt64 {
    try room.sealPairSignal(to: remote, payload: payload).sequence
  }

  func sendSignal(
    to remote: ClipLiveShareServerRoomV4MemberHandle,
    payload: ClipLiveShareServerRoomV4PairSignalPayload
  ) async throws -> UInt64 {
    let envelope = try room.sealPairSignal(to: remote, payload: payload)
    try await transport.sendPairSignal(envelope)
    return envelope.sequence
  }

  func leave() async { await transport.leave() }

  func stopListener() {
    listener?.cancel()
    listener = nil
  }

  private func consume(_ event: ClipLiveShareServerRoomV4TransportEvent) async {
    transportEvents.append(event)
    guard case .message(let message) = event else {
      if case .failed(let error) = event {
        failureDescription = "\(label): transport failed: \(error.localizedDescription)"
      }
      return
    }
    do {
      switch message {
      case .candidateOpened:
        guard let candidateKnock else {
          throw AcceptanceFailure("\(label): creator received candidate-opened")
        }
        try await transport.sendJoinKnock(sequence: 1, payload: candidateKnock)

      case .joinKnock(let candidateHandle, _, let payload):
        guard let candidateHandle else {
          throw AcceptanceFailure("\(label): forwarded join knock lacked a handle")
        }
        let decision = try room.consumeForwardedJoinKnock(
          candidateHandle: candidateHandle,
          payload: payload
        )
        guard case .admit(let command) = decision else {
          throw AcceptanceFailure("\(label): open admission unexpectedly waited")
        }
        try await transport.admitCandidate(
          command.candidateHandle,
          descriptor: command.descriptor
        )

      case .memberAdmitted(let handle, let reconnect, let roster):
        _ = try room.consumeMemberAdmitted(
          memberHandle: handle,
          reconnectCapability: reconnect,
          roster: roster
        )
        wireRosters.append(roster)

      case .rosterSnapshot(let roster):
        _ = try room.consumeRosterSnapshot(roster)
        wireRosters.append(roster)

      case .pairSignal(let envelope):
        guard let from = envelope.from else {
          throw AcceptanceFailure("\(label): routed pair signal lacked a sender")
        }
        openedSignals.append(.init(
          from: from,
          payload: try room.openPairSignal(envelope)
        ))

      case .roomEnded(let reason):
        roomEndedReasons.append(reason)

      case .protocolError(let code, let message, _):
        throw AcceptanceFailure("\(label): server protocol error \(code): \(message)")

      case .denyCandidate(_, let reason):
        throw AcceptanceFailure("\(label): admission denied: \(reason)")

      case .admitCandidate, .leaveRoom, .removeMember:
        throw AcceptanceFailure("\(label): received a client-only wire message")
      }
    } catch {
      failureDescription = "\(label): \(error)"
    }
  }
}

private actor ServerVisibilityAudit {
  private struct Record: Sendable {
    let label: String
    let bytes: Data
  }
  private var records: [Record] = []

  func record(_ request: URLRequest, label: String) {
    var text = "\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")\n"
    for (key, value) in request.allHTTPHeaderFields ?? [:] {
      text += "\(key): \(value)\n"
    }
    records.append(.init(label: "\(label)-request", bytes: Data(text.utf8)))
    if let body = request.httpBody {
      records.append(.init(label: "\(label)-body", bytes: body))
    }
  }

  func record(_ payload: ClipLiveShareWebSocketPayload, label: String) {
    switch payload {
    case .text(let value):
      records.append(.init(label: label, bytes: Data(value.utf8)))
    case .data(let value):
      records.append(.init(label: label, bytes: value))
    }
  }

  func count() -> Int { records.count }

  func exposedNeedles(_ needles: [String]) -> [String] {
    let nonempty = needles.filter { !$0.isEmpty }
    return nonempty.filter { needle in
      let bytes = Data(needle.utf8)
      return records.contains { $0.bytes.range(of: bytes) != nil }
    }
  }
}

private struct AuditedHTTPTransport: ClipLiveShareHTTPTransport {
  let base: any ClipLiveShareHTTPTransport
  let audit: ServerVisibilityAudit

  func execute(_ request: URLRequest) async throws -> ClipLiveShareHTTPResult {
    await audit.record(request, label: "http")
    return try await base.execute(request)
  }
}

private struct AuditedWebSocketFactory: ClipLiveShareWebSocketFactory {
  let base: any ClipLiveShareWebSocketFactory
  let audit: ServerVisibilityAudit

  func makeConnection(
    for request: URLRequest
  ) async throws -> any ClipLiveShareWebSocketConnection {
    await audit.record(request, label: "websocket")
    return AuditedWebSocketConnection(
      base: try await base.makeConnection(for: request),
      audit: audit
    )
  }
}

private struct AuditedWebSocketConnection: ClipLiveShareWebSocketConnection {
  let base: any ClipLiveShareWebSocketConnection
  let audit: ServerVisibilityAudit

  func resume() async throws { try await base.resume() }
  func send(_ payload: ClipLiveShareWebSocketPayload) async throws {
    await audit.record(payload, label: "websocket-send")
    try await base.send(payload)
  }
  func receive() async throws -> ClipLiveShareWebSocketPayload {
    try await base.receive()
  }
  func close() async { await base.close() }
}

@main
private enum ClipServerRoomV4AcceptanceMain {
  static func main() async {
    do {
      let report = try await run()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(report)
      print(String(decoding: data, as: UTF8.self))
    } catch {
      fputs("Clip server-room v4 acceptance failed: \(error)\n", stderr)
      exit(1)
    }
  }

  private static func run() async throws -> AcceptanceReport {
    let endpoint = try endpointArgument()
    let audit = ServerVisibilityAudit()
    let http = ClipLiveShareServerRoomV4HTTPClient(
      transport: AuditedHTTPTransport(
        base: URLSessionClipLiveShareHTTPTransport(),
        audit: audit
      )
    )
    let socketFactory = AuditedWebSocketFactory(
      base: URLSessionClipLiveShareWebSocketFactory(),
      audit: audit
    )
    let capabilities = try await http.discover(at: endpoint)
    guard capabilities.maximumRoomMembers == 4 else {
      throw AcceptanceFailure("server did not advertise a four-member v4 room")
    }

    let roomID = ClipLiveShareServerRoomV4RoomID.random()
    let target = try ClipLiveShareServerRoomV4Target(
      endpoint: endpoint,
      roomID: roomID
    )
    let owner = ClipLiveShareServerRoomV4OwnerCapability.random()
    let roomSecret = ClipLiveShareServerRoomV4RoomAgreementSecret.random()
    let admission = ClipLiveShareServerRoomV4AdmissionCapability.random()
    let sessionID = ClipLiveShareSessionID.random()
    let creatorHandle = ClipLiveShareServerRoomV4MemberHandle.random()
    let creatorMaterial = try ParticipantMaterial(index: 0)
    let creatorBootstrap = try ClipLiveShareServerRoomV4ClientRoom.makeCreator(
      serviceEndpoint: endpoint,
      roomID: roomID,
      memberHandle: creatorHandle,
      sessionID: sessionID,
      ownerCapability: owner,
      roomAgreementSecret: roomSecret,
      admissionCapability: admission,
      pairKeyIdentity: creatorMaterial.pairIdentity,
      localDescriptor: creatorMaterial.descriptor,
      signer: creatorMaterial.signer,
      admissionPolicy: .open()
    )
    let stableInviteURL = try creatorBootstrap.invite.url
    let stableInviteString = stableInviteURL.absoluteString
    _ = try await http.create(
      target: target,
      ownerCapability: owner,
      creatorHandle: creatorHandle,
      descriptor: creatorBootstrap.createRequest.descriptor,
      capabilities: capabilities
    )

    let creator = AcceptanceParticipant(
      label: "A",
      room: creatorBootstrap.room,
      candidateKnock: nil,
      target: target,
      capabilities: capabilities,
      ownerCapability: owner,
      webSocketFactory: socketFactory
    )
    var participants = [creator]
    var privateNeedles = creatorMaterial.privateNeedles
    privateNeedles += [
      "#\(ClipLiveShareServerRoomV4.inviteFragmentKey)=",
      admission.rawValue,
      roomSecret.rawValue,
      sessionID.rawValue,
    ]
    try await creator.start()
    try await waitForRoster(participants, count: 1, description: "creator roster")

    var rosterSizes: [Int] = []
    var pairCounts: [Int] = []
    var candidateMaterials: [ParticipantMaterial] = []
    for index in 1...3 {
      // Every candidate parses the same byte-stable invite URL. Merely joining
      // never rotates its admission capability or sealed client fragment.
      let parsedInvite = try ClipLiveShareServerRoomV4Invite(url: stableInviteURL)
      let material = try ParticipantMaterial(index: index)
      candidateMaterials.append(material)
      privateNeedles += material.privateNeedles
      let bootstrap = try ClipLiveShareServerRoomV4ClientRoom.makeCandidate(
        invite: parsedInvite,
        pairKeyIdentity: material.pairIdentity,
        localDescriptor: material.descriptor,
        signer: material.signer
      )
      let participant = AcceptanceParticipant(
        label: String(UnicodeScalar(65 + index)!),
        room: bootstrap.room,
        candidateKnock: bootstrap.joinKnock,
        target: target,
        capabilities: capabilities,
        ownerCapability: nil,
        webSocketFactory: socketFactory
      )
      participants.append(participant)
      try await participant.start()
      let expectedCount = index + 1
      try await waitForRoster(
        participants,
        count: expectedCount,
        description: "authoritative \(expectedCount)-member roster"
      )
      try await assertIdenticalWireRosters(participants, count: expectedCount)
      let unorderedPairs = try await assertCompleteMesh(
        participants,
        participantCount: expectedCount
      )
      rosterSizes.append(expectedCount)
      pairCounts.append(unorderedPairs)
      guard try creatorBootstrap.invite.url.absoluteString == stableInviteString else {
        throw AcceptanceFailure("invite changed after participant \(expectedCount) joined")
      }
      try await assertExistingSocketsStayedOpen(participants)
    }

    let handles = try await participantHandles(participants)
    var directedSignals = 0
    var acceptedGap: UInt64 = 0
    for senderIndex in participants.indices {
      for receiverIndex in participants.indices where senderIndex != receiverIndex {
        let sender = participants[senderIndex]
        let receiver = participants[receiverIndex]
        let receiverHandle = handles[receiverIndex]
        let senderHandle = handles[senderIndex]
        let sdp = "v=0\r\na=V4-PRIVATE-SDP-\(senderIndex)-TO-\(receiverIndex)-E29F\r\n"
        privateNeedles.append(sdp)
        let payload = ClipLiveShareServerRoomV4PairSignalPayload.offer(
          epoch: try .init(rawValue: 1),
          sdp: sdp
        )
        if senderIndex == 0, receiverIndex == 1 {
          let dropped = try await sender.discardSealedSignal(
            to: receiverHandle,
            payload: .renegotiationRequest(epoch: try .init(rawValue: 1))
          )
          guard dropped == 1 else {
            throw AcceptanceFailure("first intentionally dropped sequence was not 1")
          }
        }
        let sequence = try await sender.sendSignal(to: receiverHandle, payload: payload)
        if senderIndex == 0, receiverIndex == 1 { acceptedGap = sequence }
        try await waitUntil("directed encrypted signal \(senderIndex)->\(receiverIndex)") {
          try await throwParticipantFailures(participants)
          return await receiver.hasOpened(from: senderHandle, payload: payload)
        }
        directedSignals += 1
      }
    }
    guard directedSignals == 12, acceptedGap == 2 else {
      throw AcceptanceFailure(
        "directed pair evidence was \(directedSignals), gap sequence \(acceptedGap)"
      )
    }

    let departing = participants.removeLast()
    let departingMaterial = candidateMaterials.removeLast()
    await departing.leave()
    try await waitForRoster(
      participants,
      count: 3,
      description: "roster after noncreator leave"
    )
    try await assertIdenticalWireRosters(participants, count: 3)
    let remainingPairs = try await assertCompleteMesh(
      participants,
      participantCount: 3
    )
    try await assertExistingSocketsStayedOpen(participants)

    // The same canonical invite is reusable after a member leaves. Rejoining
    // keeps the persistent signing identity while using a fresh room-scoped
    // participant incarnation, pair key, candidate handle and member handle.
    let parsedRejoinInvite = try ClipLiveShareServerRoomV4Invite(
      url: stableInviteURL
    )
    let rejoiningMaterial = try departingMaterial.rejoining()
    let rejoiningBootstrap =
      try ClipLiveShareServerRoomV4ClientRoom.makeCandidate(
        invite: parsedRejoinInvite,
        pairKeyIdentity: rejoiningMaterial.pairIdentity,
        localDescriptor: rejoiningMaterial.descriptor,
        signer: rejoiningMaterial.signer
      )
    let rejoined = AcceptanceParticipant(
      label: "D-rejoined",
      room: rejoiningBootstrap.room,
      candidateKnock: rejoiningBootstrap.joinKnock,
      target: target,
      capabilities: capabilities,
      ownerCapability: nil,
      webSocketFactory: socketFactory
    )
    participants.append(rejoined)
    try await rejoined.start()
    try await waitForRoster(
      participants,
      count: 4,
      description: "same-invite roster after member rejoin"
    )
    try await assertIdenticalWireRosters(participants, count: 4)
    let rejoinedPairs = try await assertCompleteMesh(
      participants,
      participantCount: 4
    )
    try await assertExistingSocketsStayedOpen(participants)
    guard
      try creatorBootstrap.invite.url.absoluteString == stableInviteString,
      try parsedRejoinInvite.url.absoluteString == stableInviteString
    else {
      throw AcceptanceFailure("invite changed across leave and rejoin")
    }

    let rejoinedHandles = try await participantHandles(participants)
    var rejoinDirectedSignals = 0
    for existingIndex in 0..<3 {
      for (senderIndex, receiverIndex) in [
        (existingIndex, 3),
        (3, existingIndex),
      ] {
        let sender = participants[senderIndex]
        let receiver = participants[receiverIndex]
        let receiverHandle = rejoinedHandles[receiverIndex]
        let senderHandle = rejoinedHandles[senderIndex]
        let sdp = "v=0\r\na=V4-REJOIN-PRIVATE-SDP-\(senderIndex)-TO-\(receiverIndex)\r\n"
        privateNeedles.append(sdp)
        let payload = ClipLiveShareServerRoomV4PairSignalPayload.offer(
          epoch: try .init(rawValue: 1),
          sdp: sdp
        )
        _ = try await sender.sendSignal(
          to: receiverHandle,
          payload: payload
        )
        try await waitUntil(
          "rejoined encrypted signal \(senderIndex)->\(receiverIndex)"
        ) {
          try await throwParticipantFailures(participants)
          return await receiver.hasOpened(
            from: senderHandle,
            payload: payload
          )
        }
        rejoinDirectedSignals += 1
      }
    }

    let friendPresence = try await assertFriendPresence(
      endpoint: endpoint,
      http: http,
      invite: creatorBootstrap.invite,
      roomID: roomID,
      sessionID: sessionID,
      creator: creatorMaterial,
      participant: candidateMaterials[0]
    )
    privateNeedles += friendPresence.privateNeedles

    await creator.leave()
    let survivors = Array(participants.dropFirst())
    try await waitUntil("creator room-ended fanout") {
      try await throwParticipantFailures(survivors, allowRoomEndedClosure: true)
      for participant in survivors {
        if !(await participant.roomEnded(reason: "creator-left")) { return false }
      }
      return true
    }
    do {
      _ = try await http.status(target: target, capabilities: capabilities)
      throw AcceptanceFailure("room remained available after creator leave")
    } catch ClipLiveShareServerRoomV4TransportError.roomNotFound {
      // Expected.
    }

    let exposed = await audit.exposedNeedles(privateNeedles)
    guard exposed.isEmpty else {
      throw AcceptanceFailure(
        "server-visible transport exposed private values: \(exposed)"
      )
    }
    let reconnects = try await totalReconnects(participants)
    for participant in participants { await participant.stopListener() }
    await departing.stopListener()

    return .init(
      protocolVersion: ClipLiveShareServerRoomV4.version,
      participantCount: 4,
      stableInviteAcrossJoins: true,
      authoritativeRosterSizes: rosterSizes,
      unorderedPairCounts: pairCounts,
      directedEncryptedSignals: directedSignals,
      acceptedGappedSequence: acceptedGap,
      existingSocketReconnects: reconnects,
      memberLeaveRemainingParticipants: 3,
      memberLeaveRemainingPairs: remainingPairs,
      sameInviteRejoinParticipants: 4,
      sameInviteRejoinPairs: rejoinedPairs,
      sameInviteRejoinDirectedSignals: rejoinDirectedSignals,
      creatorLeaveRoomEndedRecipients: survivors.count,
      friendHandshakeCommitted: true,
      creatorFriendPresencePublished: true,
      friendPresenceReusableInvite: true,
      ordinaryParticipantPresenceAbsent: true,
      auditedServerVisibleRecords: await audit.count(),
      privateValuesExposed: exposed.count
    )
  }

  /// Exercises saved-friend discovery against the real Go service and real
  /// URLSession transport. A completed signed handshake establishes two
  /// directional mailboxes. Only the active creator publishes its canonical
  /// invite; an idle friend can fetch and verify that same invite repeatedly,
  /// while the ordinary participant's publication mailbox remains absent.
  private static func assertFriendPresence(
    endpoint: URL,
    http: ClipLiveShareServerRoomV4HTTPClient,
    invite: ClipLiveShareServerRoomV4Invite,
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    creator: ParticipantMaterial,
    participant: ParticipantMaterial
  ) async throws -> FriendPresenceAcceptanceResult {
    let presenceEndpoint = try ClipLiveShareRendezvousEndpoint(
      rootURL: endpoint
    )
    let creatorLocator = ClipLiveShareServerRoomV4FriendLocator.random()
    let participantLocator = ClipLiveShareServerRoomV4FriendLocator.random()
    let creatorProfile = try ClipLiveShareServerRoomV4FriendProfile(
      identity: creator.signer.publicKey,
      displayName: creator.descriptor.displayName,
      deviceName: creator.descriptor.deviceName,
      presenceServiceEndpoint: presenceEndpoint,
      locator: creatorLocator
    )
    let participantProfile = try ClipLiveShareServerRoomV4FriendProfile(
      identity: participant.signer.publicKey,
      displayName: participant.descriptor.displayName,
      deviceName: participant.descriptor.deviceName,
      presenceServiceEndpoint: presenceEndpoint,
      locator: participantLocator
    )
    let timestamp = try ClipLiveShareNativeTimestamp(date: Date())
    let request = try ClipLiveShareServerRoomV4FriendRequest(
      roomID: roomID,
      sessionID: sessionID,
      requesterParticipantID: creator.descriptor.participantID,
      accepterParticipantID: participant.descriptor.participantID,
      requester: creatorProfile,
      expectedAccepterFingerprint: participant.signer.publicKey.fingerprint,
      issuedAt: timestamp,
      expiresAt: try timestamp.adding(
        milliseconds: ClipLiveShareServerRoomV4Friends
          .maximumHandshakeLifetimeMilliseconds
      )
    )
    let signedRequest = try ClipLiveShareServerRoomV4SignedFriendMessage(
      signing: .request(request),
      with: creator.signer
    )
    let acceptance = try ClipLiveShareServerRoomV4FriendAcceptance(
      accepting: request,
      accepter: participantProfile,
      acceptedAt: timestamp
    )
    let signedAcceptance = try ClipLiveShareServerRoomV4SignedFriendMessage(
      signing: .acceptance(acceptance),
      with: participant.signer
    )
    let acknowledgement = try
      ClipLiveShareServerRoomV4FriendAcknowledgement(
        acknowledging: acceptance,
        request: request,
        acknowledgedAt: timestamp
      )
    let signedAcknowledgement = try
      ClipLiveShareServerRoomV4SignedFriendMessage(
        signing: .acknowledgement(acknowledgement),
        with: creator.signer
      )
    let receipt = try ClipLiveShareServerRoomV4FriendCommitReceipt(
      committing: acknowledgement,
      committedAt: timestamp
    )
    let signedReceipt = try ClipLiveShareServerRoomV4SignedFriendMessage(
      signing: .commitReceipt(receipt),
      with: participant.signer
    )
    try signedRequest.verify()
    try signedAcceptance.verify()
    try signedAcknowledgement.verify()
    try signedReceipt.verify()
    try receipt.validate(
      request: request,
      acceptance: acceptance,
      acknowledgement: acknowledgement,
      at: timestamp
    )

    let encrypted = try ClipLiveShareServerRoomV4FriendPresenceCrypto.seal(
      invite: invite,
      revision: UInt64(timestamp.millisecondsSince1970),
      publisherSigner: creator.signer,
      recipientIdentity: participant.signer.publicKey,
      locator: creatorLocator,
      issuedAt: timestamp,
      expiresAt: try timestamp.adding(milliseconds: 45_000)
    )
    try await http.publishFriendPresence(
      at: endpoint,
      encryptedPresence: encrypted
    )
    let fetchedFirst = try await http.friendPresence(
      at: endpoint,
      routingID: creatorLocator.routingID
    )
    let fetchedSecond = try await http.friendPresence(
      at: endpoint,
      routingID: creatorLocator.routingID
    )
    guard let fetchedFirst, let fetchedSecond else {
      throw AcceptanceFailure("creator friend presence was not published")
    }
    let openedFirst = try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
      fetchedFirst,
      locator: creatorLocator,
      expectedPublisherIdentity: creator.signer.publicKey,
      recipientIdentity: participant.signer.publicKey,
      at: timestamp
    )
    let openedSecond = try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
      fetchedSecond,
      locator: creatorLocator,
      expectedPublisherIdentity: creator.signer.publicKey,
      recipientIdentity: participant.signer.publicKey,
      at: timestamp
    )
    guard
      try openedFirst.url == invite.url,
      try openedSecond.url == invite.url
    else {
      throw AcceptanceFailure(
        "friend presence did not preserve the creator's canonical invite"
      )
    }
    guard try await http.friendPresence(
      at: endpoint,
      routingID: participantLocator.routingID
    ) == nil else {
      throw AcceptanceFailure(
        "ordinary participant unexpectedly published friend presence"
      )
    }
    return .init(privateNeedles: [
      try invite.url.absoluteString,
      creatorLocator.presenceSecret.rawValue,
      participantLocator.presenceSecret.rawValue,
    ])
  }

  private static func endpointArgument() throws -> URL {
    let arguments = CommandLine.arguments
    guard
      let index = arguments.firstIndex(of: "--endpoint"),
      arguments.indices.contains(index + 1),
      let endpoint = URL(string: arguments[index + 1])
    else {
      throw AcceptanceFailure("usage: ClipServerRoomV4Acceptance --endpoint http://127.0.0.1:PORT")
    }
    return endpoint
  }

  private static func waitForRoster(
    _ participants: [AcceptanceParticipant],
    count: Int,
    description: String
  ) async throws {
    try await waitUntil(description) {
      try await throwParticipantFailures(participants)
      for participant in participants {
        let snapshot = await participant.snapshot()
        if snapshot.members.count != count || snapshot.pairs.count != count - 1 {
          return false
        }
      }
      return true
    }
  }

  private static func assertIdenticalWireRosters(
    _ participants: [AcceptanceParticipant],
    count: Int
  ) async throws {
    var values: [ClipLiveShareServerRoomV4RosterSnapshot] = []
    for participant in participants {
      guard let roster = await participant.lastWireRoster() else {
        throw AcceptanceFailure("participant lacked the \(count)-member wire roster")
      }
      values.append(roster)
    }
    guard
      values.allSatisfy({ $0 == values[0] }),
      values[0].members.count == count
    else {
      throw AcceptanceFailure("participants disagreed on the \(count)-member roster")
    }
  }

  private static func assertCompleteMesh(
    _ participants: [AcceptanceParticipant],
    participantCount: Int
  ) async throws -> Int {
    var pairIDs = Set<ClipLiveShareServerRoomV4PairID>()
    var directedPairCount = 0
    for participant in participants {
      let snapshot = await participant.snapshot()
      guard snapshot.pairs.count == participantCount - 1 else {
        throw AcceptanceFailure(
          "participant has \(snapshot.pairs.count) pairs; expected \(participantCount - 1)"
        )
      }
      directedPairCount += snapshot.pairs.count
      pairIDs.formUnion(snapshot.pairs.map(\.pairID))
    }
    let expected = participantCount * (participantCount - 1) / 2
    guard directedPairCount == expected * 2, pairIDs.count == expected else {
      throw AcceptanceFailure(
        "mesh has \(pairIDs.count) unordered and \(directedPairCount) directed pairs; expected \(expected) and \(expected * 2)"
      )
    }
    return expected
  }

  private static func participantHandles(
    _ participants: [AcceptanceParticipant]
  ) async throws -> [ClipLiveShareServerRoomV4MemberHandle] {
    var handles: [ClipLiveShareServerRoomV4MemberHandle] = []
    for participant in participants {
      guard let handle = await participant.localHandle() else {
        throw AcceptanceFailure("admitted participant lacked a handle")
      }
      handles.append(handle)
    }
    return handles
  }

  private static func assertExistingSocketsStayedOpen(
    _ participants: [AcceptanceParticipant]
  ) async throws {
    for participant in participants {
      let summary = await participant.connectionSummary()
      guard summary.connected == 1, summary.reconnecting == 0, summary.closed == 0 else {
        throw AcceptanceFailure(
          "participant socket changed during admission: \(summary)"
        )
      }
    }
  }

  private static func totalReconnects(
    _ participants: [AcceptanceParticipant]
  ) async throws -> Int {
    var total = 0
    for participant in participants {
      total += await participant.connectionSummary().reconnecting
    }
    return total
  }

  private static func throwParticipantFailures(
    _ participants: [AcceptanceParticipant],
    allowRoomEndedClosure: Bool = false
  ) async throws {
    for participant in participants {
      guard let failure = await participant.failure() else { continue }
      if allowRoomEndedClosure, failure.contains("room-ended") { continue }
      throw AcceptanceFailure(failure)
    }
  }

  private static func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    condition: @escaping () async throws -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw AcceptanceFailure("timed out waiting for \(description)")
  }
}
