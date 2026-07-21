import ClipLiveShare
import Testing
@testable import ClipLiveShareWebRTC

@Suite("Remote stream registry")
struct RemoteStreamRegistryTests {
    @Test("manifest before native track binds only when the track arrives")
    func manifestBeforeTrack() throws {
        let descriptor = try makeDescriptor(
            stream: "stream-a",
            track: "track-a",
            order: 0
        )
        var registry = RemoteStreamRegistry()

        #expect(registry.apply(try makeManifest([descriptor])).isEmpty)
        #expect(registry.bindings.isEmpty)
        #expect(registry.pendingDescriptors == [descriptor])

        #expect(registry.registerMediaTrack(descriptor.mediaTrackID) == [
            .bound(RemoteStreamBinding(descriptor: descriptor)),
        ])
        #expect(registry.bindings.map(\.descriptor) == [descriptor])
    }

    @Test("native track before manifest binds only when metadata arrives")
    func trackBeforeManifest() throws {
        let descriptor = try makeDescriptor(
            stream: "stream-a",
            track: "track-a",
            order: 0
        )
        var registry = RemoteStreamRegistry()

        #expect(registry.registerMediaTrack(descriptor.mediaTrackID).isEmpty)
        #expect(registry.bindings.isEmpty)

        #expect(registry.apply(try makeManifest([descriptor])) == [
            .bound(RemoteStreamBinding(descriptor: descriptor)),
        ])
        #expect(registry.bindings.map(\.descriptor) == [descriptor])
    }

    @Test("multiple tracks reconcile in manifest order regardless of arrival order")
    func multipleTracks() throws {
        let first = try makeDescriptor(
            stream: "stream-a",
            track: "track-a",
            order: 0
        )
        let second = try makeDescriptor(
            stream: "stream-b",
            track: "track-b",
            order: 1
        )
        var registry = RemoteStreamRegistry()

        #expect(registry.registerMediaTrack(second.mediaTrackID).isEmpty)
        #expect(registry.apply(try makeManifest([first, second])) == [
            .bound(RemoteStreamBinding(descriptor: second)),
        ])
        #expect(registry.registerMediaTrack(first.mediaTrackID) == [
            .bound(RemoteStreamBinding(descriptor: first)),
        ])
        #expect(registry.bindings.map(\.descriptor) == [first, second])
    }

    @Test("metadata updates, removals, and reset are deterministic")
    func updateRemovalAndReset() throws {
        let original = try makeDescriptor(
            stream: "stream-a",
            track: "track-a",
            order: 0,
            width: 1_280,
            height: 720
        )
        let updated = try makeDescriptor(
            stream: "stream-a",
            track: "track-a",
            order: 0,
            width: 1_920,
            height: 1_080
        )
        var registry = RemoteStreamRegistry()
        _ = registry.registerMediaTrack(original.mediaTrackID)
        _ = registry.apply(try makeManifest([original]))

        #expect(registry.apply(try makeManifest([updated])) == [
            .updated(
                previous: RemoteStreamBinding(descriptor: original),
                current: RemoteStreamBinding(descriptor: updated)
            ),
        ])
        #expect(registry.apply(try makeManifest([])) == [
            .unbound(RemoteStreamBinding(descriptor: updated)),
        ])
        #expect(registry.reset().isEmpty)
        #expect(registry.bindings.isEmpty)
        #expect(registry.negotiatedMediaTrackIDs.isEmpty)
    }
}

private func makeDescriptor(
    stream: String,
    track: String,
    order: Int,
    width: Int = 1_280,
    height: Int = 720
) throws -> ClipLiveShareStreamDescriptor {
    try ClipLiveShareStreamDescriptor(
        id: ClipLiveShareStreamID(rawValue: stream),
        mediaTrackID: ClipLiveShareMediaTrackID(rawValue: track),
        active: true,
        focused: order == 0,
        appName: "Fixture \(order)",
        windowName: "Window \(order)",
        width: width,
        height: height,
        order: order
    )
}

private func makeManifest(
    _ descriptors: [ClipLiveShareStreamDescriptor]
) throws -> ClipLiveShareStreamManifest {
    try ClipLiveShareStreamManifest(
        sessionID: ClipLiveShareSessionID(rawValue: "viewer-session"),
        streams: descriptors
    )
}
