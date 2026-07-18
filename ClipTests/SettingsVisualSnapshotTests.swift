import AppKit
import ClipCore
import SwiftUI
import XCTest
@testable import Clip

/// Renders every Settings tab through the production `SettingsView` without UI automation.
///
/// Set `CLIP_SETTINGS_SNAPSHOT_DIRECTORY` to opt in. The test writes a top and bottom PNG for
/// every tab, plus a JSON manifest that records whether the active Form needed scrolling and
/// the final scroll offset. Rendering uses a real AppKit window so SwiftUI gets the
/// same window chrome and layout environment as the application, but it never moves the pointer
/// or synthesizes keyboard/mouse events. AppKit's cache renderer does not composite the native
/// title-bar tab labels, so these PNGs audit the full Settings content; use a real-window capture
/// when the tab-strip artwork itself is under review.
final class SettingsVisualSnapshotTests: XCTestCase {
    private static let outputEnvironmentKey = "CLIP_SETTINGS_SNAPSHOT_DIRECTORY"

    @MainActor
    func testRenderEverySettingsTabAtTopAndBottom() async throws {
        guard let requestedOutputDirectory = ProcessInfo.processInfo.environment[
            Self.outputEnvironmentKey
        ], !requestedOutputDirectory.isEmpty else {
            throw XCTSkip(
                "Set \(Self.outputEnvironmentKey) to render Settings visual-audit PNGs."
            )
        }

        let outputDirectory = URL(
            fileURLWithPath: requestedOutputDirectory,
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var records: [SettingsSnapshotRecord] = []
        for tab in SettingsTab.allCases {
            let fixture = try makeFixture(initialTab: tab)
            defer { fixture.close() }

            // Give SwiftUI one turn to install the selected tab and one turn for the fixed
            // storage-usage task to publish. No live service or permission call is involved.
            try await Task.sleep(for: .milliseconds(150))
            fixture.layout()

            let scrollView = fixture.primaryScrollableView()
            let topMetrics = scrollView.map { fixture.scroll($0, to: .top) }
            fixture.layout()
            records.append(
                try writeSnapshot(
                    fixture: fixture,
                    tab: tab,
                    position: .top,
                    scrollMetrics: topMetrics,
                    outputDirectory: outputDirectory
                )
            )

            let bottomMetrics = scrollView.map { fixture.scroll($0, to: .bottom) }
            fixture.layout()
            if let bottomMetrics, bottomMetrics.scrollRange > 1 {
                XCTAssertEqual(
                    bottomMetrics.actualOffset,
                    bottomMetrics.requestedOffset,
                    accuracy: 1,
                    "\(tab.rawValue) did not reach the bottom of its Settings form"
                )
            }
            records.append(
                try writeSnapshot(
                    fixture: fixture,
                    tab: tab,
                    position: .bottom,
                    scrollMetrics: bottomMetrics,
                    outputDirectory: outputDirectory
                )
            )
        }

        let manifestURL = outputDirectory.appendingPathComponent(
            "settings-snapshots.json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(records).write(to: manifestURL, options: .atomic)
    }

    @MainActor
    private func makeFixture(initialTab: SettingsTab) throws -> SettingsSnapshotFixture {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Clip-Settings-Snapshot-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )

        let homeDirectory = stateDirectory.appendingPathComponent("Home", isDirectory: true)
        var settings = ClipSettings.defaults(homeDirectory: homeDirectory)
        settings.launchAtLogin = false
        settings.showInDock = false
        settings.audio = .none

        let model = try AppSettingsModel(
            applicationSupportDirectory: stateDirectory.appendingPathComponent(
                "Application Support",
                isDirectory: true
            ),
            homeDirectory: homeDirectory,
            initialSettings: settings
        )
        let shortcuts = GlobalShortcutService(registrar: SnapshotGlobalHotKeyRegistrar())
        let storageSnapshot = SettingsStorageSnapshot(
            recordingCount: 3,
            indexedMasterByteCount: 13_300_000,
            directoryMP4ByteCount: 14_500_000,
            cleanupCandidateByteCount: 1_200_000,
            untrackedMP4ByteCount: 400_000
        )
        let settingsView = SettingsView(
            model: model,
            shortcuts: shortcuts,
            permissions: SnapshotPermissionService(),
            audio: SnapshotAudioService(),
            historyDirectory: stateDirectory.appendingPathComponent(
                "Recordings",
                isDirectory: true
            ),
            storageActions: SettingsStorageActions(
                loadUsage: { storageSnapshot },
                clearHistory: {
                    SettingsStorageSnapshot(
                        recordingCount: 0,
                        indexedMasterByteCount: 0,
                        directoryMP4ByteCount: 400_000,
                        cleanupCandidateByteCount: 0,
                        untrackedMP4ByteCount: 400_000
                    )
                },
                revealHistory: {}
            ),
            externalActions: .inert,
            initialTab: initialTab
        )

        return SettingsSnapshotFixture(
            rootView: settingsView,
            stateDirectory: stateDirectory
        )
    }

    @MainActor
    private func writeSnapshot(
        fixture: SettingsSnapshotFixture,
        tab: SettingsTab,
        position: SettingsSnapshotPosition,
        scrollMetrics: SettingsScrollMetrics?,
        outputDirectory: URL
    ) throws -> SettingsSnapshotRecord {
        let filename = "settings-\(tab.rawValue)-\(position.rawValue).png"
        let fileURL = outputDirectory.appendingPathComponent(filename, isDirectory: false)
        let png = try fixture.pngData()
        XCTAssertGreaterThan(png.count, 1_000, "Rendered an unexpectedly small PNG")
        try png.write(to: fileURL, options: .atomic)

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)

        return SettingsSnapshotRecord(
            tab: tab.rawValue,
            position: position.rawValue,
            filename: filename,
            viewportWidth: Double(fixture.snapshotSize.width),
            viewportHeight: Double(fixture.snapshotSize.height),
            scrollRange: Double(scrollMetrics?.scrollRange ?? 0),
            requestedOffset: Double(scrollMetrics?.requestedOffset ?? 0),
            actualOffset: Double(scrollMetrics?.actualOffset ?? 0)
        )
    }
}

private enum SettingsSnapshotPosition: String {
    case top
    case bottom
}

private struct SettingsSnapshotRecord: Codable {
    let tab: String
    let position: String
    let filename: String
    let viewportWidth: Double
    let viewportHeight: Double
    let scrollRange: Double
    let requestedOffset: Double
    let actualOffset: Double
}

private enum SettingsScrollDestination {
    case top
    case bottom
}

private struct SettingsScrollMetrics {
    let scrollRange: CGFloat
    let requestedOffset: CGFloat
    let actualOffset: CGFloat
}

@MainActor
private final class SettingsSnapshotFixture {
    private let stateDirectory: URL
    private let hostingController: NSHostingController<SettingsView>
    private let window: NSWindow

    var snapshotSize: CGSize {
        snapshotView.bounds.size
    }

    init(rootView: SettingsView, stateDirectory: URL) {
        self.stateDirectory = stateDirectory
        hostingController = NSHostingController(rootView: rootView)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clip Settings"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = hostingController
        window.setContentSize(SettingsView.contentSize)

        // Making the fixture key makes AppKit render focus-sensitive controls and tab chrome.
        // This does not synthesize any input event or move the pointer.
        window.makeKeyAndOrderFront(nil)
        layout()
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    func layout() {
        hostingController.view.layoutSubtreeIfNeeded()
        snapshotView.layoutSubtreeIfNeeded()
        hostingController.view.displayIfNeeded()
        snapshotView.displayIfNeeded()
    }

    /// Selects the visible Form's scroll view. SwiftUI can retain inactive tab hierarchies, so
    /// hidden ancestors are excluded before choosing the view with the largest vertical range.
    func primaryScrollableView() -> NSScrollView? {
        allScrollViews(in: hostingController.view)
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .max { verticalScrollRange(of: $0) < verticalScrollRange(of: $1) }
    }

    func scroll(
        _ scrollView: NSScrollView,
        to destination: SettingsScrollDestination
    ) -> SettingsScrollMetrics {
        guard let documentView = scrollView.documentView else {
            return SettingsScrollMetrics(scrollRange: 0, requestedOffset: 0, actualOffset: 0)
        }

        let clipView = scrollView.contentView
        let documentBounds = documentView.bounds
        let range = verticalScrollRange(of: scrollView)
        let topOffset = documentView.isFlipped
            ? NSMinY(documentBounds)
            : NSMaxY(documentBounds) - clipView.bounds.height
        let bottomOffset = documentView.isFlipped
            ? NSMaxY(documentBounds) - clipView.bounds.height
            : NSMinY(documentBounds)
        let requestedOffset = max(
            NSMinY(documentBounds),
            min(
                destination == .top ? topOffset : bottomOffset,
                NSMaxY(documentBounds) - clipView.bounds.height
            )
        )
        clipView.scroll(
            to: NSPoint(x: clipView.bounds.origin.x, y: requestedOffset)
        )
        scrollView.reflectScrolledClipView(clipView)
        layout()

        return SettingsScrollMetrics(
            scrollRange: range,
            requestedOffset: requestedOffset,
            actualOffset: clipView.bounds.origin.y
        )
    }

    func pngData() throws -> Data {
        let bounds = snapshotView.bounds
        guard !bounds.isEmpty,
              let representation = snapshotView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SettingsSnapshotError.couldNotCreateBitmap
        }
        snapshotView.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SettingsSnapshotError.couldNotEncodePNG
        }
        return data
    }

    private var snapshotView: NSView {
        // The content view's frame-view parent includes the real title bar and any TabView
        // toolbar/tab chrome while still avoiding Screen Recording permission APIs.
        window.contentView?.superview ?? hostingController.view
    }

    private func allScrollViews(in view: NSView) -> [NSScrollView] {
        var result = view is NSScrollView ? [view as! NSScrollView] : []
        for child in view.subviews {
            result.append(contentsOf: allScrollViews(in: child))
        }
        return result
    }

    private func verticalScrollRange(of scrollView: NSScrollView) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        return max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
    }
}

private enum SettingsSnapshotError: Error {
    case couldNotCreateBitmap
    case couldNotEncodePNG
}

@MainActor
private final class SnapshotPermissionService: PermissionServicing {
    func currentStatus(for permission: ClipPermission) -> PermissionState {
        switch permission {
        case .screenRecording:
            .granted
        case .microphone:
            .denied
        case .systemAudio:
            .restricted
        }
    }

    func request(_ permission: ClipPermission) async -> PermissionState {
        currentStatus(for: permission)
    }
}

@MainActor
private final class SnapshotAudioService: AudioServicing {
    let defaultInputName: String? = "Studio Microphone"
    func refreshDevices() async {}
}

@MainActor
private final class SnapshotGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    func replace(
        registrations: [GlobalHotKeyRegistration],
        handler: @escaping @MainActor (GlobalShortcutAction) -> Void
    ) throws {}

    func unregisterAll() {}
}
