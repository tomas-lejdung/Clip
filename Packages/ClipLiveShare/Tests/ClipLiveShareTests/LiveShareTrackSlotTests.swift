import Testing
@testable import ClipLiveShare

@Suite("Stable GoPeep track slots")
struct LiveShareTrackSlotTests {
    @Test("surviving sources never change track identity")
    func stableAfterRemoval() throws {
        var selection = LiveShareSourceSelection.empty
        var allocation = LiveShareTrackSlotAllocation()
        let one = window(1)
        let two = window(2)
        try allocation.apply(selection.adding(.window(one)))
        selection = selection.adding(.window(one)).selection
        let addTwo = selection.adding(.window(two))
        try allocation.apply(addTwo)
        selection = addTwo.selection

        #expect(allocation.slot(for: .window(one.id))?.trackID == "video0")
        #expect(allocation.slot(for: .window(two.id))?.trackID == "video1")

        try allocation.apply(selection.removing(.window(one.id)))
        #expect(allocation.slot(for: .window(two.id))?.trackID == "video1")
    }

    @Test("fullscreen clears windows and always occupies video zero")
    func fullscreen() throws {
        var selection = LiveShareSourceSelection.empty
        var allocation = LiveShareTrackSlotAllocation()
        let add = selection.adding(.window(window(1)))
        try allocation.apply(add)
        selection = add.selection

        let display = LiveShareDisplaySource(
            id: LiveShareDisplayID(rawValue: 7),
            displayName: "Studio Display"
        )
        let fullscreen = selection.adding(.fullscreen(display))
        try allocation.apply(fullscreen)

        #expect(allocation.activeSlots.count == 1)
        #expect(allocation.activeSlots.first?.trackID == "video0")
        #expect(allocation.activeSlots.first?.source?.id == .fullscreen(display.id))
    }

    @Test("focus is unique and falls back to an active source")
    func focus() throws {
        var selection = LiveShareSourceSelection.empty
        var allocation = LiveShareTrackSlotAllocation()
        for id in 1 ... 2 {
            let change = selection.adding(.window(window(UInt32(id))))
            try allocation.apply(change)
            selection = change.selection
        }

        allocation.focus(.window(LiveShareWindowID(rawValue: 2)))
        #expect(allocation.activeSlots.filter(\.isFocused).map(\.trackID) == ["video1"])

        allocation.focus(nil)
        #expect(allocation.activeSlots.filter(\.isFocused).count == 1)
    }

    private func window(_ id: UInt32) -> LiveShareWindowSource {
        LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: id),
            windowName: "Window \(id)",
            appName: "Fixture"
        )
    }
}
