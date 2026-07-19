import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Live-share source policy")
struct LiveShareSourcePolicyTests {
  @Test("An empty selection contains no source")
  func emptySelection() {
    #expect(LiveShareSourceSelection.empty.isEmpty)
    #expect(LiveShareSourceSelection.empty.sources.isEmpty)
  }

  @Test("Up to four windows preserve deterministic selection order")
  func fourWindows() {
    var selection = LiveShareSourceSelection.empty
    for id: UInt32 in 1...4 {
      selection = selection.adding(.window(makeWindow(id))).selection
    }
    #expect(selection.windows.map(\.id.rawValue) == [1, 2, 3, 4])
    #expect(selection.fullscreen == nil)
  }

  @Test("A fifth window evicts the least-recently added window")
  func fifthWindowEvictsOldest() {
    var selection = LiveShareSourceSelection.empty
    for id: UInt32 in 1...4 {
      selection = selection.adding(.window(makeWindow(id))).selection
    }

    let change = selection.adding(.window(makeWindow(5)))
    #expect(change.changed)
    #expect(change.selection.windows.map(\.id.rawValue) == [2, 3, 4, 5])
    #expect(change.added == [.window(makeWindow(5))])
    #expect(change.removed == [.window(makeWindow(1))])
  }

  @Test("Focus recency changes which window is evicted")
  func focusedWindowBecomesMostRecent() {
    var selection = try! LiveShareSourceSelection(
      windows: [makeWindow(1), makeWindow(2), makeWindow(3), makeWindow(4)]
    )
    selection = selection.markingWindowAsMostRecentlyUsed(makeWindow(1).id).selection
    #expect(selection.windows.map(\.id.rawValue) == [2, 3, 4, 1])

    let change = selection.adding(.window(makeWindow(5)))
    #expect(change.selection.windows.map(\.id.rawValue) == [3, 4, 1, 5])
    #expect(change.removed == [.window(makeWindow(2))])
  }

  @Test("Selecting fullscreen removes every selected window")
  func fullscreenClearsWindows() {
    let windows = try! LiveShareSourceSelection(windows: [makeWindow(1), makeWindow(2)])
    let display = makeDisplay(7)
    let change = windows.adding(.fullscreen(display))

    #expect(change.selection.windows.isEmpty)
    #expect(change.selection.fullscreen == display)
    #expect(change.removed == [.window(makeWindow(1)), .window(makeWindow(2))])
    #expect(change.added == [.fullscreen(display)])
  }

  @Test("Selecting a window exits fullscreen")
  func windowClearsFullscreen() {
    let display = makeDisplay(2)
    let fullscreen = try! LiveShareSourceSelection(fullscreen: display)
    let window = makeWindow(11)
    let change = fullscreen.adding(.window(window))

    #expect(change.selection.fullscreen == nil)
    #expect(change.selection.windows == [window])
    #expect(change.removed == [.fullscreen(display)])
    #expect(change.added == [.window(window)])
  }

  @Test("Adding an existing source refreshes metadata without duplicating it")
  func duplicateRefreshesMetadata() {
    let original = makeWindow(9, app: "Old Name")
    let refreshed = makeWindow(9, app: "New Name")
    let selection = try! LiveShareSourceSelection(windows: [original])
    let change = selection.adding(.window(refreshed))

    #expect(change.selection.windows == [refreshed])
    #expect(change.added.isEmpty)
    #expect(change.removed.isEmpty)
    #expect(change.changed)
  }

  @Test("Toggle, remove, and clear are idempotent")
  func removalOperations() {
    let window = makeWindow(3)
    var selection = LiveShareSourceSelection.empty
    selection = selection.toggling(.window(window)).selection
    #expect(selection.contains(.window(window.id)))
    selection = selection.toggling(.window(window)).selection
    #expect(selection.isEmpty)

    let missingRemoval = selection.removing(.window(window.id))
    #expect(!missingRemoval.changed)

    selection = selection.adding(.window(window)).selection
    #expect(selection.clearing().selection.isEmpty)
  }

  @Test("Constructed and decoded selections enforce all invariants")
  func invariantValidation() throws {
    let fiveWindows = (1...5).map { makeWindow(UInt32($0)) }
    #expect(
      throws: LiveShareSourcePolicyError.tooManyWindows(maximum: 4, actual: 5)
    ) {
      try LiveShareSourceSelection(windows: fiveWindows)
    }
    #expect(throws: LiveShareSourcePolicyError.fullscreenCannotCoexistWithWindows) {
      try LiveShareSourceSelection(windows: [makeWindow(1)], fullscreen: makeDisplay())
    }
    #expect(throws: LiveShareSourcePolicyError.duplicateWindow(makeWindow(1).id)) {
      try LiveShareSourceSelection(windows: [makeWindow(1), makeWindow(1)])
    }

    let invalidJSON = try JSONEncoder().encode(
      InvalidSelectionFixture(windows: fiveWindows, fullscreen: nil)
    )
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(LiveShareSourceSelection.self, from: invalidJSON)
    }
  }

  @Test("Valid source selections are Codable")
  func codableRoundTrip() throws {
    let selection = try LiveShareSourceSelection(
      windows: [makeWindow(4), makeWindow(8)]
    )
    let decoded = try JSONDecoder().decode(
      LiveShareSourceSelection.self,
      from: JSONEncoder().encode(selection)
    )
    #expect(decoded == selection)
  }
}

private struct InvalidSelectionFixture: Encodable {
  let windows: [LiveShareWindowSource]
  let fullscreen: LiveShareDisplaySource?
}
