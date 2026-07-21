import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Native Friends journey acceptance")
struct NativeFriendsJourneyAcceptanceTests {
  @Test("pairing authenticates both identities and a fresh room rejects a removed friend")
  func pairingFreshRoomAndRemoval() throws {
    let endpoint = ClipLiveShareServerEndpoint.localDevelopment
    let rendezvousID = try ClipLiveShareRendezvousID(
      bytes: Data(repeating: 0x31, count: ClipLiveShareNativeV2.rendezvousIDByteCount)
    )
    let hostSigner = ClipLiveShareSoftwareIdentitySigner()
    let viewerSigner = ClipLiveShareSoftwareIdentitySigner()
    let firstRoomIdentity = ClipLiveShareRoomIdentity()
    let firstRoom = try ClipLiveShareRoomName(rawValue: "NATIVE-PAIR-101")
    let firstSession = try ClipLiveShareSessionID(rawValue: "native-pairing-session-one")
    let firstRoute = try ClipLiveShareRouteID(
      bytes: Data(repeating: 0x41, count: ClipLiveShareV1.routeIDByteCount)
    )
    let now = try ClipLiveShareNativeTimestamp(millisecondsSince1970: 1_900_000_000_000)
    let firstDescriptor = try signedDescriptor(
      endpoint: endpoint,
      rendezvousID: rendezvousID,
      signer: hostSigner,
      roomIdentity: firstRoomIdentity,
      room: firstRoom,
      sessionID: firstSession,
      revision: 1,
      now: now
    )
    try firstDescriptor.verify(
      expectedIdentity: hostSigner.publicKey,
      expectedContext: firstDescriptor.descriptor.rendezvousContext,
      at: now
    )

    let viewerEphemeral = ClipLiveShareViewerIdentity()
    var hostChannel = try ClipLiveShareEncryptedChannel(
      host: firstRoomIdentity,
      viewerPublicKey: viewerEphemeral.publicKey,
      room: firstRoom,
      routeID: firstRoute
    )
    var viewerChannel = try ClipLiveShareEncryptedChannel(
      viewer: viewerEphemeral,
      roomPublicKey: firstRoomIdentity.publicKey,
      room: firstRoom,
      routeID: firstRoute
    )
    let challenge = try ClipLiveShareNativeViewerChallenge(
      sessionDescriptorDigest: firstDescriptor.descriptor.digest,
      sessionID: firstSession,
      routeID: firstRoute,
      viewerEphemeralPublicKey: viewerEphemeral.publicKey,
      challenge: Data(repeating: 0xA5, count: ClipLiveShareNativeV2.challengeByteCount),
      issuedAt: now,
      expiresAt: now.adding(milliseconds: 60_000),
      stateRevision: firstDescriptor.descriptor.stateRevision
    )
    let challengeEnvelope = try hostChannel.sealOpaquePayload(
      ClipLiveShareNativeV2MessageCodec.encode(challenge)
    )
    let receivedChallenge = try ClipLiveShareNativeV2MessageCodec.decode(
      ClipLiveShareNativeViewerChallenge.self,
      from: viewerChannel.openOpaquePayload(challengeEnvelope)
    )
    #expect(receivedChallenge == challenge)

    let proof = try ClipLiveShareSignedNativeViewerProof(
      signing: receivedChallenge,
      with: viewerSigner
    )
    let rawProofEnvelope = try viewerChannel.sealOpaquePayload(
      ClipLiveShareNativeV2MessageCodec.encode(proof)
    )
    let proofEnvelope = try routed(rawProofEnvelope, routeID: firstRoute)
    let receivedProof = try ClipLiveShareNativeV2MessageCodec.decode(
      ClipLiveShareSignedNativeViewerProof.self,
      from: hostChannel.openOpaquePayload(proofEnvelope)
    )
    try receivedProof.verify(
      expectedChallenge: challenge,
      expectedIdentity: viewerSigner.publicKey,
      at: now
    )

    var trustedIdentities: Set<ClipLiveShareIdentityPublicKey> = [viewerSigner.publicKey]
    let hostExplicitlyApproved = true
    #expect(hostExplicitlyApproved && trustedIdentities.contains(receivedProof.viewerIdentity))
    let allowedEnvelope = try hostChannel.seal(
      .authResult(try .init(sessionID: firstSession, allowed: true))
    )
    guard case .authResult(let allowed) = try viewerChannel.open(allowedEnvelope) else {
      Issue.record("Expected an encrypted admission result")
      return
    }
    #expect(allowed.allowed)

    let viewerRendezvousID = try ClipLiveShareRendezvousID(
      bytes: Data(repeating: 0x52, count: ClipLiveShareNativeV2.rendezvousIDByteCount)
    )
    let request = try ClipLiveShareNativeFriendRequest(
      requestID: .random(),
      sessionID: firstSession,
      sessionDescriptorDigest: firstDescriptor.descriptor.digest,
      requestedHostFingerprint: hostSigner.publicKey.fingerprint,
      requesterIdentity: viewerSigner.publicKey,
      requesterEndpoint: endpoint,
      requesterRendezvousID: viewerRendezvousID,
      requesterDeviceName: "Viewer Mac",
      issuedAt: now,
      expiresAt: now.adding(milliseconds: 60_000)
    )
    let signedRequest = try ClipLiveShareSignedNativeFriendMessage(
      signing: .request(request),
      with: viewerSigner
    )
    try signedRequest.verifySignature(expectedIdentity: viewerSigner.publicKey)
    try request.validate(
      expectedSessionDescriptor: firstDescriptor.descriptor,
      expectedHostIdentity: hostSigner.publicKey,
      at: now
    )

    let acceptance = try ClipLiveShareNativeFriendAcceptance(
      requestID: request.requestID,
      sessionID: firstSession,
      requestDigest: request.digest,
      accepterIdentity: hostSigner.publicKey,
      requesterFingerprint: viewerSigner.publicKey.fingerprint,
      accepterDisplayName: "Host",
      accepterDeviceName: "Host Mac",
      accepterEndpoint: endpoint,
      rendezvousID: rendezvousID,
      acceptedAt: now,
      stateRevision: firstDescriptor.descriptor.stateRevision
    )
    let signedAcceptance = try ClipLiveShareSignedNativeFriendMessage(
      signing: .accepted(acceptance),
      with: hostSigner
    )
    try signedAcceptance.verifySignature(expectedIdentity: hostSigner.publicKey)
    try acceptance.validate(
      for: request,
      expectedSessionDescriptor: firstDescriptor.descriptor,
      at: now
    )

    let acknowledgement = try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
      acknowledging: acceptance,
      for: request,
      acknowledgedAt: now
    )
    let signedAcknowledgement = try ClipLiveShareSignedNativeFriendMessage(
      signing: .acceptanceAcknowledged(acknowledgement),
      with: viewerSigner
    )
    try signedAcknowledgement.verifySignature(expectedIdentity: viewerSigner.publicKey)
    try acknowledgement.validate(
      for: acceptance,
      request: request,
      expectedSessionDescriptor: firstDescriptor.descriptor,
      at: now
    )
    let receipt = try ClipLiveShareNativeFriendCommitReceipt(
      committing: acknowledgement,
      acknowledgementDigest: signedAcknowledgement.digest,
      acceptance: acceptance,
      request: request,
      committedAt: acknowledgement.acknowledgedAt
    )
    let signedReceipt = try ClipLiveShareSignedNativeFriendMessage(
      signing: .commitReceipt(receipt),
      with: hostSigner
    )
    try signedReceipt.verifySignature(expectedIdentity: hostSigner.publicKey)
    try receipt.validate(
      for: acknowledgement,
      acknowledgementDigest: signedAcknowledgement.digest,
      acceptance: acceptance,
      request: request,
      expectedSessionDescriptor: firstDescriptor.descriptor,
      at: now
    )
    #expect(request.requesterIdentity == viewerSigner.publicKey)
    #expect(acceptance.accepterIdentity == hostSigner.publicKey)
    #expect(request.requesterRendezvousID == viewerRendezvousID)
    #expect(acceptance.rendezvousID == rendezvousID)
    #expect(receipt.requesterIdentity == viewerSigner.publicKey)
    #expect(receipt.accepterIdentity == hostSigner.publicKey)

    _ = trustedIdentities.remove(viewerSigner.publicKey)
    let secondRoomIdentity = ClipLiveShareRoomIdentity()
    let secondRoom = try ClipLiveShareRoomName(rawValue: "NATIVE-PAIR-202")
    let secondSession = try ClipLiveShareSessionID(rawValue: "native-pairing-session-two")
    let secondDescriptor = try signedDescriptor(
      endpoint: endpoint,
      rendezvousID: rendezvousID,
      signer: hostSigner,
      roomIdentity: secondRoomIdentity,
      room: secondRoom,
      sessionID: secondSession,
      revision: 1,
      now: now
    )
    try secondDescriptor.verify(
      expectedIdentity: hostSigner.publicKey,
      expectedContext: secondDescriptor.descriptor.rendezvousContext,
      at: now
    )
    #expect(secondDescriptor.descriptor.room != firstDescriptor.descriptor.room)
    #expect(secondDescriptor.descriptor.roomPublicKey != firstDescriptor.descriptor.roomPublicKey)
    #expect(secondDescriptor.descriptor.sessionID != firstDescriptor.descriptor.sessionID)

    let secondRoute = try ClipLiveShareRouteID(
      bytes: Data(repeating: 0x62, count: ClipLiveShareV1.routeIDByteCount)
    )
    let secondViewerEphemeral = ClipLiveShareViewerIdentity()
    let secondChallenge = try ClipLiveShareNativeViewerChallenge(
      sessionDescriptorDigest: secondDescriptor.descriptor.digest,
      sessionID: secondSession,
      routeID: secondRoute,
      viewerEphemeralPublicKey: secondViewerEphemeral.publicKey,
      challenge: Data(repeating: 0xB6, count: ClipLiveShareNativeV2.challengeByteCount),
      issuedAt: now,
      expiresAt: now.adding(milliseconds: 60_000),
      stateRevision: secondDescriptor.descriptor.stateRevision
    )
    let secondProof = try ClipLiveShareSignedNativeViewerProof(
      signing: secondChallenge,
      with: viewerSigner
    )
    try secondProof.verify(
      expectedChallenge: secondChallenge,
      expectedIdentity: viewerSigner.publicKey,
      at: now
    )
    let admittedAfterRemoval =
      hostExplicitlyApproved
      && trustedIdentities.contains(secondProof.viewerIdentity)
    #expect(!admittedAfterRemoval)
    let denied = try ClipLiveShareAuthResult(
      sessionID: secondSession,
      allowed: false,
      reason: "viewer-not-trusted"
    )
    #expect(!denied.allowed)
    #expect(denied.reason == "viewer-not-trusted")
  }

  private func signedDescriptor(
    endpoint: ClipLiveShareServerEndpoint,
    rendezvousID: ClipLiveShareRendezvousID,
    signer: ClipLiveShareSoftwareIdentitySigner,
    roomIdentity: ClipLiveShareRoomIdentity,
    room: ClipLiveShareRoomName,
    sessionID: ClipLiveShareSessionID,
    revision: UInt64,
    now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareSignedNativeSessionDescriptor {
    let descriptor = try ClipLiveShareNativeSessionDescriptor(
      endpoint: endpoint,
      room: room,
      rendezvousID: rendezvousID,
      hostIdentity: signer.publicKey,
      roomPublicKey: roomIdentity.publicKey,
      sessionID: sessionID,
      issuedAt: now,
      expiresAt: now.adding(milliseconds: 240_000),
      stateRevision: try ClipLiveShareStateRevision(rawValue: revision)
    )
    return try ClipLiveShareSignedNativeSessionDescriptor(
      signing: descriptor,
      with: signer
    )
  }

  private func routed(
    _ envelope: ClipLiveShareRelayEnvelope,
    routeID: ClipLiveShareRouteID
  ) throws -> ClipLiveShareRelayEnvelope {
    try ClipLiveShareRelayEnvelope(
      routeID: routeID,
      sequence: envelope.sequence,
      nonce: envelope.nonce,
      ciphertext: envelope.ciphertext
    )
  }
}
