import ClipLiveShare
import Foundation
import Testing

@testable import ClipLiveShareWebRTC

@Suite("Clip server-room v4 friend-presence HTTP")
struct ClipLiveShareServerRoomV4FriendPresenceHTTPTests {
  @Test("publish and fetch expose only the directional route and opaque record")
  func publishAndFetch() async throws {
    let endpoint = URL(string: "https://room.example.test")!
    let routingID = try ClipLiveShareServerRoomV4FriendRoutingID(
      bytes: Data(repeating: 0x31, count: 32)
    )
    let encrypted = try ClipLiveShareServerRoomV4EncryptedFriendPresence(
      routingID: routingID,
      revision: 7,
      expiresAtMilliseconds: 2_000_000_120_000,
      ciphertext: Data(repeating: 0x32, count: 256)
    )
    let record = ClipLiveShareServerRoomV4FriendPresenceRecord(
      encryptedPresence: encrypted
    )
    let response = try JSONEncoder().encode(record)
    let transport = FriendPresenceTestHTTPTransport { request, index in
      #expect(
        request.url?.path
          == "/api/native/v4/friends/\(routingID.rawValue)/presence"
      )
      switch index {
      case 0:
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let root = try #require(
          JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(Set(root.keys) == ["revision", "expiresAtMilliseconds", "payload"])
        #expect(root["revision"] as? Int == 7)
        #expect(!String(decoding: body, as: UTF8.self).contains("identity"))
        return .init(statusCode: 201, data: Data())
      case 1:
        #expect(request.httpMethod == "GET")
        return .init(statusCode: 200, data: response)
      case 2:
        #expect(request.httpMethod == "GET")
        return .init(statusCode: 404, data: Data())
      default:
        Issue.record("Unexpected presence HTTP request \(index)")
        return .init(statusCode: 500, data: Data())
      }
    }
    let client = ClipLiveShareServerRoomV4HTTPClient(transport: transport)

    try await client.publishFriendPresence(
      at: endpoint,
      encryptedPresence: encrypted
    )
    #expect(
      try await client.friendPresence(at: endpoint, routingID: routingID)
        == encrypted
    )
    #expect(
      try await client.friendPresence(at: endpoint, routingID: routingID) == nil
    )
  }

  @Test("revision conflicts and malformed service records fail closed")
  func failures() async throws {
    let endpoint = URL(string: "https://room.example.test")!
    let routingID = try ClipLiveShareServerRoomV4FriendRoutingID(
      bytes: Data(repeating: 0x41, count: 32)
    )
    let encrypted = try ClipLiveShareServerRoomV4EncryptedFriendPresence(
      routingID: routingID,
      revision: 3,
      expiresAtMilliseconds: 2_000_000_120_000,
      ciphertext: Data(repeating: 0x42, count: 128)
    )
    let conflict = ClipLiveShareServerRoomV4HTTPClient(
      transport: FriendPresenceTestHTTPTransport { _, _ in
        .init(
          statusCode: 409,
          data: Data("{\"error\":\"presence_revision_conflict\"}".utf8)
        )
      }
    )
    await #expect(
      throws: ClipLiveShareServerRoomV4TransportError
        .friendPresenceRevisionConflict
    ) {
      try await conflict.publishFriendPresence(
        at: endpoint,
        encryptedPresence: encrypted
      )
    }

    let malformed = ClipLiveShareServerRoomV4HTTPClient(
      transport: FriendPresenceTestHTTPTransport { _, _ in
        .init(
          statusCode: 200,
          data: Data(
            ("{\"revision\":3,\"expiresAtMilliseconds\":2000000120000,"
              + "\"payload\":\"not!base64\",\"identity\":\"leak\"}").utf8
          )
        )
      }
    )
    await #expect(throws: ClipLiveShareServerRoomV4TransportError.invalidResponse) {
      try await malformed.friendPresence(at: endpoint, routingID: routingID)
    }
  }
}

private actor FriendPresenceTestHTTPTransport: ClipLiveShareHTTPTransport {
  typealias Handler = @Sendable (
    URLRequest,
    Int
  ) async throws -> ClipLiveShareHTTPResult

  private let handler: Handler
  private var requestCount = 0

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func execute(_ request: URLRequest) async throws -> ClipLiveShareHTTPResult {
    let index = requestCount
    requestCount += 1
    return try await handler(request, index)
  }
}
