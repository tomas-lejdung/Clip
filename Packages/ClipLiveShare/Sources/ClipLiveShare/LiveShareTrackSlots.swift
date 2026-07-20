import Foundation

public struct LiveShareTrackSlot: Equatable, Hashable, Sendable, Identifiable {
    public let index: Int
    public var source: LiveShareSource?
    public var isFocused: Bool

    public init(index: Int, source: LiveShareSource? = nil, isFocused: Bool = false) {
        self.index = index
        self.source = source
        self.isFocused = source == nil ? false : isFocused
    }

    public var id: Int { index }
    public var trackID: String { "video\(index)" }
    public var streamID: String { "gopeep-stream-\(index)" }
    public var isActive: Bool { source != nil }
}

public enum LiveShareTrackSlotError: Error, Equatable, Sendable {
    case invalidSlotCount(Int)
    case sourceCapacityExceeded
    case fullscreenRequiresSlotZero
}

/// Stable assignment of source identity to GoPeep's four pre-negotiated tracks.
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
                slots = (0 ..< Self.slotCount).map { LiveShareTrackSlot(index: $0) }
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
        self = Self()
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
