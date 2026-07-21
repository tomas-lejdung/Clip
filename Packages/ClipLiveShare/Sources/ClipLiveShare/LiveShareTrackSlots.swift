import Foundation

public struct LiveShareTrackSlot: Equatable, Hashable, Sendable, Identifiable {
    public let index: Int
    public let streamIdentity: ClipLiveShareStreamID
    public var source: LiveShareSource?
    public var isFocused: Bool

    public init(
        index: Int,
        streamIdentity: ClipLiveShareStreamID = .random(),
        source: LiveShareSource? = nil,
        isFocused: Bool = false
    ) {
        self.index = index
        self.streamIdentity = streamIdentity
        self.source = source
        self.isFocused = source == nil ? false : isFocused
    }

    public var id: Int { index }
    /// Transitional alias for callers that previously used a deterministic transport track ID.
    public var trackID: String { streamIdentity.rawValue }
    /// Opaque protocol stream identity. Random for each Live Share session.
    public var streamID: String { streamIdentity.rawValue }
    public var isActive: Bool { source != nil }
}

public enum LiveShareTrackSlotError: Error, Equatable, Sendable {
    case invalidSlotCount(Int)
    case duplicateStreamIdentity
    case sourceCapacityExceeded
    case fullscreenRequiresSlotZero
}

/// Stable assignment of source identity to Clip's four pre-negotiated tracks.
/// Removing another source never renumbers a surviving track.
public struct LiveShareTrackSlotAllocation: Equatable, Hashable, Sendable {
    public static let slotCount = LiveShareSourceSelection.maximumWindowCount

    public private(set) var slots: [LiveShareTrackSlot]

    public init() {
        slots = (0 ..< Self.slotCount).map { LiveShareTrackSlot(index: $0) }
    }

    public init(slots: [LiveShareTrackSlot]) throws {
        guard slots.count == Self.slotCount,
              slots.map(\.index) == Array(0 ..< Self.slotCount) else {
            throw LiveShareTrackSlotError.invalidSlotCount(slots.count)
        }
        guard Set(slots.map(\.streamIdentity)).count == slots.count else {
            throw LiveShareTrackSlotError.duplicateStreamIdentity
        }
        if let fullscreenIndex = slots.firstIndex(where: { slot in
            guard case .fullscreen = slot.source else { return false }
            return true
        }), fullscreenIndex != 0 {
            throw LiveShareTrackSlotError.fullscreenRequiresSlotZero
        }
        self.slots = slots
        normalizeFocus()
    }

    public var activeSlots: [LiveShareTrackSlot] {
        slots.filter(\.isActive)
    }

    public func slot(for sourceID: LiveShareSourceID) -> LiveShareTrackSlot? {
        slots.first { $0.source?.id == sourceID }
    }

    @discardableResult
    public mutating func apply(_ change: LiveShareSourceChange) throws -> [LiveShareTrackSlot] {
        for removed in change.removed {
            if let index = slots.firstIndex(where: { $0.source?.id == removed.id }) {
                slots[index].source = nil
                slots[index].isFocused = false
            }
        }

        for source in change.added {
            if case .fullscreen = source {
                for index in slots.indices {
                    slots[index].source = nil
                    slots[index].isFocused = false
                }
                slots[0].source = source
                slots[0].isFocused = true
                continue
            }
            if let existing = slots.firstIndex(where: { $0.source?.id == source.id }) {
                slots[existing].source = source
                continue
            }
            guard let available = slots.firstIndex(where: { !$0.isActive }) else {
                throw LiveShareTrackSlotError.sourceCapacityExceeded
            }
            slots[available].source = source
        }
        normalizeFocus()
        return slots
    }

    public mutating func focus(_ sourceID: LiveShareSourceID?) {
        for index in slots.indices {
            slots[index].isFocused = sourceID != nil && slots[index].source?.id == sourceID
        }
        normalizeFocus()
    }

    public mutating func clear() {
        for index in slots.indices {
            slots[index].source = nil
            slots[index].isFocused = false
        }
    }

    private mutating func normalizeFocus() {
        guard let firstActive = slots.firstIndex(where: \.isActive) else {
            for index in slots.indices { slots[index].isFocused = false }
            return
        }
        let focused = slots.indices.filter { slots[$0].isActive && slots[$0].isFocused }
        let keeper = focused.first ?? firstActive
        for index in slots.indices {
            slots[index].isFocused = index == keeper
        }
    }
}
