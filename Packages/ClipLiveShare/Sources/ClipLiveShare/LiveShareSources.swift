import Foundation

public struct LiveShareWindowID: RawRepresentable, Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public var description: String { String(rawValue) }
}

public struct LiveShareDisplayID: RawRepresentable, Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public var description: String { String(rawValue) }
}

public struct LiveShareWindowSource: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let id: LiveShareWindowID
  public let windowName: String
  public let appName: String

  public init(id: LiveShareWindowID, windowName: String, appName: String) {
    self.id = id
    self.windowName = windowName
    self.appName = appName
  }
}

public struct LiveShareDisplaySource: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let id: LiveShareDisplayID
  public let displayName: String

  public init(id: LiveShareDisplayID, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

public enum LiveShareSourceID: Codable, Equatable, Hashable, Sendable {
  case window(LiveShareWindowID)
  case fullscreen(LiveShareDisplayID)
}

public enum LiveShareSource: Codable, Equatable, Hashable, Sendable, Identifiable {
  case window(LiveShareWindowSource)
  case fullscreen(LiveShareDisplaySource)

  public var id: LiveShareSourceID {
    switch self {
    case .window(let window): .window(window.id)
    case .fullscreen(let display): .fullscreen(display.id)
    }
  }
}

public enum LiveShareSourcePolicyError: Error, Equatable, Sendable {
  case tooManyWindows(maximum: Int, actual: Int)
  case fullscreenCannotCoexistWithWindows
  case duplicateWindow(LiveShareWindowID)
}

/// GoPeep's source policy represented as an immutable value.
///
/// Windows are ordered from least to most recently added. Adding a fifth window
/// evicts the first one, matching GoPeep's four-source LRU behavior. Fullscreen is
/// mutually exclusive with every window source.
public struct LiveShareSourceSelection: Codable, Equatable, Hashable, Sendable {
  public static let maximumWindowCount = 4
  public static let empty = try! Self()

  public let windows: [LiveShareWindowSource]
  public let fullscreen: LiveShareDisplaySource?

  public init(
    windows: [LiveShareWindowSource] = [],
    fullscreen: LiveShareDisplaySource? = nil
  ) throws {
    guard windows.count <= Self.maximumWindowCount else {
      throw LiveShareSourcePolicyError.tooManyWindows(
        maximum: Self.maximumWindowCount,
        actual: windows.count
      )
    }
    guard fullscreen == nil || windows.isEmpty else {
      throw LiveShareSourcePolicyError.fullscreenCannotCoexistWithWindows
    }

    var seen = Set<LiveShareWindowID>()
    for window in windows where !seen.insert(window.id).inserted {
      throw LiveShareSourcePolicyError.duplicateWindow(window.id)
    }

    self.windows = windows
    self.fullscreen = fullscreen
  }

  public var sources: [LiveShareSource] {
    if let fullscreen {
      return [.fullscreen(fullscreen)]
    }
    return windows.map(LiveShareSource.window)
  }

  public var isEmpty: Bool { windows.isEmpty && fullscreen == nil }

  public func contains(_ id: LiveShareSourceID) -> Bool {
    switch id {
    case .window(let windowID): windows.contains { $0.id == windowID }
    case .fullscreen(let displayID): fullscreen?.id == displayID
    }
  }

  public func adding(_ source: LiveShareSource) -> LiveShareSourceChange {
    let next: Self
    switch source {
    case .fullscreen(let display):
      next = try! Self(fullscreen: display)

    case .window(let window):
      var nextWindows = windows
      if let existingIndex = nextWindows.firstIndex(where: { $0.id == window.id }) {
        nextWindows[existingIndex] = window
      } else {
        if nextWindows.count == Self.maximumWindowCount {
          nextWindows.removeFirst()
        }
        nextWindows.append(window)
      }
      next = try! Self(windows: nextWindows)
    }
    return Self.change(from: self, to: next)
  }

  public func removing(_ id: LiveShareSourceID) -> LiveShareSourceChange {
    let next: Self
    switch id {
    case .window(let windowID):
      next = try! Self(windows: windows.filter { $0.id != windowID })
    case .fullscreen(let displayID):
      next = fullscreen?.id == displayID ? .empty : self
    }
    return Self.change(from: self, to: next)
  }

  public func toggling(_ source: LiveShareSource) -> LiveShareSourceChange {
    contains(source.id) ? removing(source.id) : adding(source)
  }

  /// Moves a selected window to the most-recently-used end of the list.
  /// Calling this for a missing window or while fullscreen is selected is a no-op.
  public func markingWindowAsMostRecentlyUsed(
    _ id: LiveShareWindowID
  ) -> LiveShareSourceChange {
    guard let index = windows.firstIndex(where: { $0.id == id }),
      index != windows.index(before: windows.endIndex)
    else {
      return Self.change(from: self, to: self)
    }
    var reordered = windows
    let window = reordered.remove(at: index)
    reordered.append(window)
    return Self.change(from: self, to: try! Self(windows: reordered))
  }

  public func clearing() -> LiveShareSourceChange {
    Self.change(from: self, to: .empty)
  }

  private static func change(from previous: Self, to selection: Self) -> LiveShareSourceChange {
    let previousByID = Dictionary(uniqueKeysWithValues: previous.sources.map { ($0.id, $0) })
    let nextByID = Dictionary(uniqueKeysWithValues: selection.sources.map { ($0.id, $0) })
    return LiveShareSourceChange(
      previous: previous,
      selection: selection,
      added: selection.sources.filter { previousByID[$0.id] == nil },
      removed: previous.sources.filter { nextByID[$0.id] == nil }
    )
  }

  private enum CodingKeys: CodingKey {
    case windows
    case fullscreen
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let windows =
      try container.decodeIfPresent(
        [LiveShareWindowSource].self,
        forKey: .windows
      ) ?? []
    let fullscreen = try container.decodeIfPresent(
      LiveShareDisplaySource.self,
      forKey: .fullscreen
    )
    do {
      try self.init(windows: windows, fullscreen: fullscreen)
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .windows,
        in: container,
        debugDescription: "Decoded live-share sources violate the source policy."
      )
    }
  }
}

public struct LiveShareSourceChange: Equatable, Hashable, Sendable {
  public let previous: LiveShareSourceSelection
  public let selection: LiveShareSourceSelection
  public let added: [LiveShareSource]
  public let removed: [LiveShareSource]

  public var changed: Bool { previous != selection }
}
