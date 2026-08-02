import Foundation
import Testing

@Suite("Clean-slate WebRTC source inventory")
struct CleanSlateWebRTCSourceInventoryTests {
  @Test("removed connection implementations cannot return to the package")
  func excludesRemovedConnectionImplementations() throws {
    let sourceDirectory = packageRoot()
      .appending(path: "Sources/ClipLiveShareWebRTC", directoryHint: .isDirectory)
    let sourceFiles = try swiftFiles(in: sourceDirectory)

    let removedFileNames: Set<String> = [
      "ClipLiveShareNativeFriendViewerSession.swift",
      "ClipLiveShareNativeV3PeerNegotiationHandoff.swift",
      "ClipLiveShareSignalingTransport.swift",
      "ClipLiveShareV1ViewerSession.swift",
      "ClipNativeRendezvousCandidateTransport.swift",
      "ClipNativeRendezvousHTTPClient.swift",
      "ClipNativeRendezvousNetwork.swift",
      "ClipNativeRendezvousOwnerTransport.swift",
      "ClipNativeRendezvousProtocol.swift",
      "ClipNativeRendezvousTransportSupport.swift",
      "RemoteStreamRegistry.swift",
      "WebRTCInboundStatistics.swift",
      "WebRTCOutboundStatistics.swift",
      "WebRTCPeerBandwidthEnvelope.swift",
      "WebRTCPeerHost.swift",
      "WebRTCPeerHostModels.swift",
      "WebRTCPeerViewer.swift",
      "WebRTCPeerViewerModels.swift",
    ]
    #expect(Set(sourceFiles.map(\.lastPathComponent)).isDisjoint(with: removedFileNames))

    let removedSymbols = [
      "ClipLiveShareNativeFriendViewerSession",
      "ClipLiveShareNativeV3PeerNegotiationHandoff",
      "ClipLiveShareSignalingTransport",
      "ClipLiveShareV1ViewerSession",
      "RemoteStreamRegistry",
      "WebRTCPeerBandwidthEnvelope",
      "WebRTCPeerHost",
      "WebRTCPeerViewer",
      "ClipNativeRendezvousHostTransport",
      "ClipNativeRendezvousViewerTransport",
      "ClipNativeRendezvousCandidateTransport",
      "ClipNativeRendezvousHTTPClient",
      "ClipNativeRendezvousOwnerTransport",
      "ClipNativeRendezvousSerializedSocket",
      "ClipNativeRendezvousTarget",
      "hostPreparing",
      "hostActive",
      "The friend is not currently sharing.",
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

  @Test("removed rendezvous protocols cannot return to production sources")
  func excludesRemovedRendezvousWireVocabulary() throws {
    let repository = repositoryRoot()
    let activeRoots = [
      packageRoot()
        .appending(path: "Sources/ClipLiveShareWebRTC", directoryHint: .isDirectory),
      repository.appending(path: "server/cmd", directoryHint: .isDirectory),
      repository.appending(path: "server/internal", directoryHint: .isDirectory),
    ]
    let activeFiles = try activeRoots.flatMap {
      try sourceFiles(in: $0, extensions: ["go", "swift"])
        .filter { !$0.lastPathComponent.hasSuffix("_test.go") }
    }

    let removedVocabulary = [
      "/api/native/v1",
      "/api/native/v3/rendezvous",
      "hostWebSocketPathTemplate",
      "viewerWebSocketPathTemplate",
      "ownerWebSocketPathTemplate",
      "candidateWebSocketPathTemplate",
      "HostWebSocketPathTemplate",
      "ViewerWebSocketPathTemplate",
      "native-host-unavailable",
      "ClipNativeRendezvousHostTransport",
      "ClipNativeRendezvousViewerTransport",
      "ClipNativeRendezvousCandidateTransport",
      "ClipNativeRendezvousOwnerTransport",
      "ClipNativeRendezvousHTTPClient",
      "MessageNativeHostUnavailable",
      "ErrNativeHostUnavailable",
      "ErrStaleHost",
      "ErrStaleViewer",
      "RelayFromHost",
      "RelayFromViewer",
      "AttachHost",
      "DetachHost",
      "RenewHost",
      "CloseRouteFromHost",
      "CloseViewerRoute",
      "closeNativeViewers",
      "nativeHostWebSocket",
      "nativeViewerWebSocket",
    ]
    for activeFile in activeFiles {
      #expect(
        FileManager.default.fileExists(atPath: activeFile.path),
        "Expected active rendezvous file \(activeFile.path)"
      )
      let contents = try String(contentsOf: activeFile, encoding: .utf8)
      for removedTerm in removedVocabulary {
        #expect(
          !contents.contains(removedTerm),
          "Legacy rendezvous term \(removedTerm) returned in \(activeFile.path)"
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

  private func repositoryRoot() -> URL {
    packageRoot()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func swiftFiles(in directory: URL) throws -> [URL] {
    try sourceFiles(in: directory, extensions: ["swift"])
  }

  private func sourceFiles(
    in directory: URL,
    extensions: Set<String>
  ) throws -> [URL] {
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
      guard
        let url = element as? URL,
        extensions.contains(url.pathExtension)
      else {
        return nil
      }
      return try url.resourceValues(forKeys: Set(keys)).isRegularFile == true
        ? url
        : nil
    }
  }
}
