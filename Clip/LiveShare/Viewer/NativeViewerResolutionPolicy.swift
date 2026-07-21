import CoreGraphics
import Foundation

enum NativeViewerScaleMode: String, CaseIterable, Equatable, Sendable {
    case automatic
    case actualPixels
    case fit
}

struct NativeViewerResolutionRequest: Equatable, Sendable {
    let decodedPixelSize: CGSize
    let destinationBackingScale: CGFloat
    let maximumContentSize: CGSize
    let mode: NativeViewerScaleMode
}

struct NativeViewerResolution: Equatable, Sendable {
    /// The video content size in AppKit points. Window chrome and Clip's
    /// identity border are deliberately excluded.
    let contentSize: CGSize
    /// Destination backing pixels used for one decoded source pixel.
    let destinationPixelsPerSourcePixel: CGFloat
    let isFitted: Bool
}

enum NativeViewerResolutionPolicy {
    static func resolve(_ request: NativeViewerResolutionRequest) -> NativeViewerResolution? {
        guard request.decodedPixelSize.width.isFinite,
              request.decodedPixelSize.height.isFinite,
              request.decodedPixelSize.width > 0,
              request.decodedPixelSize.height > 0,
              request.destinationBackingScale.isFinite,
              request.destinationBackingScale > 0,
              request.maximumContentSize.width.isFinite,
              request.maximumContentSize.height.isFinite,
              request.maximumContentSize.width > 0,
              request.maximumContentSize.height > 0 else {
            return nil
        }

        let actualPointSize = CGSize(
            width: request.decodedPixelSize.width / request.destinationBackingScale,
            height: request.decodedPixelSize.height / request.destinationBackingScale
        )
        let fitScale = min(
            1,
            request.maximumContentSize.width / actualPointSize.width,
            request.maximumContentSize.height / actualPointSize.height
        )
        let shouldFit = switch request.mode {
        case .automatic:
            fitScale < 1
        case .actualPixels:
            false
        case .fit:
            true
        }
        let pointScale = shouldFit ? fitScale : 1

        return NativeViewerResolution(
            contentSize: CGSize(
                width: max(1, floor(actualPointSize.width * pointScale)),
                height: max(1, floor(actualPointSize.height * pointScale))
            ),
            destinationPixelsPerSourcePixel: pointScale,
            isFitted: pointScale < 1
        )
    }
}

/// Prevents short-lived adaptive encoder dimensions from repeatedly resizing a
/// native window. An explicit authoritative geometry revision can commit as
/// soon as a matching frame arrives; otherwise a new decoded size must remain
/// stable for several consecutive frames.
struct NativeViewerDimensionStabilizer: Equatable, Sendable {
    let requiredConsecutiveFrames: Int

    private(set) var committedPixelSize: CGSize?
    private(set) var committedRevision: UInt64 = 0
    private var candidatePixelSize: CGSize?
    private var candidateFrameCount = 0

    init(requiredConsecutiveFrames: Int = 8) {
        self.requiredConsecutiveFrames = max(2, requiredConsecutiveFrames)
    }

    mutating func observe(
        decodedPixelSize: CGSize,
        authoritativePixelSize: CGSize?,
        stateRevision: UInt64
    ) -> CGSize? {
        guard decodedPixelSize.width.isFinite,
              decodedPixelSize.height.isFinite,
              decodedPixelSize.width > 0,
              decodedPixelSize.height > 0 else {
            return nil
        }

        if committedPixelSize == nil {
            return commit(decodedPixelSize, revision: stateRevision)
        }
        if decodedPixelSize == committedPixelSize {
            resetCandidate()
            committedRevision = max(committedRevision, stateRevision)
            return nil
        }

        if stateRevision > committedRevision,
           authoritativePixelSize == decodedPixelSize {
            return commit(decodedPixelSize, revision: stateRevision)
        }

        if candidatePixelSize == decodedPixelSize {
            candidateFrameCount += 1
        } else {
            candidatePixelSize = decodedPixelSize
            candidateFrameCount = 1
        }
        guard candidateFrameCount >= requiredConsecutiveFrames else { return nil }
        return commit(decodedPixelSize, revision: stateRevision)
    }

    private mutating func commit(_ size: CGSize, revision: UInt64) -> CGSize {
        committedPixelSize = size
        committedRevision = max(committedRevision, revision)
        resetCandidate()
        return size
    }

    private mutating func resetCandidate() {
        candidatePixelSize = nil
        candidateFrameCount = 0
    }
}
