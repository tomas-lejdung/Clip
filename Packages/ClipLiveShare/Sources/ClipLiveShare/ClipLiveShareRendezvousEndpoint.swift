import Foundation

/// Validated root endpoint for Clip's native-v3 opaque rendezvous service.
public struct ClipLiveShareRendezvousEndpoint:
  Codable, Equatable, Hashable, Sendable, CustomStringConvertible
{
  public let rootURL: URL

  private enum CodingKeys: String, CodingKey {
    case rootURL
  }

  public init(rootURL: URL) throws {
    guard var components = URLComponents(
      url: rootURL,
      resolvingAgainstBaseURL: false
    ) else {
      throw ClipLiveShareProtocolError.invalidEndpoint(
        "not an absolute URL"
      )
    }
    let inputScheme = components.scheme?.lowercased()
    let scheme: String?
    switch inputScheme {
    case "https", "wss":
      scheme = "https"
    case "http", "ws":
      scheme = "http"
    default:
      scheme = nil
    }
    guard let scheme else {
      throw ClipLiveShareProtocolError.invalidEndpoint(
        "the scheme must be HTTPS"
      )
    }
    guard let host = components.host?.lowercased(), !host.isEmpty else {
      throw ClipLiveShareProtocolError.invalidEndpoint(
        "the host is missing"
      )
    }
    guard components.user == nil, components.password == nil else {
      throw ClipLiveShareProtocolError.invalidEndpoint(
        "credentials are not allowed"
      )
    }
    guard components.query == nil, components.fragment == nil else {
      throw ClipLiveShareProtocolError.invalidEndpoint(
        "queries and fragments are not allowed"
      )
    }
    guard components.path.isEmpty || components.path == "/" else {
      throw ClipLiveShareProtocolError.invalidEndpoint(
        "the endpoint must be deployed at the host root"
      )
    }
    if scheme == "http", !Self.isLocalDevelopmentHost(host) {
      throw ClipLiveShareProtocolError.invalidEndpoint(
        "remote deployments must use HTTPS"
      )
    }
    components.scheme = scheme
    components.host = host
    components.path = ""
    guard let normalized = components.url else {
      throw ClipLiveShareProtocolError.invalidEndpoint(
        "normalization failed"
      )
    }
    self.rootURL = normalized
  }

  public init(userInput: String) throws {
    let trimmed = userInput.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !trimmed.isEmpty else {
      throw ClipLiveShareProtocolError.invalidEndpoint(
        "the endpoint is empty"
      )
    }
    guard
      let url = URL(
        string: trimmed.contains("://")
          ? trimmed
          : "https://\(trimmed)"
      )
    else {
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

  public static let official = try! Self(
    rootURL: URL(string: "https://clip.tineestudio.se")!
  )
  public static let localDevelopment = try! Self(
    rootURL: URL(string: "http://localhost:8080")!
  )

  public var description: String { rootURL.absoluteString }

  public var capabilitiesURL: URL {
    url(path: "/.well-known/clip-native-rendezvous")
  }

  public var healthURL: URL { url(path: "/healthz") }
  public var versionURL: URL { url(path: "/version") }

  private func url(path: String) -> URL {
    var components = URLComponents(
      url: rootURL,
      resolvingAgainstBaseURL: false
    )!
    components.path = path
    return components.url!
  }

  private static func isLocalDevelopmentHost(_ host: String) -> Bool {
    host == "localhost"
      || host == "127.0.0.1"
      || host == "::1"
      || host.hasSuffix(".localhost")
  }
}
