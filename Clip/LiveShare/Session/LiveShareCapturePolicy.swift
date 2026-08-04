import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import CoreGraphics
import Foundation

/// A running application that can be shown in the system-audio exclusion UI.
///
/// This value belongs to capture publication rather than any room/session
/// coordinator. Both the native participant mesh and the retired coordinator
/// can therefore build the same menu without depending on each other.
struct LiveShareCaptureAudioApplicationCandidate: Equatable, Sendable {
    let bundleIdentifier: String
    let name: String
    let applicationPath: String?
}
/// The process identity used to decide when a ScreenCaptureKit audio filter
/// must be rebuilt after an excluded application launches or restarts.
struct LiveShareCaptureAudioApplicationProcessCandidate: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
}

/// Geometry shared by ScreenCaptureKit input and the encoded WebRTC stream.
struct LiveShareCaptureGeometry: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// Stateless capture and publication decisions shared by every Live Share room
/// implementation. This type deliberately knows nothing about signaling,
/// admission, participant leadership, or the legacy coordinator lifecycle.
enum LiveShareCapturePolicy {
    /// Recording click highlights are a separate, file-capture preference.
    /// Live Share does not expose that setting and ScreenCaptureKit can place
    /// the system highlight in the wrong coordinate space after a live window
    /// resize, so every network capture keeps it disabled explicitly.
    static func captureVideoConfiguration(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        codec: LiveShareVideoCodec,
        colorMode: LiveShareColorMode = .compatibleRec709,
        showsCursor: Bool = true,
        captureResolution: CaptureVideoResolution = .best,
        sourceRect: CGRect? = nil
    ) -> CaptureVideoConfiguration {
        CaptureVideoConfiguration(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            showsCursor: showsCursor,
            showsClickHighlights: false,
            sourceRect: sourceRect,
            pixelFormat: capturePixelFormat(codec: codec, colorMode: colorMode),
            captureResolution: captureResolution
        )
    }

    /// Capture discovery supplies both point and pixel geometry. The shared
    /// policy contains the full 1×/2× matrix and preserves `contentScale = 1`.
    /// Live Share rebuilds the source when this ratio changes as a window moves
    /// between displays.
    static func windowCaptureResolution(
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        sourcePointWidth: Int,
        sourcePointHeight: Int
    ) -> CaptureVideoResolution {
        CaptureVideoResolutionPolicy.nativeScale(
            sourcePixelWidth: sourcePixelWidth,
            sourcePixelHeight: sourcePixelHeight,
            sourcePointWidth: sourcePointWidth,
            sourcePointHeight: sourcePointHeight
        )
    }

    /// ScreenCaptureKit input geometry for a live source. Native pixels remain
    /// untouched whenever they fit the H.264 hardware envelope, including odd
    /// dimensions. H.264's even output alignment is applied separately by
    /// `streamGeometry`; asking ScreenCaptureKit to turn 1,605 pixels into
    /// 1,604 would fractionally rescale every pixel and soften text.
    ///
    /// Apple Silicon's hardware H.264 encoder still rejects geometry above a
    /// 4,096-pixel side (including 5K and 6K displays), so oversized sources
    /// are aspect-fit and macroblock-aligned before capture. VP8, VP9, and AV1
    /// keep exact native geometry because none of those H.264 limits apply to
    /// their libwebrtc software encoders.
    static func captureGeometry(
        sourceWidth: Int,
        sourceHeight: Int,
        codec: LiveShareVideoCodec,
        framesPerSecond: Int = 30
    ) -> LiveShareCaptureGeometry {
        let width = max(1, sourceWidth)
        let height = max(1, sourceHeight)
        guard codec == .h264 else {
            return LiveShareCaptureGeometry(width: width, height: height)
        }

        let maximumSide = 4_096.0
        let maximumLevelMacroblocksPerFrame = 36_864
        let maximumLevelMacroblocksPerSecond = 2_073_600
        let cadence = max(1, framesPerSecond)
        let maximumMacroblocksPerFrame = min(
            maximumLevelMacroblocksPerFrame,
            max(1, maximumLevelMacroblocksPerSecond / cadence)
        )
        let maximumLuma = Double(maximumMacroblocksPerFrame * 16 * 16)
        let sourceLuma = Double(width) * Double(height)
        let scale = min(
            1,
            maximumSide / Double(width),
            maximumSide / Double(height),
            sqrt(maximumLuma / sourceLuma)
        )
        // A tiny epsilon prevents an exactly representable boundary such as
        // 6,016 × 3,384 → 4,096 × 2,304 from losing two pixels to binary
        // floating-point rounding before the even-alignment step.
        var fittedWidth = max(2, Int((Double(width) * scale + 1e-7).rounded(.down)))
        var fittedHeight = max(2, Int((Double(height) * scale + 1e-7).rounded(.down)))
        if scale < 1 {
            // H.264 Level 5.2 is expressed in 16×16 macroblocks, not only
            // visible luma pixels. Align a downscaled result to macroblocks so
            // codec padding cannot push an unusual aspect ratio beyond 36,864.
            if fittedWidth >= 16 { fittedWidth -= fittedWidth % 16 }
            if fittedHeight >= 16 { fittedHeight -= fittedHeight % 16 }
        }
        var encodedWidth = videoEncoderCompatibleDimension(fittedWidth)
        var encodedHeight = videoEncoderCompatibleDimension(fittedHeight)
        let macroblocks = ((encodedWidth + 15) / 16) * ((encodedHeight + 15) / 16)
        var requiresConstrainedCapture = scale < 1
        if macroblocks > maximumMacroblocksPerFrame {
            // A source can fit the visible-luma envelope yet exceed Level 5.2
            // after codec padding. Only those boundary cases lose the final
            // partial macroblock; normal under-limit geometry stays unchanged.
            if encodedWidth >= 16 { encodedWidth -= encodedWidth % 16 }
            if encodedHeight >= 16 { encodedHeight -= encodedHeight % 16 }
            requiresConstrainedCapture = true
        }
        guard requiresConstrainedCapture else {
            return LiveShareCaptureGeometry(width: width, height: height)
        }
        return LiveShareCaptureGeometry(width: encodedWidth, height: encodedHeight)
    }

    /// Dimensions advertised to WebRTC and produced by the encoder. Software
    /// codecs can encode the capture geometry directly. H.264 aligns down by
    /// at most one pixel per axis; the native pixel buffer remains unchanged
    /// and the VideoToolbox bridge performs a top-left crop instead of a scale.
    static func streamGeometry(
        captureGeometry: LiveShareCaptureGeometry,
        codec: LiveShareVideoCodec
    ) -> LiveShareCaptureGeometry {
        guard codec == .h264 else { return captureGeometry }
        return LiveShareCaptureGeometry(
            width: videoEncoderCompatibleDimension(captureGeometry.width),
            height: videoEncoderCompatibleDimension(captureGeometry.height)
        )
    }

    static func sourceIdentifier(_ id: LiveShareSourceID) -> String {
        switch id {
        case let .window(windowID):
            "window:\(windowID.rawValue)"
        case let .fullscreen(displayID):
            "display:\(displayID.rawValue)"
        }
    }

    static func sourceIdentifier(_ source: LiveShareSource) -> String {
        sourceIdentifier(source.id)
    }

    static func sourceID(from identifier: String) -> LiveShareSourceID? {
        let pieces = identifier.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2, let rawValue = UInt32(pieces[1]) else { return nil }
        switch pieces[0] {
        case "window":
            return .window(LiveShareWindowID(rawValue: rawValue))
        case "display":
            return .fullscreen(LiveShareDisplayID(rawValue: rawValue))
        default:
            return nil
        }
    }

    /// Builds the one mixed system-audio capture request for the current Live
    /// Share selection. Window audio is application-scoped in ScreenCaptureKit,
    /// so several shared windows from one application deliberately contribute
    /// only one bundle identifier. The caller owns the request identifier so a
    /// source refresh can update an existing audio session without changing its
    /// logical identity.
    static func captureAudioRequest(
        systemAudioEnabled: Bool,
        sources: LiveShareSourceSelection,
        knownWindows: [LiveShareWindowID: ShareableCaptureWindow],
        filterDisplayID: CGDirectDisplayID,
        clipBundleIdentifier: String,
        excludedAudioApplicationBundleIdentifiers: Set<String> = [],
        filterApplicationProcessIdentifiers: Set<pid_t> = [],
        requestIdentifier: UUID
    ) -> CaptureAudioSessionRequest? {
        guard systemAudioEnabled else { return nil }

        if let fullscreen = sources.fullscreen {
            let excludedBundleIdentifiers = normalizedBundleIdentifiers(
                excludedAudioApplicationBundleIdentifiers.union([clipBundleIdentifier])
            )
            return CaptureAudioSessionRequest(
                identifier: requestIdentifier,
                scope: .system(
                    displayID: fullscreen.id.rawValue,
                    excludedBundleIdentifiers: excludedBundleIdentifiers
                ),
                filterApplicationProcessIdentifiers:
                    filterApplicationProcessIdentifiers
            )
        }

        let bundleIdentifiers: Set<String> = Set(
            sources.windows.compactMap { source in
                guard let window = knownWindows[source.id] else { return nil }
                let identifier = window.bundleIdentifier
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return identifier.isEmpty ? nil : identifier
            }
        )
        guard !bundleIdentifiers.isEmpty else { return nil }

        return CaptureAudioSessionRequest(
            identifier: requestIdentifier,
            scope: .applications(
                displayID: filterDisplayID,
                bundleIdentifiers: bundleIdentifiers
            )
        )
    }

    /// ScreenCaptureKit resolves an application's bundle identifier to the
    /// concrete running records present when an `SCContentFilter` is built.
    /// This fingerprint lets the existing audio reconciliation path rebuild
    /// that filter after a selected app launches, terminates, or restarts.
    static func audioFilterProcessIdentifiers(
        candidates: [LiveShareCaptureAudioApplicationProcessCandidate],
        excludedBundleIdentifiers: Set<String>,
        clipBundleIdentifier: String
    ) -> Set<pid_t> {
        let identifiers = normalizedBundleIdentifiers(
            excludedBundleIdentifiers.union([clipBundleIdentifier])
        )
        return Set(candidates.compactMap { candidate in
            let bundleIdentifier = candidate.bundleIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard candidate.processIdentifier > 0,
                  identifiers.contains(bundleIdentifier) else {
                return nil
            }
            return candidate.processIdentifier
        })
    }

    /// Builds the Fullscreen audio-exclusion menu from the current eligible
    /// running applications. Applications are grouped by bundle identifier
    /// because ScreenCaptureKit's audio filter is application-scoped. A saved
    /// selection remains visible even while its app is no longer running, so
    /// users can always clear a stale selection.
    static func audioExclusionApplications(
        candidates: [LiveShareCaptureAudioApplicationCandidate],
        selectedBundleIdentifiers: Set<String>,
        clipBundleIdentifier: String
    ) -> [LiveShareAudioApplicationViewSnapshot] {
        let clipIdentifier = clipBundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var applications: [String: LiveShareAudioApplicationViewSnapshot] = [:]

        for candidate in candidates {
            let identifier = candidate.bundleIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !identifier.isEmpty, identifier != clipIdentifier else { continue }
            let suppliedName = candidate.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let name = suppliedName.isEmpty ? identifier : suppliedName
            let snapshot = LiveShareAudioApplicationViewSnapshot(
                id: identifier,
                name: name,
                bundleIdentifier: identifier,
                applicationPath: candidate.applicationPath
            )
            if let current = applications[identifier] {
                // Prefer the candidate carrying an icon path, otherwise use a
                // stable localized ordering rather than transient window order.
                let candidateAddsPath =
                    current.applicationPath == nil && snapshot.applicationPath != nil
                let hasSamePathPriority =
                    (current.applicationPath == nil) == (snapshot.applicationPath == nil)
                if candidateAddsPath
                    || hasSamePathPriority
                        && snapshot.name.localizedStandardCompare(current.name)
                            == .orderedAscending {
                    applications[identifier] = snapshot
                }
            } else {
                applications[identifier] = snapshot
            }
        }

        for identifier in normalizedBundleIdentifiers(selectedBundleIdentifiers)
            where identifier != clipIdentifier && applications[identifier] == nil {
            applications[identifier] = LiveShareAudioApplicationViewSnapshot(
                id: identifier,
                name: identifier,
                bundleIdentifier: identifier,
                applicationPath: nil
            )
        }

        return applications.values.sorted { lhs, rhs in
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame
                ? lhs.bundleIdentifier < rhs.bundleIdentifier
                : comparison == .orderedAscending
        }
    }

    static func senderPolicy(
        for settings: LiveShareSettings,
        maximumBitrateBps: Int? = nil,
        bitratePriority: Double = 1
    ) -> WebRTCSenderPolicy {
        let advanced = settings.advancedVideoSettings
            .settings(for: settings.videoCodec)
            .normalized(for: settings.videoCodec)
        let maximumBitrate = maximumBitrateBps
            ?? settings.quality.maximumBitrateBitsPerSecond
        return WebRTCSenderPolicy(
            maximumBitrateBps: maximumBitrate,
            minimumBitrateBps: advanced.minimumBitratePercent.map {
                maximumBitrate * $0 / 100
            },
            maximumFramesPerSecond: settings.frameRate.rawValue,
            degradationStrategy: degradationStrategy(
                preference: advanced.degradationPreference,
                mode: settings.encodingMode
            ),
            temporalLayerCount: advanced.temporalLayerCount,
            resolutionScale: advanced.scaleResolutionDownBy ?? 1,
            bitratePriority: bitratePriority
        )
    }

    static func preferredFullscreenDisplay(
        from displays: [ShareableCaptureDisplay],
        focusedWindowFrame: CGRect?,
        primaryDisplayID: CGDirectDisplayID
    ) -> ShareableCaptureDisplay? {
        if let focusedWindowFrame {
            let candidate = displays.max { lhs, rhs in
                intersectionArea(lhs.frame, focusedWindowFrame)
                    < intersectionArea(rhs.frame, focusedWindowFrame)
            }
            if let candidate,
               intersectionArea(candidate.frame, focusedWindowFrame) > 0 {
                return candidate
            }
        }
        return displays.first(where: { $0.id == primaryDisplayID }) ?? displays.first
    }

    /// libwebrtc's H.264 path crops odd BGRA input down to even 4:2:0 output.
    /// Capture retains the exact native pixels; metadata advertises the decoded
    /// geometry so the viewer never adds a one-pixel CSS rescale.
    static func videoEncoderCompatibleDimension(_ value: Int) -> Int {
        let positive = max(2, value)
        return positive - positive % 2
    }

    private static func capturePixelFormat(
        codec: LiveShareVideoCodec,
        colorMode: LiveShareColorMode
    ) -> CaptureVideoPixelFormat {
        if colorMode == .nativeDisplay {
            return .bgra
        }
        if codec == .h264 {
            return .rec709BGRA
        }
        switch colorMode {
        case .compatibleRec709:
            return .rec709VideoRange
        case .fullRangeRec709:
            return .rec709FullRange
        case .nativeDisplay:
            return .bgra
        }
    }

    private static func normalizedBundleIdentifiers(
        _ identifiers: Set<String>
    ) -> Set<String> {
        Set(identifiers.compactMap { identifier in
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
    }

    private static func degradationStrategy(
        preference: LiveShareDegradationPreference,
        mode: LiveShareEncodingMode
    ) -> WebRTCSenderDegradationStrategy {
        switch preference {
        case .automatic:
            mode == .quality ? .resolution : .framerate
        case .preserveResolution:
            .resolution
        case .balanced:
            .balanced
        case .preserveFrameRate:
            .framerate
        case .disabled:
            .disabled
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.standardized.intersection(rhs.standardized)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }
}
