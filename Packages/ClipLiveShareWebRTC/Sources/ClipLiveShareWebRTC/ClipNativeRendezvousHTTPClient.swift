import Foundation

public struct ClipNativeRendezvousHTTPClient: Sendable {
    private let transport: any ClipLiveShareHTTPTransport

    public init(
        transport: any ClipLiveShareHTTPTransport = URLSessionClipLiveShareHTTPTransport()
    ) {
        self.transport = transport
    }

    public func discover(
        at endpoint: URL
    ) async throws -> ClipNativeRendezvousCapabilities {
        _ = try ClipNativeRendezvousTarget(
            endpoint: endpoint,
            rendezvousID: Data(repeating: 0, count: ClipNativeRendezvousLimits.rendezvousIDBytes)
        )
        guard let url = URL(
            string: "/.well-known/clip-native-rendezvous",
            relativeTo: endpoint
        )?.absoluteURL else {
            throw ClipNativeRendezvousError.invalidEndpoint
        }
        var request = baseRequest(url: url, method: "GET")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result = try await execute(request)
        guard result.statusCode == 200 else {
            throw ClipNativeRendezvousError.rejected(statusCode: result.statusCode)
        }
        let raw: CapabilitiesResponse = try strictDecode(
            result.data,
            allowedKeys: [
                "protocol", "apiVersion", "messageVersion", "serverVersion",
                "rendezvousPathTemplate", "hostWebSocketPathTemplate",
                "viewerWebSocketPathTemplate", "maximumMessageBytes",
                "maximumDescriptorBytes", "maximumOpaquePayloadBytes",
                "maximumPendingRoutes", "maximumRendezvous",
            ]
        )
        guard raw.protocolIdentifier == "clip-native-rendezvous" else {
            throw ClipNativeRendezvousError.incompatibleServer
        }
        do {
            return try ClipNativeRendezvousCapabilities(
                apiVersion: raw.apiVersion,
                messageVersion: raw.messageVersion,
                serverVersion: raw.serverVersion,
                rendezvousPathTemplate: raw.rendezvousPathTemplate,
                hostWebSocketPathTemplate: raw.hostWebSocketPathTemplate,
                viewerWebSocketPathTemplate: raw.viewerWebSocketPathTemplate,
                maximumMessageBytes: raw.maximumMessageBytes,
                maximumDescriptorBytes: raw.maximumDescriptorBytes,
                maximumOpaquePayloadBytes: raw.maximumOpaquePayloadBytes,
                maximumPendingRoutes: raw.maximumPendingRoutes,
                maximumRendezvous: raw.maximumRendezvous
            )
        } catch {
            throw ClipNativeRendezvousError.invalidCapabilities
        }
    }

    @discardableResult
    public func claim(
        _ owner: ClipNativeRendezvousOwner,
        capabilities: ClipNativeRendezvousCapabilities
    ) async throws -> ClipNativeRendezvousLease {
        let url = try capabilities.rendezvousURL(for: owner.target)
        var request = baseRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OwnerRequest(ownerToken: owner.ownerTokenString)
        )
        let result = try await execute(request)
        switch result.statusCode {
        case 200, 201:
            break
        case 409:
            throw ClipNativeRendezvousError.rendezvousConflict
        default:
            throw ClipNativeRendezvousError.rejected(statusCode: result.statusCode)
        }
        let response: LeaseResponse = try strictDecode(
            result.data,
            allowedKeys: ["rendezvousId", "leaseDurationSeconds"]
        )
        guard response.rendezvousID == owner.target.rendezvousIDString,
              response.leaseDurationSeconds > 0
        else { throw ClipNativeRendezvousError.invalidResponse }
        return ClipNativeRendezvousLease(
            rendezvousID: owner.target.rendezvousID,
            leaseDurationSeconds: response.leaseDurationSeconds
        )
    }

    @discardableResult
    public func renew(
        _ owner: ClipNativeRendezvousOwner,
        capabilities: ClipNativeRendezvousCapabilities
    ) async throws -> ClipNativeRendezvousLease {
        try await claim(owner, capabilities: capabilities)
    }

    public func status(
        _ target: ClipNativeRendezvousTarget,
        capabilities: ClipNativeRendezvousCapabilities
    ) async throws -> ClipNativeRendezvousStatus {
        let url = try capabilities.rendezvousURL(for: target)
        var request = baseRequest(url: url, method: "GET")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result = try await execute(request)
        if result.statusCode == 404 {
            throw ClipNativeRendezvousError.rendezvousNotFound
        }
        guard result.statusCode == 200 else {
            throw ClipNativeRendezvousError.rejected(statusCode: result.statusCode)
        }
        let response: StatusResponse = try strictDecode(
            result.data,
            allowedKeys: ["rendezvousId", "state"]
        )
        guard response.rendezvousID == target.rendezvousIDString,
              let state = ClipNativeRendezvousState(rawValue: response.state)
        else { throw ClipNativeRendezvousError.invalidResponse }
        return ClipNativeRendezvousStatus(
            rendezvousID: target.rendezvousID,
            state: state
        )
    }

    public func publishSession(
        descriptor: Data,
        for owner: ClipNativeRendezvousOwner,
        capabilities: ClipNativeRendezvousCapabilities
    ) async throws {
        guard !descriptor.isEmpty,
              descriptor.count <= capabilities.maximumDescriptorBytes
        else { throw ClipNativeRendezvousError.invalidDescriptor }
        let url = try capabilities.sessionURL(for: owner.target)
        var request = baseRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            owner.authorizationHeaderValue,
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            SessionRequest(descriptor: ClipNativeRendezvousBase64URL.encode(descriptor))
        )
        let result = try await execute(request)
        switch result.statusCode {
        case 204:
            return
        case 404:
            throw ClipNativeRendezvousError.rendezvousNotFound
        case 409:
            throw ClipNativeRendezvousError.hostOffline
        default:
            throw ClipNativeRendezvousError.rejected(statusCode: result.statusCode)
        }
    }

    public func stopSession(
        for owner: ClipNativeRendezvousOwner,
        capabilities: ClipNativeRendezvousCapabilities
    ) async throws {
        let url = try capabilities.sessionURL(for: owner.target)
        var request = baseRequest(url: url, method: "DELETE")
        request.setValue(
            owner.authorizationHeaderValue,
            forHTTPHeaderField: "Authorization"
        )
        let result = try await execute(request)
        guard result.statusCode == 204 || result.statusCode == 404 else {
            throw ClipNativeRendezvousError.rejected(statusCode: result.statusCode)
        }
    }

    public func delete(
        _ owner: ClipNativeRendezvousOwner,
        capabilities: ClipNativeRendezvousCapabilities
    ) async throws {
        let url = try capabilities.rendezvousURL(for: owner.target)
        var request = baseRequest(url: url, method: "DELETE")
        request.setValue(
            owner.authorizationHeaderValue,
            forHTTPHeaderField: "Authorization"
        )
        let result = try await execute(request)
        guard result.statusCode == 204 || result.statusCode == 404 else {
            throw ClipNativeRendezvousError.rejected(statusCode: result.statusCode)
        }
    }

    private func execute(_ request: URLRequest) async throws -> ClipLiveShareHTTPResult {
        let result: ClipLiveShareHTTPResult
        do {
            result = try await transport.execute(request)
        } catch let error as ClipNativeRendezvousError {
            throw error
        } catch let error as ClipLiveShareNetworkError {
            switch error {
            case .responseTooLarge:
                throw ClipNativeRendezvousError.responseTooLarge
            default:
                throw ClipNativeRendezvousError.connectionFailed
            }
        } catch {
            throw ClipNativeRendezvousError.connectionFailed
        }
        guard result.data.count <= ClipNativeRendezvousLimits.maximumHTTPResponseBytes else {
            throw ClipNativeRendezvousError.responseTooLarge
        }
        return result
    }

    private func baseRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    private func strictDecode<T: Decodable>(
        _ data: Data,
        allowedKeys: Set<String>
    ) throws -> T {
        guard !data.isEmpty,
              data.count <= ClipNativeRendezvousLimits.maximumHTTPResponseBytes,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys).isSubset(of: allowedKeys)
        else { throw ClipNativeRendezvousError.invalidResponse }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClipNativeRendezvousError.invalidResponse
        }
    }
}

private struct CapabilitiesResponse: Decodable {
    let protocolIdentifier: String
    let apiVersion: Int
    let messageVersion: Int
    let serverVersion: String
    let rendezvousPathTemplate: String
    let hostWebSocketPathTemplate: String
    let viewerWebSocketPathTemplate: String
    let maximumMessageBytes: Int
    let maximumDescriptorBytes: Int
    let maximumOpaquePayloadBytes: Int
    let maximumPendingRoutes: Int
    let maximumRendezvous: Int

    enum CodingKeys: String, CodingKey {
        case protocolIdentifier = "protocol"
        case apiVersion
        case messageVersion
        case serverVersion
        case rendezvousPathTemplate
        case hostWebSocketPathTemplate
        case viewerWebSocketPathTemplate
        case maximumMessageBytes
        case maximumDescriptorBytes
        case maximumOpaquePayloadBytes
        case maximumPendingRoutes
        case maximumRendezvous
    }
}

private struct OwnerRequest: Encodable {
    let ownerToken: String
}

private struct SessionRequest: Encodable {
    let descriptor: String
}

private struct LeaseResponse: Decodable {
    let rendezvousID: String
    let leaseDurationSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case rendezvousID = "rendezvousId"
        case leaseDurationSeconds
    }
}

private struct StatusResponse: Decodable {
    let rendezvousID: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case rendezvousID = "rendezvousId"
        case state
    }
}
