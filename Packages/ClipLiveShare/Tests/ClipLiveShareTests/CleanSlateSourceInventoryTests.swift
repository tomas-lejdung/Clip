import Foundation
import Testing

@Suite("Clean-slate protocol source inventory")
struct CleanSlateSourceInventoryTests {
  @Test("removed connection generations cannot return to the package")
  func excludesRemovedConnectionGenerations() throws {
    let sourceDirectory = packageRoot()
      .appending(path: "Sources/ClipLiveShare", directoryHint: .isDirectory)
    let sourceFiles = try swiftFiles(in: sourceDirectory)

    let removedFileNames: Set<String> = [
      "ClipLiveShareCrypto.swift",
      "ClipLiveShareInnerMessages.swift",
      "ClipLiveShareNativeV2Crypto.swift",
      "ClipLiveShareNativeV2Friends.swift",
      "ClipLiveShareNativeV2Primitives.swift",
      "ClipLiveShareNativeV2Streams.swift",
      "ClipLiveShareOuterMessages.swift",
      "ClipLiveShareProtocolPrimitives.swift",
      "ClipLiveShareServerProtocol.swift",
      "LiveShareStateMachine.swift",
      "LiveShareTrackSlots.swift",
    ]
    #expect(Set(sourceFiles.map(\.lastPathComponent)).isDisjoint(with: removedFileNames))

    let removedSymbols = [
      "ClipLiveShareV1",
      "ClipLiveShareNativeV2",
      "ClipLiveShareJoinCapability",
      "ClipLiveShareRoomName",
      "clip-live-share-v1/",
      "clip-live-share-native-v2/",
    ]
    for sourceFile in sourceFiles {
      let contents = try String(contentsOf: sourceFile, encoding: .utf8)
      for removedSymbol in removedSymbols {
        #expect(
          !contents.contains(removedSymbol),
          "Removed connection symbol \(removedSymbol) returned in \(sourceFile.lastPathComponent)"
        )
      }
    }
  }

  private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func swiftFiles(in directory: URL) throws -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: keys
      )
    else {
      Issue.record("Could not enumerate \(directory.path)")
      return []
    }
    return try enumerator.compactMap { element in
      guard let url = element as? URL, url.pathExtension == "swift" else {
        return nil
      }
      return try url.resourceValues(forKeys: Set(keys)).isRegularFile == true
        ? url
        : nil
    }
  }
}
