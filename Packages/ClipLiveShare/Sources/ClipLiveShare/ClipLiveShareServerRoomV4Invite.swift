import CryptoKit
import Foundation

/// Stable invitation for one server-coordinated room.
///
/// The short room code in the HTTP path is presentation-only. The opaque
/// 256-bit API room ID and every private room value live in the encrypted URL
/// fragment, which browsers, proxies, and the room service do not receive.
/// Both native Clip and a future web viewer can therefore consume the same
/// canonical `ROOMCODE#v=4&key=...&join=...` invitation.
public struct ClipLiveShareServerRoomV4Invite: Equatable, Hashable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let serviceEndpoint: URL
  public let roomCode: ClipLiveShareServerRoomV4RoomCode
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let creatorIdentity: ClipLiveShareIdentityPublicKey
  public let roomAgreementSecret: ClipLiveShareServerRoomV4RoomAgreementSecret
  public let admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability

  private let sealedClientPayload: Data

  public init(
    serviceEndpoint: URL,
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    creatorIdentity: ClipLiveShareIdentityPublicKey,
    roomAgreementSecret: ClipLiveShareServerRoomV4RoomAgreementSecret,
    admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability,
    roomCode: ClipLiveShareServerRoomV4RoomCode = .random()
  ) throws {
    try self.init(
      serviceEndpoint: serviceEndpoint,
      roomCode: roomCode,
      roomID: roomID,
      sessionID: sessionID,
      creatorIdentity: creatorIdentity,
      roomAgreementSecret: roomAgreementSecret,
      admissionCapability: admissionCapability,
      nonce: Data(AES.GCM.Nonce())
    )
  }

  init(
    serviceEndpoint: URL,
    roomCode: ClipLiveShareServerRoomV4RoomCode = .random(),
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    creatorIdentity: ClipLiveShareIdentityPublicKey,
    roomAgreementSecret: ClipLiveShareServerRoomV4RoomAgreementSecret,
    admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability,
    nonce: Data
  ) throws {
    self.serviceEndpoint = try Self.validateServiceEndpoint(serviceEndpoint)
    self.roomCode = roomCode
    self.roomID = roomID
    self.sessionID = sessionID
    self.creatorIdentity = creatorIdentity
    self.roomAgreementSecret = roomAgreementSecret
    self.admissionCapability = admissionCapability
    sealedClientPayload = try Self.sealPayload(
      ClientPayload(
        version: ClipLiveShareServerRoomV4.version,
        roomID: roomID,
        sessionID: sessionID,
        creatorIdentity: creatorIdentity,
        roomAgreementSecret: roomAgreementSecret,
        admissionCapability: admissionCapability
      ),
      roomCode: roomCode,
      admissionCapability: admissionCapability,
      nonce: nonce
    )
  }

  public init(url: URL) throws {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.query == nil,
      let fragment = components.percentEncodedFragment
    else {
      throw ClipLiveShareServerRoomV4Error.invalidInvite
    }
    let fields = fragment.split(separator: "&", omittingEmptySubsequences: false)
    let versionField =
      "\(ClipLiveShareServerRoomV4.inviteFragmentKey)="
      + "\(ClipLiveShareServerRoomV4.version)"
    guard
      fields.count == 3,
      fields[0] == Substring(versionField)
    else {
      throw ClipLiveShareServerRoomV4Error.invalidInvite
    }
    let payloadPrefix = ClipLiveShareServerRoomV4.invitePayloadFragmentKey + "="
    let admissionPrefix = ClipLiveShareServerRoomV4.inviteAdmissionFragmentKey + "="
    guard
      fields[1].hasPrefix(payloadPrefix),
      fields[2].hasPrefix(admissionPrefix)
    else {
      throw ClipLiveShareServerRoomV4Error.invalidInvite
    }
    let encodedPayload = String(fields[1].dropFirst(payloadPrefix.utf8.count))
    let encodedAdmission = String(fields[2].dropFirst(admissionPrefix.utf8.count))
    let admissionCapability = try ClipLiveShareServerRoomV4AdmissionCapability(
      rawValue: encodedAdmission
    )
    guard
      let sealedClientPayload = ClipLiveShareBase64URL.decode(encodedPayload),
      sealedClientPayload.count > ClipLiveShareServerRoomV4.nonceByteCount
        + ClipLiveShareServerRoomV4.authenticationTagByteCount,
      sealedClientPayload.count <= 8 * 1_024
    else {
      throw ClipLiveShareServerRoomV4Error.invalidInvite
    }

    let pathComponents = components.percentEncodedPath.split(separator: "/")
    guard
      pathComponents.count == 1,
      components.percentEncodedPath == "/\(pathComponents[0])"
    else {
      throw ClipLiveShareServerRoomV4Error.invalidInvite
    }
    let roomCode = try ClipLiveShareServerRoomV4RoomCode(
      rawValue: String(pathComponents[0])
    )
    let payload = try Self.openPayload(
      sealedClientPayload,
      roomCode: roomCode,
      admissionCapability: admissionCapability
    )
    guard
      payload.version == ClipLiveShareServerRoomV4.version,
      payload.admissionCapability == admissionCapability
    else {
      throw ClipLiveShareServerRoomV4Error.invalidInvite
    }

    var endpointComponents = components
    endpointComponents.path = ""
    endpointComponents.fragment = nil
    guard let serviceEndpoint = endpointComponents.url else {
      throw ClipLiveShareServerRoomV4Error.invalidEndpoint
    }
    self.serviceEndpoint = try Self.validateServiceEndpoint(serviceEndpoint)
    self.roomCode = roomCode
    roomID = payload.roomID
    sessionID = payload.sessionID
    creatorIdentity = payload.creatorIdentity
    roomAgreementSecret = payload.roomAgreementSecret
    self.admissionCapability = admissionCapability
    self.sealedClientPayload = sealedClientPayload
  }

  /// The byte-stable URL. Merely copying an invite, admitting participants,
  /// applying rosters, or reconnecting never reseals or rotates it.
  public var url: URL {
    get throws {
      var components = try Self.roomURLComponents(
        serviceEndpoint: serviceEndpoint,
        roomCode: roomCode
      )
      components.percentEncodedFragment =
        "\(ClipLiveShareServerRoomV4.inviteFragmentKey)=\(ClipLiveShareServerRoomV4.version)"
        + "&\(ClipLiveShareServerRoomV4.invitePayloadFragmentKey)="
        + ClipLiveShareBase64URL.encode(sealedClientPayload)
        + "&\(ClipLiveShareServerRoomV4.inviteAdmissionFragmentKey)="
        + admissionCapability.rawValue
      guard let result = components.url else {
        throw ClipLiveShareServerRoomV4Error.invalidInvite
      }
      return result
    }
  }

  /// The only protocol operation that changes an invite URL. The room path,
  /// room agreement, session binding, and admitted roster remain unchanged.
  public func rotatingAdmissionCapability(
    to replacement: ClipLiveShareServerRoomV4AdmissionCapability = .random()
  ) throws -> Self {
    try Self(
      serviceEndpoint: serviceEndpoint,
      roomID: roomID,
      sessionID: sessionID,
      creatorIdentity: creatorIdentity,
      roomAgreementSecret: roomAgreementSecret,
      admissionCapability: replacement,
      roomCode: roomCode
    )
  }

  public var serviceRoomURL: URL {
    get throws {
      var components = try Self.roomURLComponents(
        serviceEndpoint: serviceEndpoint,
        roomCode: roomCode
      )
      components.fragment = nil
      guard let result = components.url else {
        throw ClipLiveShareServerRoomV4Error.invalidInvite
      }
      return result
    }
  }

  public var description: String {
    "ClipLiveShareServerRoomV4Invite(serviceEndpoint: \(serviceEndpoint), "
      + "roomCode: \(roomCode), identifiers-and-secrets: <redacted>)"
  }
  public var debugDescription: String { description }

  private struct ClientPayload: Codable, Equatable {
    let version: Int
    let roomID: ClipLiveShareServerRoomV4RoomID
    let sessionID: ClipLiveShareSessionID
    let creatorIdentity: ClipLiveShareIdentityPublicKey
    let roomAgreementSecret: ClipLiveShareServerRoomV4RoomAgreementSecret
    let admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability

    enum CodingKeys: String, CodingKey {
      case version
      case roomID = "roomId"
      case sessionID = "sessionId"
      case creatorIdentity
      case roomAgreementSecret
      case admissionCapability
    }
  }

  private static func sealPayload(
    _ payload: ClientPayload,
    roomCode: ClipLiveShareServerRoomV4RoomCode,
    admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability,
    nonce: Data
  ) throws -> Data {
    guard nonce.count == ClipLiveShareServerRoomV4.nonceByteCount else {
      throw ClipLiveShareProtocolError.invalidNonceLength(nonce.count)
    }
    let plaintext = try serverRoomV4StrictEncode(
      payload,
      maximumBytes: 4 * 1_024
    )
    let sealed = try AES.GCM.seal(
      plaintext,
      using: inviteEncryptionKey(admissionCapability),
      nonce: try AES.GCM.Nonce(data: nonce),
      authenticating: inviteAuthenticatedData(roomCode: roomCode)
    )
    var result = nonce
    result.append(sealed.ciphertext)
    result.append(sealed.tag)
    return result
  }

  private static func openPayload(
    _ sealedPayload: Data,
    roomCode: ClipLiveShareServerRoomV4RoomCode,
    admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability
  ) throws -> ClientPayload {
    let nonce = sealedPayload.prefix(ClipLiveShareServerRoomV4.nonceByteCount)
    let body = sealedPayload.dropFirst(ClipLiveShareServerRoomV4.nonceByteCount)
    guard body.count > ClipLiveShareServerRoomV4.authenticationTagByteCount else {
      throw ClipLiveShareServerRoomV4Error.invalidInvite
    }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce),
        ciphertext: body.dropLast(ClipLiveShareServerRoomV4.authenticationTagByteCount),
        tag: body.suffix(ClipLiveShareServerRoomV4.authenticationTagByteCount)
      )
      let plaintext = try AES.GCM.open(
        box,
        using: inviteEncryptionKey(admissionCapability),
        authenticating: inviteAuthenticatedData(roomCode: roomCode)
      )
      try serverRoomV4RequireExactKeys(
        plaintext,
        expected: [
          "version", "roomId", "sessionId", "creatorIdentity",
          "roomAgreementSecret", "admissionCapability",
        ]
      )
      return try serverRoomV4StrictDecode(
        ClientPayload.self,
        from: plaintext,
        maximumBytes: 4 * 1_024
      )
    } catch let error as ClipLiveShareServerRoomV4Error {
      throw error
    } catch {
      throw ClipLiveShareServerRoomV4Error.invalidInvite
    }
  }

  private static func inviteEncryptionKey(
    _ capability: ClipLiveShareServerRoomV4AdmissionCapability
  ) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: capability.keyMaterial),
      salt: Data("clip-live-share-server-room-v4/invite/salt".utf8),
      info: Data("clip-live-share-server-room-v4/invite/payload".utf8),
      outputByteCount: 32
    )
  }

  private static func inviteAuthenticatedData(
    roomCode: ClipLiveShareServerRoomV4RoomCode
  ) -> Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/invite"
    )
    encoder.append("/" + roomCode.rawValue)
    return encoder.data
  }

  private static func roomURLComponents(
    serviceEndpoint: URL,
    roomCode: ClipLiveShareServerRoomV4RoomCode
  ) throws -> URLComponents {
    guard
      var components = URLComponents(
        url: serviceEndpoint,
        resolvingAgainstBaseURL: false
      )
    else {
      throw ClipLiveShareServerRoomV4Error.invalidEndpoint
    }
    components.percentEncodedPath = "/\(roomCode.rawValue)"
    components.query = nil
    components.fragment = nil
    return components
  }

  private static func validateServiceEndpoint(_ endpoint: URL) throws -> URL {
    guard
      var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      components.host != nil,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else {
      throw ClipLiveShareServerRoomV4Error.invalidEndpoint
    }
    components.scheme = scheme
    components.percentEncodedPath = ""
    guard let normalized = components.url else {
      throw ClipLiveShareServerRoomV4Error.invalidEndpoint
    }
    return normalized
  }
}

/// Small owner-side state object that makes explicit-only invite rotation an
/// API invariant. No roster or admission API is accepted here.
public struct ClipLiveShareServerRoomV4InviteIssuer: Sendable {
  public private(set) var currentInvite: ClipLiveShareServerRoomV4Invite

  public init(currentInvite: ClipLiveShareServerRoomV4Invite) {
    self.currentInvite = currentInvite
  }

  @discardableResult
  public mutating func rotateInvite(
    to replacement: ClipLiveShareServerRoomV4AdmissionCapability = .random()
  ) throws -> ClipLiveShareServerRoomV4Invite {
    currentInvite = try currentInvite.rotatingAdmissionCapability(to: replacement)
    return currentInvite
  }
}
