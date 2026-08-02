import Foundation

/// Creator-side body for `PUT /api/native/v4/rooms/{room}`. This exact shape mirrors
/// the Go service; the owner capability is used only to authenticate room
/// lifecycle requests and is never placed in an invite URL.
public struct ClipLiveShareServerRoomV4CreateRequest: Codable, Equatable,
  Sendable
{
  public let ownerToken: ClipLiveShareServerRoomV4OwnerCapability
  public let creatorHandle: ClipLiveShareServerRoomV4MemberHandle
  public let descriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord

  public init(
    ownerToken: ClipLiveShareServerRoomV4OwnerCapability,
    creatorHandle: ClipLiveShareServerRoomV4MemberHandle,
    descriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
  ) {
    self.ownerToken = ownerToken
    self.creatorHandle = creatorHandle
    self.descriptor = descriptor
  }
}

public struct ClipLiveShareServerRoomV4CreateResponse: Codable, Equatable,
  Sendable
{
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let creatorHandle: ClipLiveShareServerRoomV4MemberHandle
  public let leaseDurationSeconds: Int64

  public init(
    roomID: ClipLiveShareServerRoomV4RoomID,
    creatorHandle: ClipLiveShareServerRoomV4MemberHandle,
    leaseDurationSeconds: Int64
  ) throws {
    guard leaseDurationSeconds > 0 else {
      throw ClipLiveShareServerRoomV4Error.invalidWireMessage("lease duration")
    }
    self.roomID = roomID
    self.creatorHandle = creatorHandle
    self.leaseDurationSeconds = leaseDurationSeconds
  }

  enum CodingKeys: String, CodingKey {
    case roomID = "roomId"
    case creatorHandle
    case leaseDurationSeconds
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      roomID: container.decode(ClipLiveShareServerRoomV4RoomID.self, forKey: .roomID),
      creatorHandle: container.decode(
        ClipLiveShareServerRoomV4MemberHandle.self,
        forKey: .creatorHandle
      ),
      leaseDurationSeconds: container.decode(Int64.self, forKey: .leaseDurationSeconds)
    )
  }
}
