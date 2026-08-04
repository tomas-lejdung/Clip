import ClipLiveShare
import Foundation

public enum ClipLiveShareServerRoomV4TransportError: Error, Equatable,
  Sendable, LocalizedError
{
  case invalidEndpoint
  case invalidCapabilities
  case invalidResponse
  case responseTooLarge
  case rejected(statusCode: Int, code: String?)
  case roomConflict
  case roomNotFound
  case connectionAlreadyActive
  case connectionFailed
  case notConnected
  case invalidMessage
  case unsupportedBinaryMessage
  case messageTooLarge(maximumBytes: Int)
  case sendFailed
  case candidateDisconnectedBeforeAdmission
  case reconnectExhausted
  case operationSuperseded
  case eventBufferOverflow
  case friendPresenceRevisionConflict

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "The native room server endpoint is invalid."
    case .invalidCapabilities:
      "The server does not support Clip native room protocol v4."
    case .invalidResponse:
      "The native room server returned an invalid response."
    case .responseTooLarge:
      "The native room server response exceeded Clip's safety limit."
    case .rejected(let statusCode, let code):
      "The native room server rejected the request (HTTP \(statusCode)\(code.map { ": \($0)" } ?? ""))."
    case .roomConflict:
      "That native room identifier is already in use."
    case .roomNotFound:
      "The native room no longer exists."
    case .connectionAlreadyActive:
      "A native room transport is already active."
    case .connectionFailed:
      "Clip could not connect to the native room server."
    case .notConnected:
      "The native room transport is not connected."
    case .invalidMessage:
      "The native room server sent an invalid message."
    case .unsupportedBinaryMessage:
      "The native room server sent an unsupported binary message."
    case .messageTooLarge(let maximumBytes):
      "The native room message exceeds the \(maximumBytes)-byte limit."
    case .sendFailed:
      "Clip could not send the native room message."
    case .candidateDisconnectedBeforeAdmission:
      "The native room candidate disconnected before admission completed."
    case .reconnectExhausted:
      "Clip exhausted its bounded native room reconnect attempts."
    case .operationSuperseded:
      "A newer native room lifecycle operation replaced this one."
    case .eventBufferOverflow:
      "A native room event subscriber could not keep up."
    case .friendPresenceRevisionConflict:
      "A newer friend presence publication is already stored."
    }
  }
}

public struct ClipLiveShareServerRoomV4Target: Equatable, Sendable {
  public let endpoint: URL
  public let roomID: ClipLiveShareServerRoomV4RoomID

  public init(
    endpoint: URL,
    roomID: ClipLiveShareServerRoomV4RoomID
  ) throws {
    guard
      let endpoint =
        ClipLiveShareServerRoomV4ServiceEndpointPolicy
        .normalizedEndpoint(endpoint)
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidEndpoint
    }
    self.endpoint = endpoint
    self.roomID = roomID
  }
}

public struct ClipLiveShareServerRoomV4ICEServer: Equatable, Sendable {
  public let urls: [String]
  public let username: String?
  public let credential: String?

  public init(
    urls: [String],
    username: String? = nil,
    credential: String? = nil
  ) throws {
    guard
      (1...16).contains(urls.count),
      username?.utf8.count ?? 0 <= 1_024,
      credential?.utf8.count ?? 0 <= 4_096
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidCapabilities
    }
    for value in urls {
      guard
        !value.isEmpty,
        value.utf8.count <= 2_048,
        let components = URLComponents(string: value),
        let scheme = components.scheme?.lowercased(),
        ["stun", "stuns", "turn", "turns"].contains(scheme)
      else {
        throw ClipLiveShareServerRoomV4TransportError.invalidCapabilities
      }
    }
    self.urls = urls
    self.username = username
    self.credential = credential
  }

  public var webRTCConfiguration: WebRTCICEServerConfiguration {
    .init(urlStrings: urls, username: username, credential: credential)
  }
}

public struct ClipLiveShareServerRoomV4Capabilities: Equatable, Sendable {
  public let serverVersion: String
  public let roomPathTemplate: String
  public let roomWebSocketPathTemplate: String
  public let maximumMessageBytes: Int
  public let maximumDescriptorBytes: Int
  public let maximumOpaquePayloadBytes: Int
  public let maximumPendingCandidates: Int
  public let maximumRoomMembers: Int
  public let maximumRooms: Int
  public let iceServers: [ClipLiveShareServerRoomV4ICEServer]

  public var webRTCICEServers: [WebRTCICEServerConfiguration] {
    iceServers.map(\.webRTCConfiguration)
  }

  public init(
    serverVersion: String,
    roomPathTemplate: String = "/api/native/v4/rooms/{room}",
    roomWebSocketPathTemplate: String = "/api/native/v4/rooms/{room}/socket",
    maximumMessageBytes: Int = ClipLiveShareServerRoomV4.maximumWireMessageBytes,
    maximumDescriptorBytes: Int = ClipLiveShareServerRoomV4.maximumOpaqueDescriptorBytes,
    maximumOpaquePayloadBytes: Int = ClipLiveShareServerRoomV4.maximumPairSignalCiphertextBytes,
    maximumPendingCandidates: Int = 8,
    maximumRoomMembers: Int = ClipLiveShareServerRoomV4.maximumParticipants,
    maximumRooms: Int,
    iceServers: [ClipLiveShareServerRoomV4ICEServer]
  ) throws {
    guard
      !serverVersion.isEmpty,
      serverVersion.utf8.count <= 128,
      Self.validTemplate(roomPathTemplate, suffix: ""),
      Self.validTemplate(roomWebSocketPathTemplate, suffix: "/socket"),
      (1...ClipLiveShareServerRoomV4.maximumWireMessageBytes).contains(maximumMessageBytes),
      (1...ClipLiveShareServerRoomV4.maximumOpaqueDescriptorBytes).contains(maximumDescriptorBytes),
      (1...ClipLiveShareServerRoomV4.maximumPairSignalCiphertextBytes).contains(
        maximumOpaquePayloadBytes
      ),
      (1...64).contains(maximumPendingCandidates),
      maximumRoomMembers == ClipLiveShareServerRoomV4.maximumParticipants,
      maximumRooms > 0,
      maximumRooms <= 1_000_000,
      iceServers.count <= 32
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidCapabilities
    }
    self.serverVersion = serverVersion
    self.roomPathTemplate = roomPathTemplate
    self.roomWebSocketPathTemplate = roomWebSocketPathTemplate
    self.maximumMessageBytes = maximumMessageBytes
    self.maximumDescriptorBytes = maximumDescriptorBytes
    self.maximumOpaquePayloadBytes = maximumOpaquePayloadBytes
    self.maximumPendingCandidates = maximumPendingCandidates
    self.maximumRoomMembers = maximumRoomMembers
    self.maximumRooms = maximumRooms
    self.iceServers = iceServers
  }

  public func roomURL(for target: ClipLiveShareServerRoomV4Target) throws -> URL {
    try makeURL(template: roomPathTemplate, target: target, webSocket: false)
  }

  public func roomWebSocketURL(
    for target: ClipLiveShareServerRoomV4Target
  ) throws -> URL {
    try makeURL(template: roomWebSocketPathTemplate, target: target, webSocket: true)
  }

  private static func validTemplate(_ value: String, suffix: String) -> Bool {
    guard
      value.hasPrefix("/api/native/v4/rooms/"),
      value.hasSuffix("{room}\(suffix)"),
      value.components(separatedBy: "{room}").count == 2,
      !value.contains("?"),
      !value.contains("#")
    else { return false }
    return true
  }

  private func makeURL(
    template: String,
    target: ClipLiveShareServerRoomV4Target,
    webSocket: Bool
  ) throws -> URL {
    let path = template.replacingOccurrences(of: "{room}", with: target.roomID.rawValue)
    guard
      var components = URLComponents(url: target.endpoint, resolvingAgainstBaseURL: false)
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidEndpoint
    }
    components.path = path
    if webSocket {
      components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
    }
    guard let url = components.url else {
      throw ClipLiveShareServerRoomV4TransportError.invalidEndpoint
    }
    return url
  }
}

public enum ClipLiveShareServerRoomV4StatusState: String, Equatable, Sendable {
  case active
  case creatorGrace = "creator-grace"
}

public struct ClipLiveShareServerRoomV4Status: Equatable, Sendable {
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let state: ClipLiveShareServerRoomV4StatusState
  public let rosterRevision: UInt64
  public let memberCount: Int

  public init(
    roomID: ClipLiveShareServerRoomV4RoomID,
    state: ClipLiveShareServerRoomV4StatusState,
    rosterRevision: UInt64,
    memberCount: Int
  ) throws {
    guard
      rosterRevision > 0,
      (1...ClipLiveShareServerRoomV4.maximumParticipants).contains(memberCount)
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidResponse
    }
    self.roomID = roomID
    self.state = state
    self.rosterRevision = rosterRevision
    self.memberCount = memberCount
  }
}

public struct ClipLiveShareServerRoomV4RoomLease: Equatable, Sendable {
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let creatorHandle: ClipLiveShareServerRoomV4MemberHandle
  public let leaseDurationSeconds: Int64
}

public struct ClipLiveShareServerRoomV4HTTPClient: Sendable {
  private static let maximumHTTPResponseBytes = 65_536
  private let transport: any ClipLiveShareHTTPTransport

  public init(
    transport: any ClipLiveShareHTTPTransport = URLSessionClipLiveShareHTTPTransport()
  ) {
    self.transport = transport
  }

  public func discover(
    at endpoint: URL
  ) async throws -> ClipLiveShareServerRoomV4Capabilities {
    _ = try ClipLiveShareServerRoomV4Target(
      endpoint: endpoint,
      roomID: .random()
    )
    guard
      let url = URL(
        string: "/.well-known/clip-native-rendezvous",
        relativeTo: endpoint
      )?.absoluteURL
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidEndpoint
    }
    let result = try await execute(request(url: url, method: "GET"))
    guard result.statusCode == 200 else { throw try rejected(result) }
    let raw: CapabilitiesResponse = try strictDecode(
      result.data,
      exactKeys: [
        "protocol", "apiVersion", "messageVersion", "serverVersion",
        "roomPathTemplate", "roomWebSocketPathTemplate",
        "maximumMessageBytes", "maximumDescriptorBytes",
        "maximumOpaquePayloadBytes", "maximumPendingCandidates",
        "maximumRoomMembers", "maximumRooms", "iceServers",
      ]
    )
    try validateICEServerShape(result.data)
    guard
      raw.protocolIdentifier == ClipLiveShareServerRoomV4.protocolIdentifier,
      raw.apiVersion == ClipLiveShareServerRoomV4.version,
      raw.messageVersion == ClipLiveShareServerRoomV4.version
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidCapabilities
    }
    do {
      return try .init(
        serverVersion: raw.serverVersion,
        roomPathTemplate: raw.roomPathTemplate,
        roomWebSocketPathTemplate: raw.roomWebSocketPathTemplate,
        maximumMessageBytes: raw.maximumMessageBytes,
        maximumDescriptorBytes: raw.maximumDescriptorBytes,
        maximumOpaquePayloadBytes: raw.maximumOpaquePayloadBytes,
        maximumPendingCandidates: raw.maximumPendingCandidates,
        maximumRoomMembers: raw.maximumRoomMembers,
        maximumRooms: raw.maximumRooms,
        iceServers: raw.iceServers.map {
          try .init(urls: $0.urls, username: $0.username, credential: $0.credential)
        }
      )
    } catch {
      throw ClipLiveShareServerRoomV4TransportError.invalidCapabilities
    }
  }

  @discardableResult
  public func create(
    target: ClipLiveShareServerRoomV4Target,
    ownerCapability: ClipLiveShareServerRoomV4OwnerCapability,
    creatorHandle: ClipLiveShareServerRoomV4MemberHandle,
    descriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord,
    capabilities: ClipLiveShareServerRoomV4Capabilities
  ) async throws -> ClipLiveShareServerRoomV4RoomLease {
    guard descriptor.ciphertext.count <= capabilities.maximumDescriptorBytes else {
      throw ClipLiveShareServerRoomV4TransportError.messageTooLarge(
        maximumBytes: capabilities.maximumDescriptorBytes
      )
    }
    let url = try capabilities.roomURL(for: target)
    var request = request(url: url, method: "PUT")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      ClipLiveShareServerRoomV4CreateRequest(
        ownerToken: ownerCapability,
        creatorHandle: creatorHandle,
        descriptor: descriptor
      )
    )
    let result = try await execute(request)
    switch result.statusCode {
    case 200, 201: break
    case 409: throw ClipLiveShareServerRoomV4TransportError.roomConflict
    default: throw try rejected(result)
    }
    let response: ClipLiveShareServerRoomV4CreateResponse = try strictDecode(
      result.data,
      exactKeys: ["roomId", "creatorHandle", "leaseDurationSeconds"]
    )
    guard response.roomID == target.roomID, response.creatorHandle == creatorHandle else {
      throw ClipLiveShareServerRoomV4TransportError.invalidResponse
    }
    return .init(
      roomID: response.roomID,
      creatorHandle: response.creatorHandle,
      leaseDurationSeconds: response.leaseDurationSeconds
    )
  }

  public func status(
    target: ClipLiveShareServerRoomV4Target,
    capabilities: ClipLiveShareServerRoomV4Capabilities
  ) async throws -> ClipLiveShareServerRoomV4Status {
    let result = try await execute(
      request(url: try capabilities.roomURL(for: target), method: "GET")
    )
    if result.statusCode == 404 {
      throw ClipLiveShareServerRoomV4TransportError.roomNotFound
    }
    guard result.statusCode == 200 else { throw try rejected(result) }
    let raw: StatusResponse = try strictDecode(
      result.data,
      exactKeys: ["roomId", "state", "rosterRevision", "memberCount"]
    )
    guard
      raw.roomID == target.roomID,
      let state = ClipLiveShareServerRoomV4StatusState(rawValue: raw.state)
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidResponse
    }
    return try .init(
      roomID: raw.roomID,
      state: state,
      rosterRevision: raw.rosterRevision,
      memberCount: raw.memberCount
    )
  }

  public func delete(
    target: ClipLiveShareServerRoomV4Target,
    ownerCapability: ClipLiveShareServerRoomV4OwnerCapability,
    capabilities: ClipLiveShareServerRoomV4Capabilities
  ) async throws {
    var request = request(url: try capabilities.roomURL(for: target), method: "DELETE")
    request.setValue(
      "Bearer \(ownerCapability.rawValue)",
      forHTTPHeaderField: "Authorization"
    )
    let result = try await execute(request)
    guard result.statusCode == 204 || result.statusCode == 404 else {
      throw try rejected(result)
    }
  }

  /// Publishes one directional, per-friend encrypted mailbox. Callers must
  /// invoke this once per saved friend; sharing a locator across friends would
  /// make the publisher's friend graph correlatable by the service.
  public func publishFriendPresence(
    at endpoint: URL,
    encryptedPresence: ClipLiveShareServerRoomV4EncryptedFriendPresence
  ) async throws {
    let url = try friendPresenceURL(
      endpoint: endpoint,
      routingID: encryptedPresence.routingID
    )
    var request = request(url: url, method: "PUT")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    request.httpBody = try encoder.encode(
      ClipLiveShareServerRoomV4FriendPresenceRecord(
        encryptedPresence: encryptedPresence
      )
    )
    let result = try await execute(request)
    switch result.statusCode {
    case 201, 204:
      return
    case 409:
      throw ClipLiveShareServerRoomV4TransportError.friendPresenceRevisionConflict
    default:
      throw try rejected(result)
    }
  }

  /// Fetches only opaque bytes. Authenticity, recipient/publisher identity,
  /// expiry, and stale revision checks are performed by
  /// `ClipLiveShareServerRoomV4FriendPresenceCrypto.open`.
  public func friendPresence(
    at endpoint: URL,
    routingID: ClipLiveShareServerRoomV4FriendRoutingID
  ) async throws -> ClipLiveShareServerRoomV4EncryptedFriendPresence? {
    let url = try friendPresenceURL(endpoint: endpoint, routingID: routingID)
    let result = try await execute(request(url: url, method: "GET"))
    if result.statusCode == 404 { return nil }
    guard result.statusCode == 200 else { throw try rejected(result) }
    let record: ClipLiveShareServerRoomV4FriendPresenceRecord = try strictDecode(
      result.data,
      exactKeys: ["revision", "expiresAtMilliseconds", "payload"]
    )
    do {
      return try record.encryptedPresence(routingID: routingID)
    } catch {
      throw ClipLiveShareServerRoomV4TransportError.invalidResponse
    }
  }

  private func request(url: URL, method: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 5
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func friendPresenceURL(
    endpoint: URL,
    routingID: ClipLiveShareServerRoomV4FriendRoutingID
  ) throws -> URL {
    _ = try ClipLiveShareServerRoomV4Target(endpoint: endpoint, roomID: .random())
    guard
      var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidEndpoint
    }
    components.percentEncodedPath =
      "/api/native/v4/friends/\(routingID.rawValue)/presence"
    guard let url = components.url else {
      throw ClipLiveShareServerRoomV4TransportError.invalidEndpoint
    }
    return url
  }

  private func execute(_ request: URLRequest) async throws -> ClipLiveShareHTTPResult {
    let result: ClipLiveShareHTTPResult
    do {
      result = try await transport.execute(request)
    } catch let error as ClipLiveShareServerRoomV4TransportError {
      throw error
    } catch let error as ClipLiveShareNetworkError {
      if error == .responseTooLarge {
        throw ClipLiveShareServerRoomV4TransportError.responseTooLarge
      }
      throw ClipLiveShareServerRoomV4TransportError.connectionFailed
    } catch {
      throw ClipLiveShareServerRoomV4TransportError.connectionFailed
    }
    guard result.data.count <= Self.maximumHTTPResponseBytes else {
      throw ClipLiveShareServerRoomV4TransportError.responseTooLarge
    }
    return result
  }

  private func strictDecode<T: Decodable>(
    _ data: Data,
    exactKeys: Set<String>
  ) throws -> T {
    guard
      !data.isEmpty,
      data.count <= Self.maximumHTTPResponseBytes,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == exactKeys
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidResponse
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw ClipLiveShareServerRoomV4TransportError.invalidResponse
    }
  }

  private func validateICEServerShape(_ data: Data) throws {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let servers = root["iceServers"] as? [[String: Any]],
      servers.count <= 32
    else {
      throw ClipLiveShareServerRoomV4TransportError.invalidCapabilities
    }
    for server in servers {
      let keys = Set(server.keys)
      guard
        keys.contains("urls"),
        keys.isSubset(of: ["urls", "username", "credential"])
      else {
        throw ClipLiveShareServerRoomV4TransportError.invalidCapabilities
      }
    }
  }

  private func rejected(
    _ result: ClipLiveShareHTTPResult
  ) throws -> ClipLiveShareServerRoomV4TransportError {
    let code: String?
    if let object = try? JSONSerialization.jsonObject(with: result.data)
      as? [String: Any],
      Set(object.keys) == ["error"]
    {
      code = object["error"] as? String
    } else {
      code = nil
    }
    return .rejected(statusCode: result.statusCode, code: code)
  }
}

private struct CapabilitiesResponse: Decodable {
  let protocolIdentifier: String
  let apiVersion: Int
  let messageVersion: Int
  let serverVersion: String
  let roomPathTemplate: String
  let roomWebSocketPathTemplate: String
  let maximumMessageBytes: Int
  let maximumDescriptorBytes: Int
  let maximumOpaquePayloadBytes: Int
  let maximumPendingCandidates: Int
  let maximumRoomMembers: Int
  let maximumRooms: Int
  let iceServers: [ICEServerResponse]

  enum CodingKeys: String, CodingKey {
    case protocolIdentifier = "protocol"
    case apiVersion, messageVersion, serverVersion, roomPathTemplate
    case roomWebSocketPathTemplate, maximumMessageBytes, maximumDescriptorBytes
    case maximumOpaquePayloadBytes, maximumPendingCandidates, maximumRoomMembers
    case maximumRooms, iceServers
  }
}

private struct ICEServerResponse: Decodable {
  let urls: [String]
  let username: String?
  let credential: String?
}

private struct StatusResponse: Decodable {
  let roomID: ClipLiveShareServerRoomV4RoomID
  let state: String
  let rosterRevision: UInt64
  let memberCount: Int

  enum CodingKeys: String, CodingKey {
    case roomID = "roomId"
    case state, rosterRevision, memberCount
  }
}
