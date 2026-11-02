@preconcurrency import AVFoundation
import AppKit
import AVKit
import SwiftUI

/// SwiftUI/AppKit boundary for a lightweight, controller-free AVPlayer surface.
/// SwiftUI owns gestures and file dragging; AppKit owns the AVPlayerLayer.
struct PreviewPlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PreviewPlayerNSView {
        let view = PreviewPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PreviewPlayerNSView, context: Context) {
        nsView.player = player
    }
}

/// A dedicated native player window shares the editor's player. Closing or
/// leaving fullscreen does not replace its item, mute state, or playhead.
@MainActor
final class PreviewExpandedPlayerController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let playerView: PreviewExpandedPlayerView
    private var onClose: (() -> Void)?
    private weak var editorWindow: NSWindow?
    private var shouldRestoreEditor = false
    private var hasBeenShown = false
    private var isClosed = false

    init(player: AVPlayer, title: String, editorWindow: NSWindow? = nil, onClose: @escaping () -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        playerView = PreviewExpandedPlayerView()
        self.onClose = onClose
        self.editorWindow = editorWindow
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        window.minSize = NSSize(width: 480, height: 320)
        window.delegate = self
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = false
        playerView.closePreview = { [weak self] in self?.close() }
        window.contentView = playerView
        window.center()
    }

    func show() {
        guard !isClosed else { return }
        if !hasBeenShown {
            shouldRestoreEditor = editorWindow?.isVisible == true
            hasBeenShown = true
        }
        // The editor is a floating panel and a fullscreen auxiliary window.
        // Hide it while the native player owns presentation so it cannot cover
        // either the expanded window or its dedicated fullscreen Space.
        editorWindow?.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(playerView)
    }

    func close(restoringEditor: Bool = true) {
        if !restoringEditor { shouldRestoreEditor = false }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        playerView.player = nil
        let callback = onClose
        onClose = nil
        callback?()
        if shouldRestoreEditor { editorWindow?.makeKeyAndOrderFront(nil) }
    }
}

@MainActor
private final class PreviewExpandedPlayerView: AVPlayerView {
    var closePreview: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePreview?() }
        else { super.keyDown(with: event) }
    }
}

final class PreviewPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
        }
    }

    private var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            preconditionFailure("PreviewPlayerNSView must be backed by AVPlayerLayer")
        }
        return playerLayer
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
