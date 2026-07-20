import Foundation

/// The JSON protocol currently implemented by GoPeep's signaling server and viewer.
///
/// GoPeep uses the same JSON envelope on two transports. SDP, ICE, room, and peer
/// lifecycle messages travel over the signaling WebSocket. Stream metadata and
/// presentation updates travel over the ordered `gopeep-control` WebRTC data channel.
public enum GoPeepV1Transport: String, Codable, Hashable, Sendable {
  case signalingWebSocket
  case controlDataChannel
}

/// A forward-compatible GoPeep message discriminator.
///
/// This is a string-backed value instead of a closed enum so a newer signaling server
/// can be decoded and reported without crashing an older Clip build.
public struct GoPeepV1MessageType: RawRepresentable, Codable, Equatable, Hashable,
  Sendable, ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.init(rawValue: value)
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let join: Self = "join"
  public static let joined: Self = "joined"
  public static let viewerJoined: Self = "viewer-joined"
  public static let viewerReoffer: Self = "viewer-reoffer"
  public static let offer: Self = "offer"
  public static let answer: Self = "answer"
  public static let renegotiateAnswer: Self = "renegotiate-answer"
  public static let ice: Self = "ice"
  public static let error: Self = "error"
  public static let passwordUpdate: Self = "password-update"
  public static let passwordRequired: Self = "password-required"
  public static let passwordInvalid: Self = "password-invalid"
  public static let sharerReady: Self = "sharer-ready"

  public static let streamsInfo: Self = "streams-info"
  public static let focusChange: Self = "focus-change"
  public static let streamAdded: Self = "stream-added"
  public static let streamRemoved: Self = "stream-removed"
  public static let streamActivated: Self = "stream-activated"
  public static let streamDeactivated: Self = "stream-deactivated"
  public static let sizeChange: Self = "size-change"
  public static let cursorPosition: Self = "cursor-position"
  public static let sharerStarted: Self = "sharer-started"
  public static let sharerStopped: Self = "sharer-stopped"

  public var intendedTransport: GoPeepV1Transport? {
    switch self {
    case .streamsInfo, .focusChange, .streamAdded, .streamRemoved,
      .streamActivated, .streamDeactivated, .sizeChange, .cursorPosition,
      .sharerStarted, .sharerStopped:
      .controlDataChannel
    case .join, .joined, .viewerJoined, .viewerReoffer, .offer, .answer,
      .renegotiateAnswer, .ice, .error, .passwordUpdate, .passwordRequired,
      .passwordInvalid, .sharerReady:
      .signalingWebSocket
    default:
      nil
    }
  }
}

public struct GoPeepV1Role: RawRepresentable, Codable, Equatable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.init(rawValue: value)
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let sharer: Self = "sharer"
  public static let viewer: Self = "viewer"
}

/// The exact `StreamInfo` object consumed by GoPeep's browser viewer.
public struct GoPeepV1StreamInfo: Codable, Equatable, Hashable, Sendable {
  public let trackID: String
  public let windowName: String
  public let appName: String
  public let isFocused: Bool
  public let width: Int
  public let height: Int

  public init(
    trackID: String,
    windowName: String,
    appName: String,
    isFocused: Bool,
    width: Int,
    height: Int
  ) {
    self.trackID = trackID
    self.windowName = windowName
    self.appName = appName
    self.isFocused = isFocused
    self.width = width
    self.height = height
  }

  private enum CodingKeys: String, CodingKey {
    case trackID = "trackId"
    case windowName
    case appName
    case isFocused
    case width
    case height
  }
}

/// GoPeep's v1 JSON envelope, including both signaling and data-channel fields.
///
/// Its custom encoder deliberately mirrors Go's `omitempty`: empty strings, empty
/// stream lists, zero dimensions and cursor values, and `false` are omitted.
public struct GoPeepV1Message: Codable, Equatable, Sendable {
  public var type: GoPeepV1MessageType
  public var room: String
  public var role: GoPeepV1Role?
  public var sdp: String
  public var candidate: String
  public var errorMessage: String
  public var peerID: String
  public var password: String
  public var secret: String
  public var trackID: String

  public var streams: [GoPeepV1StreamInfo]
  public var focusedTrack: String
  public var streamAdded: GoPeepV1StreamInfo?
  public var streamRemoved: String
  public var streamActivated: GoPeepV1StreamInfo?
  public var streamDeactivated: String

  public var width: Int
  public var height: Int
  public var cursorX: Double
  public var cursorY: Double
  public var cursorInView: Bool

  public init(
    type: GoPeepV1MessageType,
    room: String = "",
    role: GoPeepV1Role? = nil,
    sdp: String = "",
    candidate: String = "",
    errorMessage: String = "",
    peerID: String = "",
    password: String = "",
    secret: String = "",
    trackID: String = "",
    streams: [GoPeepV1StreamInfo] = [],
    focusedTrack: String = "",
    streamAdded: GoPeepV1StreamInfo? = nil,
    streamRemoved: String = "",
    streamActivated: GoPeepV1StreamInfo? = nil,
    streamDeactivated: String = "",
    width: Int = 0,
    height: Int = 0,
    cursorX: Double = 0,
    cursorY: Double = 0,
    cursorInView: Bool = false
  ) {
    self.type = type
    self.room = room
    self.role = role
    self.sdp = sdp
    self.candidate = candidate
    self.errorMessage = errorMessage
    self.peerID = peerID
    self.password = password
    self.secret = secret
    self.trackID = trackID
    self.streams = streams
    self.focusedTrack = focusedTrack
    self.streamAdded = streamAdded
    self.streamRemoved = streamRemoved
    self.streamActivated = streamActivated
    self.streamDeactivated = streamDeactivated
    self.width = width
    self.height = height
    self.cursorX = cursorX
    self.cursorY = cursorY
    self.cursorInView = cursorInView
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case room
    case role
    case sdp
    case candidate
    case errorMessage = "error"
    case peerID = "peerId"
    case password
    case secret
    case trackID = "trackId"
    case streams
    case focusedTrack
    case streamAdded
    case streamRemoved
    case streamActivated
    case streamDeactivated
    case width
    case height
    case cursorX
    case cursorY
    case cursorInView
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(GoPeepV1MessageType.self, forKey: .type)
    room = try container.decodeIfPresent(String.self, forKey: .room) ?? ""
    role = try container.decodeIfPresent(GoPeepV1Role.self, forKey: .role)
    sdp = try container.decodeIfPresent(String.self, forKey: .sdp) ?? ""
    candidate = try container.decodeIfPresent(String.self, forKey: .candidate) ?? ""
    errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
    peerID = try container.decodeIfPresent(String.self, forKey: .peerID) ?? ""
    password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
    secret = try container.decodeIfPresent(String.self, forKey: .secret) ?? ""
    trackID = try container.decodeIfPresent(String.self, forKey: .trackID) ?? ""
    streams = try container.decodeIfPresent([GoPeepV1StreamInfo].self, forKey: .streams) ?? []
    focusedTrack = try container.decodeIfPresent(String.self, forKey: .focusedTrack) ?? ""
    streamAdded = try container.decodeIfPresent(GoPeepV1StreamInfo.self, forKey: .streamAdded)
    streamRemoved = try container.decodeIfPresent(String.self, forKey: .streamRemoved) ?? ""
    streamActivated = try container.decodeIfPresent(
      GoPeepV1StreamInfo.self,
      forKey: .streamActivated
    )
    streamDeactivated = try container.decodeIfPresent(String.self, forKey: .streamDeactivated) ?? ""
    width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
    height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 0
    cursorX = try container.decodeIfPresent(Double.self, forKey: .cursorX) ?? 0
    cursorY = try container.decodeIfPresent(Double.self, forKey: .cursorY) ?? 0
    cursorInView = try container.decodeIfPresent(Bool.self, forKey: .cursorInView) ?? false
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encodeNonEmpty(room, forKey: .room)
    if let role, !role.rawValue.isEmpty {
      try container.encode(role, forKey: .role)
    }
    try container.encodeNonEmpty(sdp, forKey: .sdp)
    try container.encodeNonEmpty(candidate, forKey: .candidate)
    try container.encodeNonEmpty(errorMessage, forKey: .errorMessage)
    try container.encodeNonEmpty(peerID, forKey: .peerID)
    try container.encodeNonEmpty(password, forKey: .password)
    try container.encodeNonEmpty(secret, forKey: .secret)
    try container.encodeNonEmpty(trackID, forKey: .trackID)
    if !streams.isEmpty {
      try container.encode(streams, forKey: .streams)
    }
    try container.encodeNonEmpty(focusedTrack, forKey: .focusedTrack)
    try container.encodeIfPresent(streamAdded, forKey: .streamAdded)
    try container.encodeNonEmpty(streamRemoved, forKey: .streamRemoved)
    try container.encodeIfPresent(streamActivated, forKey: .streamActivated)
    try container.encodeNonEmpty(streamDeactivated, forKey: .streamDeactivated)
    if width != 0 { try container.encode(width, forKey: .width) }
    if height != 0 { try container.encode(height, forKey: .height) }
    if type == .cursorPosition {
      try container.encode(cursorX, forKey: .cursorX)
      try container.encode(cursorY, forKey: .cursorY)
      try container.encode(cursorInView, forKey: .cursorInView)
    } else {
      if cursorX != 0 { try container.encode(cursorX, forKey: .cursorX) }
      if cursorY != 0 { try container.encode(cursorY, forKey: .cursorY) }
      if cursorInView { try container.encode(true, forKey: .cursorInView) }
    }
  }
}

extension KeyedEncodingContainer {
  fileprivate mutating func encodeNonEmpty(_ value: String, forKey key: Key) throws {
    if !value.isEmpty {
      try encode(value, forKey: key)
    }
  }
}

public enum GoPeepV1ProtocolError: Error, Equatable, Sendable {
  case invalidRoomCode(String)
  case emptyReservationSecret
  case invalidSignalingServerURL(URL)
  case invalidReservationURL(URL)
  case emptyICEServerURLs
}

public enum LiveShareServerEndpointError: Error, Equatable, Sendable {
  case empty
  case invalidURL(String)
  case unsupportedScheme(String)
  case insecureRemoteServer
  case missingHost
  case credentialsNotAllowed
  case pathNotAllowed
  case queryOrFragmentNotAllowed
}

extension LiveShareServerEndpointError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .empty:
      "Enter a Live Share server address."
    case .invalidURL:
      "Enter a valid Live Share server address."
    case let .unsupportedScheme(scheme):
      "The Live Share server address cannot use the \(scheme) scheme."
    case .insecureRemoteServer:
      "Remote Live Share servers must use HTTPS. HTTP is available only for local development."
    case .missingHost:
      "The Live Share server address must include a host name."
    case .credentialsNotAllowed:
      "Remove the username and password from the Live Share server address."
    case .pathNotAllowed:
      "Enter the server root address without an additional path."
    case .queryOrFragmentNotAllowed:
      "Remove the query or fragment from the Live Share server address."
    }
  }
}

/// GoPeep room codes use `ADJECTIVE-NOUN-NN[N]`, are normalized to uppercase,
/// and intentionally don't require words to come from the server's current word lists.
public struct GoPeepV1RoomCode: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) throws {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
      !parts[0].isEmpty,
      !parts[1].isEmpty,
      (2...3).contains(parts[2].count),
      parts[2].utf8.allSatisfy({ (48...57).contains($0) })
    else {
      throw GoPeepV1ProtocolError.invalidRoomCode(rawValue)
    }
    self.rawValue = normalized
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    do {
      try self.init(rawValue: rawValue)
    } catch {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid GoPeep room code."
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The exact JSON returned by GoPeep's `POST /api/reserve` endpoint.
public struct GoPeepV1RoomReservationResponse: Codable, Equatable, Hashable, Sendable {
  public let room: GoPeepV1RoomCode
  public let secret: String

  public init(room: GoPeepV1RoomCode, secret: String) throws {
    guard !secret.isEmpty else {
      throw GoPeepV1ProtocolError.emptyReservationSecret
    }
    self.room = room
    self.secret = secret
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let room = try container.decode(GoPeepV1RoomCode.self, forKey: .room)
    let secret = try container.decode(String.self, forKey: .secret)
    do {
      try self.init(room: room, secret: secret)
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .secret,
        in: container,
        debugDescription: "A reservation secret cannot be empty."
      )
    }
  }
}

/// Host credentials retained for the lifetime of a reserved GoPeep room.
public struct GoPeepV1RoomConfiguration: Codable, Equatable, Hashable, Sendable {
  public let room: GoPeepV1RoomCode
  public let secret: String
  public let password: String?

  public init(reservation: GoPeepV1RoomReservationResponse, password: String? = nil) {
    room = reservation.room
    secret = reservation.secret
    self.password = password?.isEmpty == true ? nil : password
  }
}

/// Dependency-free ICE configuration. A future WebRTC adapter maps these values to
/// its own ICE-server type without leaking that dependency into the domain package.
public struct GoPeepV1ICEServer: Codable, Equatable, Hashable, Sendable {
  public let urls: [String]
  public let username: String?
  public let credential: String?

  public init(urls: [String], username: String? = nil, credential: String? = nil) throws {
    guard !urls.isEmpty else {
      throw GoPeepV1ProtocolError.emptyICEServerURLs
    }
    self.urls = urls
    self.username = username
    self.credential = credential
  }
}

/// A user-facing Live Share service root. The app stores this HTTP(S) value and
/// derives GoPeep's reservation, WebSocket signaling, and viewer URLs from it.
/// Keeping the root canonical prevents a custom path or credential from being
/// silently discarded when those protocol endpoints are constructed.
public struct LiveShareServerEndpoint: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let baseURL: URL

  public init(userInput: String) throws {
    let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw LiveShareServerEndpointError.empty
    }

    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: candidate) else {
      throw LiveShareServerEndpointError.invalidURL(trimmed)
    }
    let suppliedScheme = components.scheme?.lowercased() ?? ""
    switch suppliedScheme {
    case "https", "wss":
      components.scheme = "https"
    case "http", "ws":
      components.scheme = "http"
    default:
      throw LiveShareServerEndpointError.unsupportedScheme(
        suppliedScheme.isEmpty ? "unknown" : suppliedScheme
      )
    }

    guard let host = components.host, !host.isEmpty else {
      throw LiveShareServerEndpointError.missingHost
    }
    guard components.user == nil, components.password == nil else {
      throw LiveShareServerEndpointError.credentialsNotAllowed
    }
    guard components.query == nil, components.fragment == nil else {
      throw LiveShareServerEndpointError.queryOrFragmentNotAllowed
    }
    guard components.path.isEmpty || components.path == "/" else {
      throw LiveShareServerEndpointError.pathNotAllowed
    }

    let normalizedHost = host.lowercased()
    if components.scheme == "http", !Self.isLoopbackHost(normalizedHost) {
      throw LiveShareServerEndpointError.insecureRemoteServer
    }
    components.host = normalizedHost
    components.path = ""
    guard let baseURL = components.url else {
      throw LiveShareServerEndpointError.invalidURL(trimmed)
    }
    self.baseURL = baseURL
  }

  public static let goPeepRemote = try! Self(
    userInput: "https://gopeep.tineestudio.se"
  )

  public var description: String { baseURL.absoluteString }

  public var configuration: GoPeepV1ServerConfiguration {
    get throws {
      var signalingComponents = URLComponents(
        url: baseURL,
        resolvingAgainstBaseURL: false
      )!
      signalingComponents.scheme = baseURL.scheme == "https" ? "wss" : "ws"
      return try GoPeepV1ServerConfiguration(
        signalingServerURL: signalingComponents.url!
      )
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    do {
      try self.init(userInput: value)
    } catch {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid Live Share server endpoint."
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  private static func isLoopbackHost(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1"
      || host.hasSuffix(".localhost")
  }
}

public struct GoPeepV1ServerConfiguration: Codable, Equatable, Sendable {
  public let signalingServerURL: URL
  public let reservationURL: URL
  public let iceServers: [GoPeepV1ICEServer]
  public let forceRelay: Bool

  public init(
    signalingServerURL: URL,
    reservationURL: URL? = nil,
    iceServers: [GoPeepV1ICEServer] = Self.goPeepDefaultSTUNServers,
    forceRelay: Bool = false
  ) throws {
    guard ["ws", "wss"].contains(signalingServerURL.scheme?.lowercased() ?? ""),
      signalingServerURL.host != nil
    else {
      throw GoPeepV1ProtocolError.invalidSignalingServerURL(signalingServerURL)
    }

    let resolvedReservationURL =
      reservationURL
      ?? Self.makeReservationURL(
        from: signalingServerURL
      )
    guard ["http", "https"].contains(resolvedReservationURL.scheme?.lowercased() ?? ""),
      resolvedReservationURL.host != nil
    else {
      throw GoPeepV1ProtocolError.invalidReservationURL(resolvedReservationURL)
    }

    self.signalingServerURL = signalingServerURL
    self.reservationURL = resolvedReservationURL
    self.iceServers = iceServers
    self.forceRelay = forceRelay
  }

  public func signalingURL(for room: GoPeepV1RoomCode) -> URL {
    var components = URLComponents(url: signalingServerURL, resolvingAgainstBaseURL: false)!
    components.path = "/ws/\(room.rawValue)"
    components.query = nil
    components.fragment = nil
    return components.url!
  }

  public func viewerURL(for room: GoPeepV1RoomCode) -> URL {
    var components = URLComponents(url: signalingServerURL, resolvingAgainstBaseURL: false)!
    components.scheme = signalingServerURL.scheme?.lowercased() == "wss" ? "https" : "http"
    components.path = "/\(room.rawValue)"
    components.query = nil
    components.fragment = nil
    return components.url!
  }

  public static let goPeepDefaultSTUNServers: [GoPeepV1ICEServer] = [
    try! GoPeepV1ICEServer(urls: ["stun:stun.l.google.com:19302"]),
    try! GoPeepV1ICEServer(urls: ["stun:stun1.l.google.com:19302"]),
    try! GoPeepV1ICEServer(urls: ["stun:stun2.l.google.com:19302"]),
  ]

  public static let goPeepRemote: Self = try! Self(
    signalingServerURL: URL(string: "wss://gopeep.tineestudio.se")!
  )

  public static let localDevelopment: Self = try! Self(
    signalingServerURL: URL(string: "ws://localhost:8080")!
  )

  private static func makeReservationURL(from signalingURL: URL) -> URL {
    var components = URLComponents(url: signalingURL, resolvingAgainstBaseURL: false)!
    components.scheme = signalingURL.scheme?.lowercased() == "wss" ? "https" : "http"
    components.path = "/api/reserve"
    components.query = nil
    components.fragment = nil
    return components.url!
  }
}
