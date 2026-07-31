import Foundation
import Testing
@testable import Clip

@Suite("Remote participant presentation")
struct RemoteParticipantPresentationTests {
    @Test("Source-before-track and track-before-source converge")
    func eventOrderConverges() {
        let source = makeSource(instance: "shared", stream: "video0")

        var sourceFirst = RemoteParticipantPresentation<String>(
            participantNamespace: Data([1])
        )
        let sourceFirstBeforeTrack = sourceFirst.replaceAuthoritativeSources([source])
        let sourceFirstAfterTrack = sourceFirst.upsertRemoteTrack(
            "source-first",
            streamID: "video0"
        )
        #expect(sourceFirstBeforeTrack.isEmpty)
        #expect(sourceFirstAfterTrack == [source])

        var trackFirst = RemoteParticipantPresentation<String>()
        let trackFirstBeforeIdentity = trackFirst.upsertRemoteTrack(
            "track-first",
            streamID: "video0"
        )
        let trackFirstBeforeSource = trackFirst.replaceAuthoritativeSources([source])
        #expect(trackFirstBeforeIdentity.isEmpty)
        #expect(trackFirstBeforeSource.isEmpty)
        trackFirst.replaceParticipantNamespace(Data([2]))
        #expect(trackFirst.readySources == [source])
        #expect(trackFirst.remoteTrack(forStreamID: "video0") == "track-first")
    }

    @Test("Participant identity namespaces identical source and window IDs")
    func participantNamespaceIsolation() {
        let source = makeSource(instance: "same", stream: "video0")
        var first = RemoteParticipantPresentation<String>(
            participantNamespace: Data([1])
        )
        var second = RemoteParticipantPresentation<String>(
            participantNamespace: Data([2])
        )

        _ = first.replaceAuthoritativeSources([source])
        _ = second.replaceAuthoritativeSources([source])
        _ = first.upsertRemoteTrack("first", streamID: "video0")
        _ = second.upsertRemoteTrack("second", streamID: "video0")

        #expect(first.sourceKey(for: source) != second.sourceKey(for: source))
        #expect(first.windowKey(for: source) != second.windowKey(for: source))
        #expect(first.remoteTrack(forStreamID: "video0") == "first")
        #expect(second.remoteTrack(forStreamID: "video0") == "second")

        let didTearDownFirst = first.tearDown()
        #expect(didTearDownFirst)
        #expect(second.readySources == [source])
        #expect(second.remoteTrack(forStreamID: "video0") == "second")
    }

    @Test("Descriptor replacement and reconnect preserve local window presentation")
    func localPresentationSurvivesReplacement() {
        let initial = makeSource(instance: "source", stream: "video0")
        let replacement = makeSource(
            instance: "source",
            stream: "video1",
            title: "Renamed"
        )
        let saved = RemoteParticipantLocalWindowPresentation(
            scaleMode: .native,
            isVisible: false,
            isFullScreen: true
        )
        var presentation = RemoteParticipantPresentation<String>(
            participantNamespace: Data([1])
        )
        _ = presentation.replaceAuthoritativeSources([initial])
        _ = presentation.upsertRemoteTrack("first", streamID: "video0")
        presentation.rememberLocalPresentation([
            NativeViewerWindowSnapshot(
                id: .source(instanceID: initial.sourceInstanceID),
                source: initial,
                isVisible: saved.isVisible,
                scaleMode: saved.scaleMode,
                isFullScreen: saved.isFullScreen
            )
        ])

        _ = presentation.removeRemoteTrack(streamID: "video0")
        #expect(presentation.readySources.isEmpty)
        #expect(presentation.localPresentation(for: initial) == saved)

        _ = presentation.replaceAuthoritativeSources([replacement])
        #expect(presentation.localPresentation(for: replacement) == saved)
        _ = presentation.upsertRemoteTrack("replacement", streamID: "video1")
        #expect(presentation.readySources == [replacement])
        #expect(presentation.localPresentation(for: replacement) == saved)

        presentation.replaceParticipantNamespace(Data([9]))
        #expect(presentation.localPresentation(for: replacement) == saved)
        #expect(
            presentation.sourceKey(for: replacement)?.participantNamespace
                == Data([9])
        )
    }

    @Test("Track loss removes only its ready window and a fresh track rebinds")
    func trackLossDoesNotLeaveGhostWindow() {
        let first = makeSource(instance: "first", stream: "video0")
        let second = makeSource(instance: "second", stream: "video1")
        var presentation = RemoteParticipantPresentation<String>(
            participantNamespace: Data([1])
        )
        _ = presentation.replaceAuthoritativeSources([first, second])
        _ = presentation.upsertRemoteTrack("track-0", streamID: "video0")
        _ = presentation.upsertRemoteTrack("track-1", streamID: "video1")
        #expect(presentation.readySources == [first, second])

        let afterLoss = presentation.removeRemoteTrack(streamID: "video0")

        #expect(afterLoss == [second])
        #expect(presentation.remoteTrack(forStreamID: "video0") == nil)
        #expect(presentation.remoteTrack(forStreamID: "video1") == "track-1")

        let afterRecovery = presentation.upsertRemoteTrack(
            "replacement-0",
            streamID: "video0"
        )
        #expect(afterRecovery == [first, second])
        #expect(
            presentation.remoteTrack(forStreamID: "video0")
                == "replacement-0"
        )
    }

    @Test("Auto-shared source replacement does not inherit another source's presentation")
    func autoSharedSourcesKeepIndependentPresentation() {
        let initial = makeSource(
            instance: "first",
            stream: "video0"
        )
        let replacement = makeSource(
            instance: "second",
            stream: "video1"
        )
        let saved = RemoteParticipantLocalWindowPresentation(
            scaleMode: .fit,
            isVisible: false,
            isFullScreen: false
        )
        var presentation = RemoteParticipantPresentation<String>(
            participantNamespace: Data([1])
        )
        _ = presentation.replaceAuthoritativeSources([initial])
        presentation.rememberLocalPresentation([
            NativeViewerWindowSnapshot(
                id: .source(instanceID: initial.sourceInstanceID),
                source: initial,
                isVisible: saved.isVisible,
                scaleMode: saved.scaleMode
            )
        ])

        _ = presentation.replaceAuthoritativeSources([replacement])

        #expect(presentation.localPresentation(for: replacement) == nil)
    }

    @Test("Authoritative removal discards obsolete local presentation")
    func sourceRemovalPrunesPresentation() {
        let source = makeSource(instance: "source", stream: "video0")
        var presentation = RemoteParticipantPresentation<String>(
            participantNamespace: Data([1])
        )
        _ = presentation.replaceAuthoritativeSources([source])
        presentation.rememberLocalPresentation([
            NativeViewerWindowSnapshot(
                id: .source(instanceID: source.sourceInstanceID),
                source: source,
                isVisible: false,
                scaleMode: .native
            )
        ])

        _ = presentation.replaceAuthoritativeSources([])

        #expect(presentation.localPresentation(for: source) == nil)
    }

    @Test("Teardown is idempotent and makes later events inert")
    func teardownIsIdempotent() {
        let source = makeSource(instance: "source", stream: "video0")
        var presentation = RemoteParticipantPresentation<String>(
            participantNamespace: Data([1])
        )
        _ = presentation.replaceAuthoritativeSources([source])
        _ = presentation.upsertRemoteTrack("track", streamID: "video0")

        let firstTeardown = presentation.tearDown()
        let secondTeardown = presentation.tearDown()
        #expect(firstTeardown)
        #expect(!secondTeardown)
        #expect(presentation.isTornDown)
        #expect(presentation.readySources.isEmpty)
        #expect(presentation.sourceKeys.isEmpty)
        #expect(presentation.remoteTrack(forStreamID: "video0") == nil)

        let lateTrack = presentation.upsertRemoteTrack(
            "late",
            streamID: "video0"
        )
        let lateSource = presentation.replaceAuthoritativeSources([source])
        #expect(lateTrack.isEmpty)
        #expect(lateSource.isEmpty)
        #expect(presentation.readySources.isEmpty)
    }

    private func makeSource(
        instance: String,
        stream: String,
        title: String = "Document"
    ) -> NativeViewerSourceSnapshot {
        NativeViewerSourceSnapshot(
            sourceInstanceID: instance,
            streamID: stream,
            applicationName: "Fixture",
            windowName: title,
            pixelSize: CGSize(width: 1_280, height: 720),
            sourcePointSize: CGSize(width: 1_280, height: 720),
            isFocused: false,
            isConnected: true,
            stateRevision: 1
        )
    }
}
