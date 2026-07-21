import Foundation

public enum ClipNativeRendezvousLimits {
    public static let rendezvousIDBytes = 32
    public static let ownerTokenBytes = 32
    public static let routeIDBytes = 16
    public static let maximumMessageBytes = 262_144
    public static let maximumDescriptorBytes = 16_384
    public static let maximumOpaquePayloadBytes = 196_000
    public static let maximumPendingRoutes = 8
    public static let maximumHTTPResponseBytes = 65_536
}

public enum ClipNativeRendezvousError: Error, Equatable, Sendable,
    LocalizedError
{
    case invalidEndpoint
    case invalidRendezvousID
    case invalidOwnerToken
    case invalidCapabilities
    case invalidResponse
    case responseTooLarge
    case invalidDescriptor
    case invalidOpaquePayload
    case invalidRouteID
    case invalidMessage
    case messageTooLarge(maximumBytes: Int)
    case incompatibleServer
    case rejected(statusCode: Int)
    case rendezvousConflict
    case rendezvousNotFound
    case rendezvousNotLive
    case hostOffline
    case connectionAlreadyActive
    case connectionFailed
    case notConnected
    case routeNotFound
    case routeCapacityReached
    case sendFailed
    case reconnectExhausted
    case operationSuperseded
    case eventBufferOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The native rendezvous server endpoint is invalid."
        case .invalidRendezvousID:
            "The native rendezvous identifier must contain 32 random bytes."
        case .invalidOwnerToken:
            "The native rendezvous owner token must contain 32 random bytes."
        case .invalidCapabilities, .incompatibleServer:
            "The server does not support Clip native rendezvous API v1."
        case .invalidResponse:
            "The native rendezvous server returned an invalid response."
        case .responseTooLarge:
            "The native rendezvous server response exceeded Clip’s safety limit."
        case .invalidDescriptor:
            "The signed native session descriptor is invalid or too large."
        case .invalidOpaquePayload:
            "The native rendezvous payload is invalid or too large."
        case .invalidRouteID:
            "The native rendezvous route identifier is invalid."
        case .invalidMessage:
            "The native rendezvous server sent an invalid routing message."
        case .messageTooLarge(let maximumBytes):
            "The native rendezvous message exceeds the \(maximumBytes)-byte limit."
        case .rejected(let statusCode):
            "The native rendezvous server rejected the request (HTTP \(statusCode))."
        case .rendezvousConflict:
            "That native rendezvous identifier is already owned."
        case .rendezvousNotFound:
            "The native rendezvous identifier is offline or unknown."
        case .rendezvousNotLive:
            "The friend is not currently sharing."
        case .hostOffline:
            "The native rendezvous host is not connected."
        case .connectionAlreadyActive:
            "A native rendezvous transport is already active."
        case .connectionFailed:
            "Clip could not connect to the native rendezvous server."
        case .notConnected:
            "The native rendezvous transport is not connected."
        case .routeNotFound:
            "The temporary native rendezvous route is no longer available."
        case .routeCapacityReached:
            "The native rendezvous has too many pending routes."
        case .sendFailed:
            "Clip could not send the native rendezvous message."
        case .reconnectExhausted:
            "Clip exhausted its bounded native rendezvous reconnect attempts."
        case .operationSuperseded:
            "A newer native rendezvous lifecycle operation replaced this one."
        case .eventBufferOverflow:
            "The native rendezvous event buffer overflowed."
        }
    }
}

public struct ClipNativeRendezvousTarget: Equatable, Sendable {
    public let endpoint: URL
    public let rendezvousID: Data

    public init(endpoint: URL, rendezvousID: Data) throws {
        guard Self.isValid(endpoint: endpoint) else {
            throw ClipNativeRendezvousError.invalidEndpoint
        }
        guard rendezvousID.count == ClipNativeRendezvousLimits.rendezvousIDBytes else {
            throw ClipNativeRendezvousError.invalidRendezvousID
        }
        self.endpoint = endpoint
        self.rendezvousID = rendezvousID
    }

    public var rendezvousIDString: String {
        ClipNativeRendezvousBase64URL.encode(rendezvousID)
    }

    private static func isValid(endpoint: URL) -> Bool {
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return false }
        return true
    }
}

public struct ClipNativeRendezvousOwner: Equatable, Sendable {
    public let target: ClipNativeRendezvousTarget
    public let ownerToken: Data

    public init(target: ClipNativeRendezvousTarget, ownerToken: Data) throws {
        guard ownerToken.count == ClipNativeRendezvousLimits.ownerTokenBytes else {
            throw ClipNativeRendezvousError.invalidOwnerToken
        }
        self.target = target
        self.ownerToken = ownerToken
    }

    public var ownerTokenString: String {
        ClipNativeRendezvousBase64URL.encode(ownerToken)
    }

    public var authorizationHeaderValue: String {
        "Bearer \(ownerTokenString)"
    }
}

public enum ClipNativeRendezvousState: String, Codable, Equatable, Sendable {
    case offline
    case preparing
    case active
}

public struct ClipNativeRendezvousCapabilities: Equatable, Sendable {
    public let apiVersion: Int
    public let messageVersion: Int
    public let serverVersion: String
    public let rendezvousPathTemplate: String
    public let hostWebSocketPathTemplate: String
    public let viewerWebSocketPathTemplate: String
    public let maximumMessageBytes: Int
    public let maximumDescriptorBytes: Int
    public let maximumOpaquePayloadBytes: Int
    public let maximumPendingRoutes: Int
    public let maximumRendezvous: Int

    public init(
        apiVersion: Int = 1,
        messageVersion: Int = 2,
        serverVersion: String,
        rendezvousPathTemplate: String = "/api/native/v1/rendezvous/{rendezvous}",
        hostWebSocketPathTemplate: String = "/api/native/v1/rendezvous/{rendezvous}/host",
        viewerWebSocketPathTemplate: String = "/api/native/v1/rendezvous/{rendezvous}/viewer",
        maximumMessageBytes: Int = ClipNativeRendezvousLimits.maximumMessageBytes,
        maximumDescriptorBytes: Int = ClipNativeRendezvousLimits.maximumDescriptorBytes,
        maximumOpaquePayloadBytes: Int = ClipNativeRendezvousLimits.maximumOpaquePayloadBytes,
        maximumPendingRoutes: Int = ClipNativeRendezvousLimits.maximumPendingRoutes,
        maximumRendezvous: Int = 1_024
    ) throws {
        guard apiVersion == 1,
              messageVersion == 2,
              !serverVersion.isEmpty,
              serverVersion.utf8.count <= 128,
              Self.validTemplate(rendezvousPathTemplate, suffix: nil),
              Self.validTemplate(hostWebSocketPathTemplate, suffix: "/host"),
              Self.validTemplate(viewerWebSocketPathTemplate, suffix: "/viewer"),
              (1...ClipNativeRendezvousLimits.maximumMessageBytes)
                .contains(maximumMessageBytes),
              (1...ClipNativeRendezvousLimits.maximumDescriptorBytes)
                .contains(maximumDescriptorBytes),
              (1...ClipNativeRendezvousLimits.maximumOpaquePayloadBytes)
                .contains(maximumOpaquePayloadBytes),
              (1...ClipNativeRendezvousLimits.maximumPendingRoutes)
                .contains(maximumPendingRoutes),
              (1...16_384).contains(maximumRendezvous)
        else {
            throw ClipNativeRendezvousError.invalidCapabilities
        }
        self.apiVersion = apiVersion
        self.messageVersion = messageVersion
        self.serverVersion = serverVersion
        self.rendezvousPathTemplate = rendezvousPathTemplate
        self.hostWebSocketPathTemplate = hostWebSocketPathTemplate
        self.viewerWebSocketPathTemplate = viewerWebSocketPathTemplate
        self.maximumMessageBytes = maximumMessageBytes
        self.maximumDescriptorBytes = maximumDescriptorBytes
        self.maximumOpaquePayloadBytes = maximumOpaquePayloadBytes
        self.maximumPendingRoutes = maximumPendingRoutes
        self.maximumRendezvous = maximumRendezvous
    }

    public func rendezvousURL(for target: ClipNativeRendezvousTarget) throws -> URL {
        try Self.resolve(rendezvousPathTemplate, target: target, webSocket: false)
    }

    public func sessionURL(for target: ClipNativeRendezvousTarget) throws -> URL {
        try rendezvousURL(for: target).appending(path: "session")
    }

    public func hostWebSocketURL(for target: ClipNativeRendezvousTarget) throws -> URL {
        try Self.resolve(hostWebSocketPathTemplate, target: target, webSocket: true)
    }

    public func viewerWebSocketURL(for target: ClipNativeRendezvousTarget) throws -> URL {
        try Self.resolve(viewerWebSocketPathTemplate, target: target, webSocket: true)
    }

    private static func validTemplate(_ value: String, suffix: String?) -> Bool {
        guard value.hasPrefix("/"),
              value.filter({ $0 == "{" }).count == 1,
              value.filter({ $0 == "}" }).count == 1,
              value.contains("{rendezvous}"),
              !value.contains("?"),
              !value.contains("#"),
              !value.contains("://"),
              value.utf8.count <= 512
        else { return false }
        if let suffix { return value.hasSuffix(suffix) }
        return true
    }

    private static func resolve(
        _ template: String,
        target: ClipNativeRendezvousTarget,
        webSocket: Bool
    ) throws -> URL {
        guard validTemplate(template, suffix: nil),
              let encodedPath = template.replacingOccurrences(
                of: "{rendezvous}",
                with: target.rendezvousIDString
              ).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(
                url: target.endpoint,
                resolvingAgainstBaseURL: false
              )
        else { throw ClipNativeRendezvousError.invalidCapabilities }
        components.path = encodedPath
        components.query = nil
        components.fragment = nil
        if webSocket {
            switch components.scheme?.lowercased() {
            case "http": components.scheme = "ws"
            case "https": components.scheme = "wss"
            default: throw ClipNativeRendezvousError.invalidEndpoint
            }
        }
        guard let url = components.url else {
            throw ClipNativeRendezvousError.invalidEndpoint
        }
        return url
    }
}

public struct ClipNativeRendezvousLease: Equatable, Sendable {
    public let rendezvousID: Data
    public let leaseDurationSeconds: Int64
}

public struct ClipNativeRendezvousStatus: Equatable, Sendable {
    public let rendezvousID: Data
    public let state: ClipNativeRendezvousState
}

public enum ClipNativeRendezvousRole: Equatable, Sendable {
    case host
    case viewer
}

public enum ClipNativeRendezvousDisconnectReason: Equatable, Sendable {
    case connectionLost
    case reconnectExhausted
}

public enum ClipNativeRendezvousEvent: Equatable, Sendable {
    case connecting(role: ClipNativeRendezvousRole, reconnectAttempt: Int)
    case connected(role: ClipNativeRendezvousRole, reconnectAttempt: Int)
    case hostPreparing(reconnectAttempt: Int)
    case hostActive
    case routeOpened(routeID: String, descriptor: Data?)
    case relay(routeID: String, payload: Data, sequence: UInt64)
    case routeClosed(routeID: String, reason: String?)
    case serverError(code: String)
    case invalidMessageReceived
    case disconnected(reason: ClipNativeRendezvousDisconnectReason, willReconnect: Bool)
    case reconnectScheduled(attempt: Int, delay: Duration)
    case eventBufferOverflow
    case stopped
}

enum ClipNativeRendezvousBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeCanonical(
        _ value: String,
        minimumBytes: Int,
        maximumBytes: Int
    ) -> Data? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                let scalar = $0.value
                return (65...90).contains(scalar)
                    || (97...122).contains(scalar)
                    || (48...57).contains(scalar)
                    || scalar == 45
                    || scalar == 95
              })
        else { return nil }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard + padding),
              (minimumBytes...maximumBytes).contains(data.count),
              encode(data) == value
        else { return nil }
        return data
    }
}

enum ClipNativeRendezvousWireType: String, Codable {
    case routeOpened = "native-route-opened"
    case relay = "native-relay"
    case routeClosed = "native-route-closed"
    case closeRoute = "native-close-route"
    case hostUnavailable = "native-host-unavailable"
    case error = "native-error"
}

struct ClipNativeRendezvousWireMessage: Codable, Equatable {
    let type: ClipNativeRendezvousWireType
    let version: Int
    var routeID: String?
    var sequence: UInt64?
    var payload: String?
    var reason: String?
    var code: String?
    var message: String?

    init(
        type: ClipNativeRendezvousWireType,
        version: Int = 2,
        routeID: String? = nil,
        sequence: UInt64? = nil,
        payload: String? = nil,
        reason: String? = nil,
        code: String? = nil,
        message: String? = nil
    ) {
        self.type = type
        self.version = version
        self.routeID = routeID
        self.sequence = sequence
        self.payload = payload
        self.reason = reason
        self.code = code
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case routeID = "routeId"
        case sequence
        case payload
        case reason
        case code
        case message
    }
}

enum ClipNativeRendezvousWireCodec {
    static func encode(
        _ message: ClipNativeRendezvousWireMessage,
        maximumBytes: Int
    ) throws -> ClipLiveShareWebSocketPayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(message)
        guard data.count <= maximumBytes else {
            throw ClipNativeRendezvousError.messageTooLarge(maximumBytes: maximumBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClipNativeRendezvousError.sendFailed
        }
        return .text(text)
    }

    static func decode(
        _ payload: ClipLiveShareWebSocketPayload,
        role: ClipNativeRendezvousRole,
        capabilities: ClipNativeRendezvousCapabilities
    ) throws -> (message: ClipNativeRendezvousWireMessage, decodedPayload: Data?) {
        let data: Data = switch payload {
        case .text(let text): Data(text.utf8)
        case .data(let data): data
        }
        guard !data.isEmpty, data.count <= capabilities.maximumMessageBytes else {
            throw ClipNativeRendezvousError.invalidMessage
        }
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any],
              let typeValue = object["type"] as? String,
              let type = ClipNativeRendezvousWireType(rawValue: typeValue)
        else { throw ClipNativeRendezvousError.invalidMessage }
        let allowed: Set<String> = switch type {
        case .routeOpened: ["type", "version", "routeId", "payload"]
        case .relay: ["type", "version", "routeId", "sequence", "payload"]
        case .routeClosed: ["type", "version", "routeId", "reason"]
        case .closeRoute: ["type", "version", "routeId", "reason"]
        case .hostUnavailable: ["type", "version"]
        case .error: ["type", "version", "code", "message"]
        }
        guard Set(object.keys).isSubset(of: allowed) else {
            throw ClipNativeRendezvousError.invalidMessage
        }
        let message = try JSONDecoder().decode(
            ClipNativeRendezvousWireMessage.self,
            from: data
        )
        guard message.version == capabilities.messageVersion else {
            throw ClipNativeRendezvousError.invalidMessage
        }

        let routeID: String? = message.routeID
        if let routeID, !validRouteID(routeID) {
            throw ClipNativeRendezvousError.invalidMessage
        }
        let decodedPayload: Data?
        switch message.type {
        case .routeOpened:
            guard routeID != nil,
                  message.sequence == nil,
                  message.reason == nil,
                  message.code == nil,
                  message.message == nil
            else { throw ClipNativeRendezvousError.invalidMessage }
            switch role {
            case .host:
                guard message.payload == nil else {
                    throw ClipNativeRendezvousError.invalidMessage
                }
                decodedPayload = nil
            case .viewer:
                guard let value = message.payload,
                      let descriptor = ClipNativeRendezvousBase64URL.decodeCanonical(
                        value,
                        minimumBytes: 1,
                        maximumBytes: capabilities.maximumDescriptorBytes
                      )
                else { throw ClipNativeRendezvousError.invalidMessage }
                decodedPayload = descriptor
            }

        case .relay:
            guard let sequence = message.sequence, sequence > 0,
                  let value = message.payload,
                  message.reason == nil,
                  message.code == nil,
                  message.message == nil,
                  routeID != nil,
                  let opaque = ClipNativeRendezvousBase64URL.decodeCanonical(
                    value,
                    minimumBytes: 1,
                    maximumBytes: capabilities.maximumOpaquePayloadBytes
                  )
            else { throw ClipNativeRendezvousError.invalidMessage }
            decodedPayload = opaque

        case .routeClosed:
            guard routeID != nil,
                  message.sequence == nil,
                  message.payload == nil,
                  message.code == nil,
                  message.message == nil,
                  validReason(message.reason)
            else { throw ClipNativeRendezvousError.invalidMessage }
            decodedPayload = nil

        case .hostUnavailable:
            guard message.routeID == nil,
                  message.sequence == nil,
                  message.payload == nil,
                  message.reason == nil,
                  message.code == nil,
                  message.message == nil
            else { throw ClipNativeRendezvousError.invalidMessage }
            decodedPayload = nil

        case .error:
            guard message.routeID == nil,
                  message.sequence == nil,
                  message.payload == nil,
                  message.reason == nil,
                  validASCII(message.code, maximumBytes: 64, required: true),
                  validASCII(message.message, maximumBytes: 256, required: false)
            else { throw ClipNativeRendezvousError.invalidMessage }
            decodedPayload = nil

        case .closeRoute:
            throw ClipNativeRendezvousError.invalidMessage
        }
        return (message, decodedPayload)
    }

    static func validRouteID(_ value: String) -> Bool {
        ClipNativeRendezvousBase64URL.decodeCanonical(
            value,
            minimumBytes: ClipNativeRendezvousLimits.routeIDBytes,
            maximumBytes: ClipNativeRendezvousLimits.routeIDBytes
        ) != nil
    }

    static func validReason(_ value: String?) -> Bool {
        validASCII(value, maximumBytes: 120, required: false)
    }

    private static func validASCII(
        _ value: String?,
        maximumBytes: Int,
        required: Bool
    ) -> Bool {
        guard let value else { return !required }
        guard !required || !value.isEmpty,
              value.utf8.count <= maximumBytes
        else { return false }
        return value.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) }
    }
}
