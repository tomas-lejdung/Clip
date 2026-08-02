import Foundation

/// Correlates a recoverable service-side routing error with exactly one
/// direct participant edge. Room/authentication errors intentionally omit
/// this value because they apply to the whole control-plane session.
public struct ClipLiveShareServerRoomV4ProtocolErrorPair:
  Equatable, Sendable
{
  public let pairID: ClipLiveShareServerRoomV4PairID
  public let remoteHandle: ClipLiveShareServerRoomV4MemberHandle
  public let sequence: UInt64

  public init(
    pairID: ClipLiveShareServerRoomV4PairID,
    remoteHandle: ClipLiveShareServerRoomV4MemberHandle,
    sequence: UInt64
  ) throws {
    guard sequence > 0 else {
      throw ClipLiveShareProtocolError.invalidSequence(
        expected: 1,
        actual: sequence
      )
    }
    self.pairID = pairID
    self.remoteHandle = remoteHandle
    self.sequence = sequence
  }
}

/// Byte-for-byte mirror of the Go room service's flat v4 envelope. Omitted
/// fields are direction-sensitive: the authenticated service fills candidate
/// and sender handles before forwarding to another client.
public enum ClipLiveShareServerRoomV4WireMessage: Equatable, Sendable {
  case candidateOpened(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle,
    roomDescriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
  )
  case joinKnock(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle?,
    sequence: UInt64,
    payload: ClipLiveShareServerRoomV4OpaqueJoinKnock
  )
  case admitCandidate(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle,
    descriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
  )
  case denyCandidate(
    candidateHandle: ClipLiveShareServerRoomV4CandidateHandle?,
    reason: String
  )
  case memberAdmitted(
    memberHandle: ClipLiveShareServerRoomV4MemberHandle,
    reconnectCapability: ClipLiveShareServerRoomV4ReconnectCapability?,
    roster: ClipLiveShareServerRoomV4RosterSnapshot
  )
  case rosterSnapshot(ClipLiveShareServerRoomV4RosterSnapshot)
  case pairSignal(ClipLiveShareServerRoomV4PairSignalEnvelope)
  case leaveRoom
  case removeMember(ClipLiveShareServerRoomV4MemberHandle)
  case roomEnded(reason: String)
  case protocolError(
    code: String,
    message: String,
    pair: ClipLiveShareServerRoomV4ProtocolErrorPair?
  )

  public var type: String {
    switch self {
    case .candidateOpened: "candidate-opened"
    case .joinKnock: "join-knock"
    case .admitCandidate: "admit-candidate"
    case .denyCandidate: "deny-candidate"
    case .memberAdmitted: "member-admitted"
    case .rosterSnapshot: "roster-snapshot"
    case .pairSignal: "pair-signal"
    case .leaveRoom: "leave-room"
    case .removeMember: "remove-member"
    case .roomEnded: "room-ended"
    case .protocolError: "protocol-error"
    }
  }
}

public enum ClipLiveShareServerRoomV4WireCodec {
  public static func encode(
    _ message: ClipLiveShareServerRoomV4WireMessage,
    maximumBytes: Int = ClipLiveShareServerRoomV4.maximumWireMessageBytes
  ) throws -> Data {
    let flat: FlatEnvelope
    switch message {
    case .candidateOpened(let candidateHandle, let descriptor):
      flat = .init(
        type: message.type,
        candidateHandle: candidateHandle.rawValue,
        roomDescriptor: descriptor.rawValue
      )
    case .joinKnock(let candidateHandle, let sequence, let payload):
      guard sequence > 0 else {
        throw ClipLiveShareProtocolError.invalidSequence(expected: 1, actual: sequence)
      }
      flat = .init(
        type: message.type,
        sequence: sequence,
        payload: payload.rawValue,
        candidateHandle: candidateHandle?.rawValue
      )
    case .admitCandidate(let candidateHandle, let descriptor):
      flat = .init(
        type: message.type,
        payload: descriptor.rawValue,
        candidateHandle: candidateHandle.rawValue
      )
    case .denyCandidate(let candidateHandle, let reason):
      try validateText(reason, name: "denial reason", maximum: 256, allowEmpty: true)
      flat = .init(
        type: message.type,
        reason: reason,
        candidateHandle: candidateHandle?.rawValue
      )
    case .memberAdmitted(let memberHandle, let reconnectCapability, let roster):
      flat = .init(
        type: message.type,
        memberHandle: memberHandle.rawValue,
        reconnectCapability: reconnectCapability?.rawValue,
        roster: roster
      )
    case .rosterSnapshot(let roster):
      flat = .init(type: message.type, roster: roster)
    case .pairSignal(let signal):
      flat = .init(
        type: message.type,
        sequence: signal.sequence,
        payload: ClipLiveShareBase64URL.encode(signal.ciphertext),
        from: signal.from?.rawValue,
        to: signal.to.rawValue,
        pairID: signal.pairID.rawValue
      )
    case .leaveRoom:
      flat = .init(type: message.type)
    case .removeMember(let handle):
      flat = .init(type: message.type, to: handle.rawValue)
    case .roomEnded(let reason):
      try validateText(reason, name: "room-ended reason", maximum: 256, allowEmpty: true)
      flat = .init(type: message.type, reason: reason)
    case .protocolError(let code, let text, let pair):
      try validateText(code, name: "protocol error code", maximum: 64, allowEmpty: false)
      try validateText(text, name: "protocol error text", maximum: 256, allowEmpty: true)
      flat = .init(
        type: message.type,
        sequence: pair?.sequence,
        code: code,
        message: text,
        to: pair?.remoteHandle.rawValue,
        pairID: pair?.pairID.rawValue
      )
    }
    let data = try serverRoomV4StrictEncode(flat, maximumBytes: maximumBytes)
    try validateExactShape(data, type: flat.type)
    return data
  }

  public static func decode(
    _ data: Data,
    maximumBytes: Int = ClipLiveShareServerRoomV4.maximumWireMessageBytes
  ) throws -> ClipLiveShareServerRoomV4WireMessage {
    try serverRoomV4ValidateSize(data, maximumBytes: maximumBytes)
    let flat: FlatEnvelope
    do {
      flat = try serverRoomV4StrictDecode(
        FlatEnvelope.self,
        from: data,
        maximumBytes: maximumBytes
      )
    } catch {
      throw ClipLiveShareServerRoomV4Error.invalidWireMessage("JSON envelope")
    }
    guard flat.version == ClipLiveShareServerRoomV4.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(flat.version)
    }
    try validateExactShape(data, type: flat.type)

    switch flat.type {
    case "candidate-opened":
      return .candidateOpened(
        candidateHandle: try candidate(flat.candidateHandle),
        roomDescriptor: try admission(flat.roomDescriptor)
      )
    case "join-knock":
      guard let sequence = flat.sequence, sequence > 0 else {
        throw ClipLiveShareServerRoomV4Error.invalidWireMessage("join sequence")
      }
      return .joinKnock(
        candidateHandle: try flat.candidateHandle.map {
          try ClipLiveShareServerRoomV4CandidateHandle(rawValue: $0)
        },
        sequence: sequence,
        payload: try knock(flat.payload)
      )
    case "admit-candidate":
      return .admitCandidate(
        candidateHandle: try candidate(flat.candidateHandle),
        descriptor: try admission(flat.payload)
      )
    case "deny-candidate":
      let reason = flat.reason ?? ""
      try validateText(reason, name: "denial reason", maximum: 256, allowEmpty: true)
      return .denyCandidate(
        candidateHandle: try flat.candidateHandle.map {
          try ClipLiveShareServerRoomV4CandidateHandle(rawValue: $0)
        },
        reason: reason
      )
    case "member-admitted":
      return .memberAdmitted(
        memberHandle: try member(flat.memberHandle),
        reconnectCapability: try flat.reconnectCapability.map {
          try ClipLiveShareServerRoomV4ReconnectCapability(rawValue: $0)
        },
        roster: try requireRoster(flat.roster)
      )
    case "roster-snapshot":
      return .rosterSnapshot(try requireRoster(flat.roster))
    case "pair-signal":
      guard let sequence = flat.sequence, sequence > 0,
        let payload = flat.payload,
        let ciphertext = ClipLiveShareBase64URL.decode(payload)
      else {
        throw ClipLiveShareServerRoomV4Error.invalidWireMessage("pair signal")
      }
      return .pairSignal(
        try .init(
          from: try flat.from.map {
            try ClipLiveShareServerRoomV4MemberHandle(rawValue: $0)
          },
          to: try member(flat.to),
          pairID: try .init(rawValue: required(flat.pairID, name: "pair ID")),
          sequence: sequence,
          ciphertext: ciphertext
        )
      )
    case "leave-room":
      return .leaveRoom
    case "remove-member":
      return .removeMember(try member(flat.to))
    case "room-ended":
      let reason = flat.reason ?? ""
      try validateText(reason, name: "room-ended reason", maximum: 256, allowEmpty: true)
      return .roomEnded(reason: reason)
    case "protocol-error":
      let code = try required(flat.code, name: "protocol error code")
      let text = flat.message ?? ""
      try validateText(code, name: "protocol error code", maximum: 64, allowEmpty: false)
      try validateText(text, name: "protocol error text", maximum: 256, allowEmpty: true)
      let pair: ClipLiveShareServerRoomV4ProtocolErrorPair?
      switch (flat.sequence, flat.to, flat.pairID) {
      case (nil, nil, nil):
        pair = nil
      case let (sequence?, remoteHandle?, pairID?) where sequence > 0:
        pair = try .init(
          pairID: .init(rawValue: pairID),
          remoteHandle: .init(rawValue: remoteHandle),
          sequence: sequence
        )
      default:
        throw ClipLiveShareServerRoomV4Error.invalidWireMessage(
          "protocol error pair context"
        )
      }
      return .protocolError(code: code, message: text, pair: pair)
    default:
      throw ClipLiveShareServerRoomV4Error.unknownWireMessage(flat.type)
    }
  }

  private static func validateExactShape(_ data: Data, type: String) throws {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ClipLiveShareServerRoomV4Error.invalidWireMessage("outer envelope")
    }
    let keys = Set(root.keys)
    let required: Set<String>
    let allowed: Set<String>
    switch type {
    case "candidate-opened":
      required = ["type", "version", "candidateHandle", "roomDescriptor"]
      allowed = required
    case "join-knock":
      required = ["type", "version", "sequence", "payload"]
      allowed = required.union(["candidateHandle"])
    case "admit-candidate":
      required = ["type", "version", "candidateHandle", "payload"]
      allowed = required
    case "deny-candidate":
      required = ["type", "version"]
      allowed = required.union(["candidateHandle", "reason"])
    case "member-admitted":
      required = ["type", "version", "memberHandle", "roster"]
      allowed = required.union(["reconnectCapability"])
    case "roster-snapshot":
      required = ["type", "version", "roster"]
      allowed = required
    case "pair-signal":
      required = ["type", "version", "sequence", "payload", "to", "pairId"]
      allowed = required.union(["from"])
    case "leave-room":
      required = ["type", "version"]
      allowed = required
    case "remove-member":
      required = ["type", "version", "to"]
      allowed = required
    case "room-ended":
      required = ["type", "version"]
      allowed = required.union(["reason"])
    case "protocol-error":
      required = ["type", "version", "code"]
      allowed = required.union(["message", "sequence", "to", "pairId"])
    default:
      // Unknown messages remain parseable enough to return a precise error.
      return
    }
    guard required.isSubset(of: keys), keys.isSubset(of: allowed) else {
      throw ClipLiveShareServerRoomV4Error.invalidWireMessage("fields for \(type)")
    }
    if let roster = root["roster"] as? [String: Any] {
      try validateRosterObject(roster)
    }
  }

  private static func validateRosterObject(_ roster: [String: Any]) throws {
    guard Set(roster.keys) == ["revision", "creatorHandle", "members"],
      let members = roster["members"] as? [[String: Any]],
      (1...ClipLiveShareServerRoomV4.maximumParticipants).contains(members.count)
    else {
      throw ClipLiveShareServerRoomV4Error.invalidWireMessage("roster shape")
    }
    for member in members {
      guard Set(member.keys) == ["handle", "descriptor", "connected"] else {
        throw ClipLiveShareServerRoomV4Error.invalidWireMessage("roster member shape")
      }
    }
  }

  private static func required(_ value: String?, name: String) throws -> String {
    guard let value, !value.isEmpty else {
      throw ClipLiveShareServerRoomV4Error.invalidWireMessage(name)
    }
    return value
  }
  private static func member(
    _ value: String?
  ) throws -> ClipLiveShareServerRoomV4MemberHandle {
    try .init(rawValue: required(value, name: "member handle"))
  }
  private static func candidate(
    _ value: String?
  ) throws -> ClipLiveShareServerRoomV4CandidateHandle {
    try .init(rawValue: required(value, name: "candidate handle"))
  }
  private static func admission(
    _ value: String?
  ) throws -> ClipLiveShareServerRoomV4OpaqueAdmissionRecord {
    let raw = try required(value, name: "descriptor")
    guard let data = ClipLiveShareBase64URL.decode(raw) else {
      throw ClipLiveShareServerRoomV4Error.invalidOpaqueValue("admission record")
    }
    return try .init(ciphertext: data)
  }
  private static func knock(
    _ value: String?
  ) throws -> ClipLiveShareServerRoomV4OpaqueJoinKnock {
    let raw = try required(value, name: "join payload")
    guard let data = ClipLiveShareBase64URL.decode(raw) else {
      throw ClipLiveShareServerRoomV4Error.invalidOpaqueValue("join knock")
    }
    return try .init(ciphertext: data)
  }
  private static func requireRoster(
    _ value: ClipLiveShareServerRoomV4RosterSnapshot?
  ) throws -> ClipLiveShareServerRoomV4RosterSnapshot {
    guard let value else {
      throw ClipLiveShareServerRoomV4Error.invalidWireMessage("roster")
    }
    return value
  }
  private static func validateText(
    _ value: String,
    name: String,
    maximum: Int,
    allowEmpty: Bool
  ) throws {
    guard allowEmpty || !value.isEmpty, value.utf8.count <= maximum else {
      throw ClipLiveShareServerRoomV4Error.invalidWireMessage(name)
    }
  }
}

private struct FlatEnvelope: Codable {
  let type: String
  let version: Int
  let sequence: UInt64?
  let payload: String?
  let reason: String?
  let code: String?
  let message: String?
  let candidateHandle: String?
  let memberHandle: String?
  let reconnectCapability: String?
  let roomDescriptor: String?
  let from: String?
  let to: String?
  let pairID: String?
  let roster: ClipLiveShareServerRoomV4RosterSnapshot?

  enum CodingKeys: String, CodingKey {
    case type
    case version
    case sequence
    case payload
    case reason
    case code
    case message
    case candidateHandle
    case memberHandle
    case reconnectCapability
    case roomDescriptor
    case from
    case to
    case pairID = "pairId"
    case roster
  }

  init(
    type: String,
    version: Int = ClipLiveShareServerRoomV4.version,
    sequence: UInt64? = nil,
    payload: String? = nil,
    reason: String? = nil,
    code: String? = nil,
    message: String? = nil,
    candidateHandle: String? = nil,
    memberHandle: String? = nil,
    reconnectCapability: String? = nil,
    roomDescriptor: String? = nil,
    from: String? = nil,
    to: String? = nil,
    pairID: String? = nil,
    roster: ClipLiveShareServerRoomV4RosterSnapshot? = nil
  ) {
    self.type = type
    self.version = version
    self.sequence = sequence
    self.payload = payload
    self.reason = reason
    self.code = code
    self.message = message
    self.candidateHandle = candidateHandle
    self.memberHandle = memberHandle
    self.reconnectCapability = reconnectCapability
    self.roomDescriptor = roomDescriptor
    self.from = from
    self.to = to
    self.pairID = pairID
    self.roster = roster
  }
}

func serverRoomV4StrictEncode<T: Encodable>(
  _ value: T,
  maximumBytes: Int
) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(value)
  try serverRoomV4ValidateSize(data, maximumBytes: maximumBytes)
  return data
}

func serverRoomV4StrictDecode<T: Decodable>(
  _ type: T.Type,
  from data: Data,
  maximumBytes: Int
) throws -> T {
  try serverRoomV4ValidateSize(data, maximumBytes: maximumBytes)
  return try JSONDecoder().decode(type, from: data)
}

func serverRoomV4ValidateSize(_ data: Data, maximumBytes: Int) throws {
  guard maximumBytes > 0 else {
    throw ClipLiveShareServerRoomV4Error.invalidWireMessage("size limit")
  }
  guard data.count <= maximumBytes else {
    throw ClipLiveShareProtocolError.messageTooLarge(maximum: maximumBytes, actual: data.count)
  }
}

func serverRoomV4RequireExactKeys(_ data: Data, expected: Set<String>) throws {
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    Set(object.keys) == expected
  else {
    throw ClipLiveShareServerRoomV4Error.invalidWireMessage("object keys")
  }
}
