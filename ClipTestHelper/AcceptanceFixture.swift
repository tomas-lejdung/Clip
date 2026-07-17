import AppKit
@preconcurrency import AVFoundation
import Foundation

enum AcceptanceToneError: LocalizedError {
    case unavailableFormat
    case unavailableBuffer

    var errorDescription: String? {
        switch self {
        case .unavailableFormat:
            "The current audio output cannot render the synthetic acceptance tone."
        case .unavailableBuffer:
            "ClipTestHelper could not allocate the synthetic acceptance tone."
        }
    }
}

/// A process-local, low-volume signal used only by the opt-in real-audio lane.
/// ScreenCaptureKit can therefore prove system-audio capture without opening a
/// browser, media service, or any user content.
@MainActor
final class AcceptanceTonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    func start() throws {
        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ) else {
            throw AcceptanceToneError.unavailableFormat
        }
        let frameCount = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let channelData = buffer.floatChannelData else {
            throw AcceptanceToneError.unavailableBuffer
        }

        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let phase = (2 * Double.pi * 997 * Double(frame)) / sampleRate
            let sample = Float(sin(phase)) * 0.055
            for channel in 0..<Int(format.channelCount) {
                channelData[channel][frame] = sample
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    deinit {
        player.stop()
        engine.stop()
    }
}

@MainActor
final class CapturePatternView: NSView {
    private(set) var frameNumber = 0
    private var framesPerSecond = 30
    private var clickCount = 0
    private var cursorPoint: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("clip.acceptance.capturePattern")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Deterministic animated screen capture target")
    }

    required init?(coder: NSCoder) {
        nil
    }

    func advanceFrame() {
        frameNumber += 1
        needsDisplay = true
    }

    func setFrameNumber(_ frameNumber: Int) {
        self.frameNumber = max(0, frameNumber)
        needsDisplay = true
    }

    func setFramesPerSecond(_ framesPerSecond: Int) {
        precondition(framesPerSecond == 30 || framesPerSecond == 60)
        self.framesPerSecond = framesPerSecond
        needsDisplay = true
    }

    func reset() {
        frameNumber = 0
        clickCount = 0
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.push()
        updateCursor(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
        cursorPoint = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        clickCount += 1
        updateCursor(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCheckerboard()
        drawCalibrationBorder()
        drawColorBars()
        drawFineDetailTargets()
        drawMovingObject()
        drawScrollingText()
        drawCursorTarget()
        drawTimecode()
        drawCursorTelemetry()
    }

    private func updateCursor(_ event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    private func drawCheckerboard() {
        let tileSize: CGFloat = 40
        let columns = Int(ceil(bounds.width / tileSize))
        let rows = Int(ceil(bounds.height / tileSize))

        for row in 0..<rows {
            for column in 0..<columns {
                let isLight = (row + column).isMultiple(of: 2)
                (isLight
                    ? NSColor(calibratedWhite: 0.90, alpha: 1)
                    : NSColor(calibratedWhite: 0.14, alpha: 1)
                ).setFill()
                NSRect(
                    x: CGFloat(column) * tileSize,
                    y: CGFloat(row) * tileSize,
                    width: tileSize,
                    height: tileSize
                ).fill()
            }
        }
    }

    private func drawCalibrationBorder() {
        NSColor.systemYellow.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 5, dy: 5))
        border.lineWidth = 10
        border.stroke()

        let cornerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black,
        ]
        NSString(string: "TOP LEFT · 0,0").draw(
            at: CGPoint(x: 16, y: 14),
            withAttributes: cornerAttributes
        )
        NSString(string: "BOTTOM RIGHT · \(Int(bounds.width))×\(Int(bounds.height))").draw(
            at: CGPoint(x: max(16, bounds.width - 245), y: max(14, bounds.height - 34)),
            withAttributes: cornerAttributes
        )
    }

    private func drawColorBars() {
        let colors: [NSColor] = [
            .systemRed,
            .systemOrange,
            .systemYellow,
            .systemGreen,
            .systemCyan,
            .systemBlue,
            .systemPurple,
            .white,
        ]
        let barWidth = max(1, (bounds.width - 80) / CGFloat(colors.count))
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSRect(
                x: 40 + (CGFloat(index) * barWidth),
                y: 58,
                width: barWidth,
                height: 46
            ).fill()
        }
    }

    private func drawFineDetailTargets() {
        let backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        let physicalPixel = 1 / max(1, backingScale)
        let detailRect = NSRect(x: 40, y: 105, width: 230, height: 34)
        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        detailRect.fill()

        for pixelColumn in 0..<80 {
            (pixelColumn.isMultiple(of: 2) ? NSColor.white : NSColor.black).setFill()
            NSRect(
                x: detailRect.minX + CGFloat(pixelColumn) * physicalPixel,
                y: detailRect.minY,
                width: physicalPixel,
                height: detailRect.height
            ).fill()
        }
        for pixelRow in stride(from: 0, to: 30, by: 4) {
            NSColor.white.setFill()
            NSRect(
                x: detailRect.minX + 52,
                y: detailRect.minY + CGFloat(pixelRow) * physicalPixel,
                width: 74,
                height: physicalPixel
            ).fill()
            NSColor.black.setFill()
            NSRect(
                x: detailRect.minX + 52,
                y: detailRect.minY + CGFloat(pixelRow + 1) * physicalPixel,
                width: 74,
                height: physicalPixel
            ).fill()
        }

        let edgeColors: [NSColor] = [.systemRed, .systemGreen, .systemBlue, .systemCyan]
        for (index, color) in edgeColors.enumerated() {
            color.setFill()
            let x = detailRect.minX + 134 + CGFloat(index) * 21
            NSRect(x: x, y: detailRect.minY, width: 20, height: detailRect.height).fill()
            (index.isMultiple(of: 2) ? NSColor.white : NSColor.black).setFill()
            NSRect(x: x, y: detailRect.minY, width: physicalPixel, height: detailRect.height).fill()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black,
        ]
        NSString(string: "SMALL TEXT 1PX RGB 0123456789").draw(
            at: CGPoint(x: 278, y: 106),
            withAttributes: attributes
        )
    }

    private func drawMovingObject() {
        let travel = max(1, Int(bounds.width - 200))
        let period = max(2, travel * 2)
        let motionPixels = Int(
            (Double(frameNumber) * 240 / Double(framesPerSecond)).rounded(.down)
        )
        let phase = motionPixels % period
        let offset = phase <= travel ? phase : period - phase
        let rect = NSRect(x: 60 + CGFloat(offset), y: 145, width: 94, height: 94)

        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: rect.offsetBy(dx: 7, dy: 7), xRadius: 14, yRadius: 14).fill()
        NSColor.systemPink.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        NSString(string: "MOTION").draw(
            at: CGPoint(x: rect.minX + 15, y: rect.midY - 10),
            withAttributes: attributes
        )
    }

    private func drawScrollingText() {
        let message = "CLIP • NATIVE SWIFT 6 • LOCAL MP4 • FRAME \(frameNumber) • "
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.86),
        ]
        let measuredWidth = NSString(string: message).size(withAttributes: attributes).width
        let cycleWidth = max(1, bounds.width + measuredWidth)
        let scrollPixels = Double(frameNumber) * 150 / Double(framesPerSecond)
        let x = bounds.width - CGFloat(scrollPixels).truncatingRemainder(dividingBy: cycleWidth)
        NSString(string: message).draw(
            at: CGPoint(x: x, y: bounds.height - 82),
            withAttributes: attributes
        )
    }

    private func drawCursorTarget() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY + 35)
        NSColor.systemGreen.setStroke()

        for radius: CGFloat in [18, 34, 52] {
            let ring = NSBezierPath(ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            ring.lineWidth = radius == 18 ? 4 : 2
            ring.stroke()
        }

        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: center.x - 70, y: center.y))
        crosshair.line(to: CGPoint(x: center.x + 70, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 70))
        crosshair.line(to: CGPoint(x: center.x, y: center.y + 70))
        crosshair.lineWidth = 3
        crosshair.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .heavy),
            .foregroundColor: NSColor.systemGreen,
            .backgroundColor: NSColor.black.withAlphaComponent(0.8),
        ]
        NSString(string: "CURSOR TARGET").draw(
            at: CGPoint(x: center.x - 61, y: center.y + 78),
            withAttributes: attributes
        )
    }

    private func drawTimecode() {
        let totalSeconds = frameNumber / framesPerSecond
        let frames = frameNumber % framesPerSecond
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let value = String(
            format: "%02d:%02d:%02d:%02d  FRAME %06d",
            hours,
            minutes,
            seconds,
            frames,
            frameNumber
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 25, weight: .heavy),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.92),
        ]
        NSString(string: value).draw(at: CGPoint(x: 34, y: 116), withAttributes: attributes)
    }

    private func drawCursorTelemetry() {
        guard let cursorPoint else { return }
        NSColor.systemCyan.setStroke()
        let cursorRing = NSBezierPath(ovalIn: NSRect(
            x: cursorPoint.x - 13,
            y: cursorPoint.y - 13,
            width: 26,
            height: 26
        ))
        cursorRing.lineWidth = 3
        cursorRing.stroke()

        let text = "x=\(Int(cursorPoint.x)) y=\(Int(cursorPoint.y)) clicks=\(clickCount)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black,
        ]
        NSString(string: text).draw(
            at: CGPoint(x: min(cursorPoint.x + 18, bounds.maxX - 185), y: cursorPoint.y + 8),
            withAttributes: attributes
        )
    }
}

@MainActor
final class MP4DropReceiverView: NSView {
    static let accessibilityIdentifier = "clip.acceptance.dropReceiver"

    private let titleLabel = NSTextField(labelWithString: "Local MP4 Receiver")
    private let instructionLabel = NSTextField(wrappingLabelWithString:
        "Drop a Clip video here, copy it and choose Validate Pasteboard, or select it locally. Nothing is uploaded or sent to another app."
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "Waiting for a local .mp4 file URL")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var pasteboardButton = NSButton(
        title: "Validate Pasteboard",
        target: self,
        action: #selector(validatePasteboard)
    )
    private lazy var chooseButton = NSButton(
        title: "Choose MP4…",
        target: self,
        action: #selector(chooseMP4)
    )
    private var lastValidationWasValid: Bool?
    private var pendingPromiseReceivers: [NSFilePromiseReceiver] = []
    var onValidation: ((MP4ValidationReport) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier(Self.accessibilityIdentifier)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Local MP4 paste and drop receiver")
        var draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]
        draggedTypes.append(contentsOf:
            NSFilePromiseReceiver.readableDraggedTypes.map {
                NSPasteboard.PasteboardType(rawValue: $0)
            }
        )
        registerForDraggedTypes(draggedTypes)

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("clip.acceptance.receiver.title")
        instructionLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("clip.acceptance.receiver.status")
        detailsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.identifier = NSUserInterfaceItemIdentifier("clip.acceptance.receiver.details")
        pasteboardButton.identifier = NSUserInterfaceItemIdentifier(
            "clip.acceptance.receiver.validatePasteboard"
        )
        chooseButton.identifier = NSUserInterfaceItemIdentifier("clip.acceptance.receiver.choose")

        [titleLabel, instructionLabel, statusLabel, detailsLabel, pasteboardButton, chooseButton]
            .forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let horizontalInset: CGFloat = 22
        let contentWidth = max(120, bounds.width - (horizontalInset * 2))
        titleLabel.frame = NSRect(x: horizontalInset, y: 26, width: contentWidth, height: 30)
        instructionLabel.frame = NSRect(x: horizontalInset, y: 70, width: contentWidth, height: 86)
        pasteboardButton.frame = NSRect(x: horizontalInset, y: 176, width: contentWidth, height: 34)
        chooseButton.frame = NSRect(x: horizontalInset, y: 218, width: contentWidth, height: 34)
        statusLabel.frame = NSRect(x: horizontalInset, y: 286, width: contentWidth, height: 58)
        detailsLabel.frame = NSRect(x: horizontalInset, y: 352, width: contentWidth, height: 170)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let dropZone = NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 12), xRadius: 18, yRadius: 18)
        switch lastValidationWasValid {
        case true:
            NSColor.systemGreen.withAlphaComponent(0.14).setFill()
            NSColor.systemGreen.setStroke()
        case false:
            NSColor.systemRed.withAlphaComponent(0.12).setFill()
            NSColor.systemRed.setStroke()
        case nil:
            NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
            NSColor.separatorColor.setStroke()
        }
        dropZone.fill()
        dropZone.lineWidth = 2
        dropZone.stroke()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if FileURLPasteboardResolver.firstFileURL(in: sender.draggingPasteboard) != nil
            || !filePromiseReceivers(in: sender.draggingPasteboard).isEmpty {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let url = FileURLPasteboardResolver.firstFileURL(in: sender.draggingPasteboard) {
            validate(url)
            return true
        }

        let receivers = filePromiseReceivers(in: sender.draggingPasteboard)
        guard let receiver = receivers.first else {
            display(MP4Validator.rejectedReport(
                URL(fileURLWithPath: "/missing-drop-file.mp4"),
                failure: "The drop did not contain a local file URL or file promise."
            ))
            return false
        }
        pendingPromiseReceivers = receivers
        receivePromisedFile(receiver)
        return true
    }

    @objc
    private func validatePasteboard() {
        guard let url = FileURLPasteboardResolver.firstFileURL(in: .general) else {
            display(MP4Validator.rejectedReport(
                URL(fileURLWithPath: "/missing-pasteboard-file.mp4"),
                failure: "The pasteboard does not contain a local file URL."
            ))
            return
        }
        validate(url)
    }

    @objc
    private func chooseMP4() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        validate(url)
    }

    private func filePromiseReceivers(in pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver] ?? []
    }

    private func receivePromisedFile(_ receiver: NSFilePromiseReceiver) {
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-drop-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            display(MP4Validator.rejectedReport(
                destinationDirectory.appendingPathComponent("unavailable.mp4"),
                failure: "Could not create the local promised-file destination: \(error.localizedDescription)"
            ))
            pendingPromiseReceivers = []
            return
        }

        statusLabel.stringValue = "Receiving promised MP4…"
        detailsLabel.stringValue = destinationDirectory.path
        receiver.receivePromisedFiles(
            atDestination: destinationDirectory,
            options: [:],
            operationQueue: .main
        ) { [weak self] fileURL, error in
            guard let self else { return }
            self.pendingPromiseReceivers = []
            if let error {
                try? FileManager.default.removeItem(at: destinationDirectory)
                self.display(MP4Validator.rejectedReport(
                    destinationDirectory.appendingPathComponent("failed.mp4"),
                    failure: "The promised MP4 could not be received: \(error.localizedDescription)"
                ))
                return
            }
            self.validate(fileURL, cleanupDirectory: destinationDirectory)
        }
    }

    private func validate(_ url: URL, cleanupDirectory: URL? = nil) {
        statusLabel.stringValue = "Validating \(url.lastPathComponent)…"
        detailsLabel.stringValue = url.path
        Task { @MainActor [weak self] in
            let report = await MP4Validator.validate(url)
            if let cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }
            self?.display(report)
        }
    }

    private func display(_ report: MP4ValidationReport) {
        lastValidationWasValid = report.valid
        if report.valid {
            statusLabel.stringValue = "Valid local MP4 file URL"
            detailsLabel.stringValue = """
            \(report.width)×\(report.height) · \(String(format: "%.2f", report.durationSeconds)) s
            \(String(format: "%.2f", report.nominalFramesPerSecond)) fps · \(report.videoCodec ?? "unknown codec")
            \(report.videoTrackCount) video / \(report.audioTrackCount) audio track(s)
            \(report.fileSizeBytes) bytes
            \(URL(string: report.fileURL)?.path ?? report.fileURL)
            """
        } else {
            statusLabel.stringValue = "Rejected: not a readable MP4 video"
            detailsLabel.stringValue = report.failure ?? "Unknown validation failure."
        }
        needsDisplay = true
        onValidation?(report)
    }
}

@MainActor
final class AcceptanceFixtureController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: FixtureOptions
    private let patternView = CapturePatternView(frame: .zero)
    private let receiverView = MP4DropReceiverView(frame: .zero)
    private var window: NSWindow?
    private var receiverWindow: NSWindow?
    private var animationTimer: Timer?
    private var quitTimer: Timer?
    private var tonePlayer: AcceptanceTonePlayer?
    private var toneFailure: String?

    init(options: FixtureOptions) {
        self.options = options
        super.init()
        patternView.setFramesPerSecond(options.framesPerSecond)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        guard let screen = NSScreen.screens.first ?? NSScreen.main else {
            NSApp.terminate(nil)
            return
        }
        let visibleFrame = screen.visibleFrame
        let receiverWidth = min(320, max(240, visibleFrame.width - 24))
        let receiverHeight = min(540, max(360, visibleFrame.height - 64))
        // Keep the capture fixture and promised-file receiver side by side.
        // On narrower displays the fixture shrinks instead of allowing the
        // always-on-top receiver to cover pixels used as capture evidence.
        let fixtureWidth = min(
            960,
            max(480, visibleFrame.width - receiverWidth - 60)
        )
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: fixtureWidth,
            height: min(700, max(480, visibleFrame.height - 48))
        )
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clip Deterministic Acceptance Fixture"
        window.identifier = NSUserInterfaceItemIdentifier("clip.acceptance.fixtureWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 480)
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.minX + 16,
            y: visibleFrame.midY - (window.frame.height / 2)
        ))
        patternView.autoresizingMask = [.width, .height]
        window.contentView = patternView
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Keep the local drop receiver visible while Clip's floating Preview
        // panel is active. The receiver lives in its own deterministic window
        // so a real cross-application promised-file drag can be unattended.
        let receiverContentRect = NSRect(
            x: 0,
            y: 0,
            width: receiverWidth,
            height: receiverHeight
        )
        let receiverWindow = NSPanel(
            contentRect: receiverContentRect,
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        receiverWindow.title = "Clip Local MP4 Receiver"
        receiverWindow.identifier = NSUserInterfaceItemIdentifier(
            "clip.acceptance.receiverWindow"
        )
        receiverWindow.isReleasedWhenClosed = false
        receiverWindow.hidesOnDeactivate = false
        receiverWindow.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 1
        )
        receiverWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        receiverWindow.delegate = self
        receiverWindow.contentView = receiverView
        let receiverLeft = min(
            visibleFrame.maxX - receiverWindow.frame.width - 12,
            window.frame.maxX + 12
        )
        receiverWindow.setFrameTopLeftPoint(NSPoint(
            x: receiverLeft,
            y: visibleFrame.maxY - 12
        ))
        receiverWindow.orderFront(nil)
        self.receiverWindow = receiverWindow

        receiverView.onValidation = { [weak self] report in
            guard let resultFileURL = self?.options.resultFileURL else { return }
            do {
                try HelperJSON.write(report, to: resultFileURL)
            } catch {
                NSSound.beep()
            }
        }

        if options.playsTone {
            do {
                let tonePlayer = AcceptanceTonePlayer()
                try tonePlayer.start()
                self.tonePlayer = tonePlayer
            } catch {
                toneFailure = error.localizedDescription
            }
        }

        writeFixtureReadyReport(
            screen: screen,
            fixtureWindow: window,
            receiverWindow: receiverWindow
        )

        if options.isAnimated {
            let timer = Timer(
                timeInterval: 1.0 / Double(options.framesPerSecond),
                target: self,
                selector: #selector(advanceFrame),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }

        if let quitAfterSeconds = options.quitAfterSeconds {
            let timer = Timer(
                timeInterval: quitAfterSeconds,
                target: self,
                selector: #selector(quit),
                userInfo: nil,
                repeats: false
            )
            RunLoop.main.add(timer, forMode: .common)
            quitTimer = timer
        }

        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        animationTimer?.invalidate()
        quitTimer?.invalidate()
        tonePlayer?.stop()
        tonePlayer = nil
        receiverWindow?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    @objc
    private func advanceFrame() {
        patternView.advanceFrame()
    }

    private func writeFixtureReadyReport(
        screen: NSScreen,
        fixtureWindow: NSWindow,
        receiverWindow: NSWindow
    ) {
        guard let readyFileURL = options.readyFileURL else { return }

        receiverView.layoutSubtreeIfNeeded()
        let localDropPoint = NSPoint(
            x: receiverView.bounds.midX,
            y: min(270, receiverView.bounds.maxY - 24)
        )
        let windowPoint = receiverView.convert(localDropPoint, to: nil)
        let appKitScreenPoint = receiverWindow.convertPoint(toScreen: windowPoint)

        // XCTest's global screen coordinates are top-left based while AppKit's
        // primary-screen coordinates are bottom-left based.
        let xctestScreenPoint = CGPoint(
            x: appKitScreenPoint.x,
            y: screen.frame.maxY - appKitScreenPoint.y
        )
        let fixtureAppKitPoint = CGPoint(
            x: fixtureWindow.frame.midX,
            y: fixtureWindow.frame.midY
        )
        let fixtureXCTestPoint = CGPoint(
            x: fixtureAppKitPoint.x,
            y: screen.frame.maxY - fixtureAppKitPoint.y
        )

        // Keep the drag endpoints inside the pattern view rather than on the
        // titled window's resize border. These are global XCTest coordinates
        // (top-left origin), matching the drop/capture points above. Publishing
        // the expected backing-pixel dimensions lets the real acceptance lane
        // prove that the user's selected rectangle reached the managed master.
        patternView.layoutSubtreeIfNeeded()
        let patternWindowRect = patternView.convert(patternView.bounds, to: nil)
        let patternScreenRect = fixtureWindow.convertToScreen(patternWindowRect)
        let captureInset: CGFloat = 12
        let captureScreenRect = patternScreenRect.insetBy(
            dx: min(captureInset, patternScreenRect.width / 4),
            dy: min(captureInset, patternScreenRect.height / 4)
        )
        let captureAreaStart = CGPoint(
            x: captureScreenRect.minX,
            y: screen.frame.maxY - captureScreenRect.maxY
        )
        let captureAreaEnd = CGPoint(
            x: captureScreenRect.maxX,
            y: screen.frame.maxY - captureScreenRect.minY
        )
        let expectedCaptureWidth = Int(
            (captureScreenRect.width * screen.backingScaleFactor).rounded()
        )
        let expectedCaptureHeight = Int(
            (captureScreenRect.height * screen.backingScaleFactor).rounded()
        )
        let expectedDisplayWidth = Int(
            (screen.frame.width * screen.backingScaleFactor).rounded()
        )
        let expectedDisplayHeight = Int(
            (screen.frame.height * screen.backingScaleFactor).rounded()
        )
        let status = toneFailure == nil ? "ready" : "tone-unavailable"
        let report = FixtureReadyReport(
            protocolVersion: 2,
            status: status,
            dropReceiverAccessibilityIdentifier: MP4DropReceiverView.accessibilityIdentifier,
            dropPointX: Double(xctestScreenPoint.x),
            dropPointY: Double(xctestScreenPoint.y),
            capturePointX: Double(fixtureXCTestPoint.x),
            capturePointY: Double(fixtureXCTestPoint.y),
            captureAreaStartX: Double(captureAreaStart.x),
            captureAreaStartY: Double(captureAreaStart.y),
            captureAreaEndX: Double(captureAreaEnd.x),
            captureAreaEndY: Double(captureAreaEnd.y),
            captureAreaExpectedWidthPixels: expectedCaptureWidth,
            captureAreaExpectedHeightPixels: expectedCaptureHeight,
            displayExpectedWidthPixels: expectedDisplayWidth,
            displayExpectedHeightPixels: expectedDisplayHeight,
            fixtureFramesPerSecond: options.framesPerSecond,
            toneActive: tonePlayer != nil,
            failure: toneFailure
        )
        do {
            try HelperJSON.write(report, to: readyFileURL)
        } catch {
            let message = "ClipTestHelper could not publish fixture readiness: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            NSSound.beep()
        }
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }
}

enum FixtureRendererError: LocalizedError {
    case cannotCreateBitmap
    case cannotEncodePNG

    var errorDescription: String? {
        switch self {
        case .cannotCreateBitmap:
            "Could not render the deterministic fixture into a bitmap."
        case .cannotEncodePNG:
            "Could not encode the deterministic fixture as PNG."
        }
    }
}

@MainActor
enum FixtureRenderer {
    static func renderPNG(to outputURL: URL, frame: Int) throws {
        _ = NSApplication.shared
        let view = CapturePatternView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.setFrameNumber(frame)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw FixtureRendererError.cannotCreateBitmap
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureRendererError.cannotEncodePNG
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
    }
}

@MainActor
enum AcceptanceSelfTest {
    static func run(in workDirectory: URL) async -> AcceptanceSelfTestReport {
        let mp4URL = workDirectory.appendingPathComponent("fixture.mp4")
        let renamedMP4URL = workDirectory.appendingPathComponent(
            "acceptance renamed clip.mp4"
        )
        let pngURL = workDirectory.appendingPathComponent("fixture.png")
        let invalidURL = workDirectory.appendingPathComponent("invalid.mp4")

        do {
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true
            )
            try await SyntheticMP4Generator.write(to: mp4URL)
            try FileManager.default.copyItem(at: mp4URL, to: renamedMP4URL)
            try FixtureRenderer.renderPNG(to: pngURL, frame: 45)
            try Data("This is deliberately not an MP4 file.".utf8).write(
                to: invalidURL,
                options: .atomic
            )

            let validReport = await MP4Validator.validate(mp4URL)
            let renamedReport = await MP4Validator.validate(renamedMP4URL)
            let invalidReport = await MP4Validator.validate(invalidURL)

            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let wrotePasteboard = pasteboard.writeObjects([renamedMP4URL as NSURL])
            let resolvedURL = FileURLPasteboardResolver.firstFileURL(in: pasteboard)
            let pasteboardResolved = wrotePasteboard
                && resolvedURL?.standardizedFileURL == renamedMP4URL.standardizedFileURL

            let success = validReport.valid
                && renamedReport.valid
                && renamedReport.fileSizeBytes == validReport.fileSizeBytes
                && FileManager.default.fileExists(atPath: mp4URL.path)
                && FileManager.default.fileExists(atPath: renamedMP4URL.path)
                && !invalidReport.valid
                && pasteboardResolved
                && FileManager.default.fileExists(atPath: pngURL.path)

            return AcceptanceSelfTestReport(
                protocolVersion: 2,
                success: success,
                generatedMP4URL: mp4URL.absoluteString,
                renderedFixturePNGURL: pngURL.absoluteString,
                generatedMP4WasValid: validReport.valid,
                invalidPayloadWasRejected: !invalidReport.valid,
                localPasteboardResolvedFileURL: pasteboardResolved,
                failure: success ? nil : "One or more deterministic acceptance assertions failed."
            )
        } catch {
            return AcceptanceSelfTestReport(
                protocolVersion: 2,
                success: false,
                generatedMP4URL: mp4URL.absoluteString,
                renderedFixturePNGURL: pngURL.absoluteString,
                generatedMP4WasValid: false,
                invalidPayloadWasRejected: false,
                localPasteboardResolvedFileURL: false,
                failure: error.localizedDescription
            )
        }
    }
}
