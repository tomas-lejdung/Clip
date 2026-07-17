@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// SwiftUI/AppKit boundary for a lightweight, controller-free AVPlayer surface.
/// SwiftUI owns gestures and file dragging; AppKit owns the AVPlayerLayer.
struct PreviewPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PreviewPlayerNSView {
        let view = PreviewPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PreviewPlayerNSView, context: Context) {
        nsView.player = player
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
