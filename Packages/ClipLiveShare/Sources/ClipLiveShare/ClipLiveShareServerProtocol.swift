import Foundation

public struct ClipLiveShareServerEndpoint: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rootURL: URL

  private enum CodingKeys: String, CodingKey {
    case rootURL
  }

  public init(rootURL: URL) throws {
    guard var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false) else {
      throw ClipLiveShareProtocolError.invalidEndpoint("not an absolute URL")
    }
    let inputScheme = components.scheme?.lowercased()
    let scheme: String?
    switch inputScheme {
    case "https", "wss": scheme = "https"
    case "http", "ws": scheme = "http"
    default: scheme = nil
    }
    guard let scheme else {
      throw ClipLiveShareProtocolError.invalidEndpoint("the scheme must be HTTPS")
    }
    guard let host = components.host?.lowercased(), !host.isEmpty else {
      throw ClipLiveShareProtocolError.invalidEndpoint("the host is missing")
    }
    guard components.user == nil, components.password == nil else {
      throw ClipLiveShareProtocolError.invalidEndpoint("credentials are not allowed")
    }
    guard components.query == nil, components.fragment == nil else {
      throw ClipLiveShareProtocolError.invalidEndpoint("queries and fragments are not allowed")
    }
    guard components.path.isEmpty || components.path == "/" else {
      throw ClipLiveShareProtocolError.invalidEndpoint("the endpoint must be deployed at the host root")
    }
    if scheme == "http", !Self.isLocalDevelopmentHost(host) {
      throw ClipLiveShareProtocolError.invalidEndpoint("remote deployments must use HTTPS")
    }

    components.scheme = scheme
    components.host = host
    components.path = ""
    guard let normalized = components.url else {
      throw ClipLiveShareProtocolError.invalidEndpoint("normalization failed")
    }
    self.rootURL = normalized
  }

  public init(userInput: String) throws {
    let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ClipLiveShareProtocolError.invalidEndpoint("the endpoint is empty")
    }
    guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") else {
      throw ClipLiveShareProtocolError.invalidEndpoint("not a URL")
    }
    try self.init(rootURL: url)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(rootURL: container.decode(URL.self, forKey: .rootURL))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rootURL, forKey: .rootURL)
  }

  public static let official = try! Self(rootURL: URL(string: "https://clip.tineestudio.se")!)
  public static let localDevelopment = try! Self(rootURL: URL(string: "http://localhost:8080")!)

  public var description: String { rootURL.absoluteString }

  public var capabilitiesURL: URL { url(path: "/.well-known/clip-live-share") }
  public var healthURL: URL { url(path: "/healthz") }
  public var versionURL: URL { url(path: "/version") }

  public func advertiseRoomURL(_ room: ClipLiveShareRoomName) -> URL {
    url(path: "/api/v1/rooms/\(room.rawValue)")
  }

  public func standardHostWebSocketURL(_ room: ClipLiveShareRoomName) -> URL {
    webSocketURL(path: "/api/v1/rooms/\(room.rawValue)/host")
  }

  public func standardViewerWebSocketURL(_ room: ClipLiveShareRoomName) -> URL {
    webSocketURL(path: "/api/v1/rooms/\(room.rawValue)/viewer")
  }

  public func standardViewerURL(_ room: ClipLiveShareRoomName) -> URL {
    url(path: "/\(room.rawValue)")
  }

  public func url(for template: String, room: ClipLiveShareRoomName) throws -> URL {
    try ClipLiveSharePathTemplate.validate(template)
    return url(path: template.replacingOccurrences(of: "{room}", with: room.rawValue))
  }

  public func webSocketURL(for template: String, room: ClipLiveShareRoomName) throws -> URL {
    let httpURL = try url(for: template, room: room)
    return Self.convertingToWebSocket(httpURL)
  }

  private func url(path: String) -> URL {
    var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)!
    components.path = path
    return components.url!
  }

  private func webSocketURL(path: String) -> URL {
    Self.convertingToWebSocket(url(path: path))
  }

  private static func convertingToWebSocket(_ url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    return components.url!
  }

  private static func isLocalDevelopmentHost(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
  }
}

public struct ClipLiveShareICEServer: Codable, Equatable, Hashable, Sendable {
  public let urls: [String]
  public let username: String?
  public let credential: String?

  public init(urls: [String], username: String? = nil, credential: String? = nil) throws {
    guard !urls.isEmpty, urls.count <= 16 else {
      throw ClipLiveShareProtocolError.invalidCapabilities("an ICE server must have 1...16 URLs")
    }
    for value in urls {
      guard
        value.utf8.count <= 2_048,
        let scheme = URLComponents(string: value)?.scheme?.lowercased(),
        ["stun", "stuns", "turn", "turns"].contains(scheme)
      else {
        throw ClipLiveShareProtocolError.invalidCapabilities("invalid ICE server URL")
      }
    }
    guard (username?.utf8.count ?? 0) <= 1_024, (credential?.utf8.count ?? 0) <= 4_096 else {
      throw ClipLiveShareProtocolError.invalidCapabilities("ICE credentials are too large")
    }
    self.urls = urls
    self.username = username
    self.credential = credential
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      urls: container.decode([String].self, forKey: .urls),
      username: container.decodeIfPresent(String.self, forKey: .username),
      credential: container.decodeIfPresent(String.self, forKey: .credential)
    )
  }
}

public struct ClipLiveShareCapabilities: Codable, Equatable, Hashable, Sendable {
  public struct Limits: Codable, Equatable, Hashable, Sendable {
    public let maximumMessageBytes: Int
    public let maximumPendingViewersPerRoom: Int

    public init(maximumMessageBytes: Int, maximumPendingViewersPerRoom: Int) throws {
      guard (1...ClipLiveShareV1.maximumWebSocketMessageBytes).contains(maximumMessageBytes) else {
        throw ClipLiveShareProtocolError.invalidCapabilities("invalid maximum message size")
      }
      guard (1...ClipLiveShareV1.maximumPendingRoutesPerRoom).contains(maximumPendingViewersPerRoom) else {
        throw ClipLiveShareProtocolError.invalidCapabilities("invalid pending-viewer limit")
      }
      self.maximumMessageBytes = maximumMessageBytes
      self.maximumPendingViewersPerRoom = maximumPendingViewersPerRoom
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        maximumMessageBytes: container.decode(Int.self, forKey: .maximumMessageBytes),
        maximumPendingViewersPerRoom: container.decode(
          Int.self,
          forKey: .maximumPendingViewersPerRoom
        )
      )
    }
  }

  public let protocolIdentifier: String
  public let versions: [Int]
  public let serverVersion: String
  public let viewerPathTemplate: String
  public let hostWebSocketPathTemplate: String
  public let viewerWebSocketPathTemplate: String
  public let iceServers: [ClipLiveShareICEServer]
  public let limits: Limits

  public init(
    protocolIdentifier: String,
    versions: [Int],
    serverVersion: String,
    viewerPathTemplate: String,
    hostWebSocketPathTemplate: String,
    viewerWebSocketPathTemplate: String,
    iceServers: [ClipLiveShareICEServer],
    limits: Limits
  ) throws {
    guard protocolIdentifier == ClipLiveShareV1.protocolIdentifier else {
      throw ClipLiveShareProtocolError.invalidCapabilities("unexpected protocol identifier")
    }
    guard versions.contains(ClipLiveShareV1.version) else {
      throw ClipLiveShareProtocolError.invalidCapabilities("protocol version 1 is unavailable")
    }
    guard !versions.isEmpty, versions.count <= 32, Set(versions).count == versions.count else {
      throw ClipLiveShareProtocolError.invalidCapabilities("invalid version list")
    }
    guard !serverVersion.isEmpty, serverVersion.utf8.count <= 128 else {
      throw ClipLiveShareProtocolError.invalidCapabilities("invalid server version")
    }
    try ClipLiveSharePathTemplate.validate(viewerPathTemplate)
    try ClipLiveSharePathTemplate.validate(hostWebSocketPathTemplate)
    try ClipLiveSharePathTemplate.validate(viewerWebSocketPathTemplate)
    guard iceServers.count <= 32 else {
      throw ClipLiveShareProtocolError.invalidCapabilities("too many ICE servers")
    }

    self.protocolIdentifier = protocolIdentifier
    self.versions = versions
    self.serverVersion = serverVersion
    self.viewerPathTemplate = viewerPathTemplate
    self.hostWebSocketPathTemplate = hostWebSocketPathTemplate
    self.viewerWebSocketPathTemplate = viewerWebSocketPathTemplate
    self.iceServers = iceServers
    self.limits = limits
  }

  public static let v1Default = try! Self(
    protocolIdentifier: ClipLiveShareV1.protocolIdentifier,
    versions: [ClipLiveShareV1.version],
    serverVersion: "development",
    viewerPathTemplate: "/{room}",
    hostWebSocketPathTemplate: "/api/v1/rooms/{room}/host",
    viewerWebSocketPathTemplate: "/api/v1/rooms/{room}/viewer",
    iceServers: [try! ClipLiveShareICEServer(urls: ["stun:stun.l.google.com:19302"])],
    limits: try! Limits(
      maximumMessageBytes: ClipLiveShareV1.maximumWebSocketMessageBytes,
      maximumPendingViewersPerRoom: ClipLiveShareV1.maximumPendingRoutesPerRoom
    )
  )

  private enum CodingKeys: String, CodingKey {
    case protocolIdentifier = "protocol"
    case versions
    case serverVersion
    case viewerPathTemplate
    case hostWebSocketPathTemplate
    case viewerWebSocketPathTemplate
    case iceServers
    case limits
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      protocolIdentifier: container.decode(String.self, forKey: .protocolIdentifier),
      versions: container.decode([Int].self, forKey: .versions),
      serverVersion: container.decode(String.self, forKey: .serverVersion),
      viewerPathTemplate: container.decode(String.self, forKey: .viewerPathTemplate),
      hostWebSocketPathTemplate: container.decode(
        String.self,
        forKey: .hostWebSocketPathTemplate
      ),
      viewerWebSocketPathTemplate: container.decode(
        String.self,
        forKey: .viewerWebSocketPathTemplate
      ),
      iceServers: container.decode([ClipLiveShareICEServer].self, forKey: .iceServers),
      limits: container.decode(Limits.self, forKey: .limits)
    )
  }
}

public struct ClipLiveShareAdvertiseRoomRequest: Codable, Equatable, Hashable, Sendable {
  public let ownerToken: ClipLiveShareOwnerToken

  public init(ownerToken: ClipLiveShareOwnerToken) {
    self.ownerToken = ownerToken
  }
}

public struct ClipLiveShareRoomAdvertisement: Codable, Equatable, Hashable, Sendable {
  public let room: ClipLiveShareRoomName
  public let leaseDurationSeconds: Int

  public init(room: ClipLiveShareRoomName, leaseDurationSeconds: Int) throws {
    guard leaseDurationSeconds > 0 else {
      throw ClipLiveShareProtocolError.invalidResource("room lease duration must be positive")
    }
    self.room = room
    self.leaseDurationSeconds = leaseDurationSeconds
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      room: container.decode(ClipLiveShareRoomName.self, forKey: .room),
      leaseDurationSeconds: container.decode(Int.self, forKey: .leaseDurationSeconds)
    )
  }
}

public struct ClipLiveShareRoomConfiguration: Sendable {
  public let endpoint: ClipLiveShareServerEndpoint
  public let capabilities: ClipLiveShareCapabilities
  public let room: ClipLiveShareRoomName
  public let ownerToken: ClipLiveShareOwnerToken
  public let identity: ClipLiveShareRoomIdentity

  public init(
    endpoint: ClipLiveShareServerEndpoint,
    capabilities: ClipLiveShareCapabilities,
    room: ClipLiveShareRoomName,
    ownerToken: ClipLiveShareOwnerToken,
    identity: ClipLiveShareRoomIdentity
  ) {
    self.endpoint = endpoint
    self.capabilities = capabilities
    self.room = room
    self.ownerToken = ownerToken
    self.identity = identity
  }

  public var advertiseURL: URL { endpoint.advertiseRoomURL(room) }

  public var hostWebSocketURL: URL {
    get throws {
      try endpoint.webSocketURL(for: capabilities.hostWebSocketPathTemplate, room: room)
    }
  }

  public var viewerWebSocketURL: URL {
    get throws {
      try endpoint.webSocketURL(for: capabilities.viewerWebSocketPathTemplate, room: room)
    }
  }

  public var viewerURL: URL {
    get throws {
      let base = try endpoint.url(for: capabilities.viewerPathTemplate, room: room)
      return try ClipLiveShareViewerFragment(publicKey: identity.publicKey).adding(to: base)
    }
  }
}

private enum ClipLiveSharePathTemplate {
  static func validate(_ template: String) throws {
    let occurrences = template.components(separatedBy: "{room}").count - 1
    guard
      template.hasPrefix("/"),
      occurrences == 1,
      template.utf8.count <= 2_048,
      !template.contains("?"),
      !template.contains("#"),
      !template.contains("\\"),
      !template.contains("..")
    else {
      throw ClipLiveShareProtocolError.invalidPathTemplate(template)
    }
  }
}
