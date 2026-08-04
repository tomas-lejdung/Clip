import AppKit
import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation

enum MeshRoomConnectionPresentationPolicy {
    static func effectiveTransportRoute(
        statisticsRoute: WebRTCConnectionRoute?,
        retainedRoute: WebRTCConnectionRoute?
    ) -> WebRTCConnectionRoute? {
        if let statisticsRoute, statisticsRoute != .unknown {
            return statisticsRoute
        }
        return retainedRoute
    }

    static func route(
        connectionState: WebRTCPeerConnectionState?,
        transportRoute: WebRTCConnectionRoute?,
        hasReachedLive: Bool
    ) -> MeshRoomConnectionRoute {
        guard let connectionState else {
            return hasReachedLive ? .disconnected : .connecting
        }
        guard connectionState == .connected else {
            return .disconnected
        }
        switch transportRoute {
        case .direct:
            return .direct
        case .relay:
            return .turn
        case .unknown, nil:
            // Selected-candidate route classification is optional diagnostics
            // metadata. It cannot override an established WebRTC connection.
            return .connected
        }
    }
}

enum MeshParticipantMenuBarStatus: Equatable, Sendable {
    case ready
    case live
    case admissionRequest
    case reconnecting
    case failed

    var symbolName: String {
        switch self {
        case .ready:
            "dot.radiowaves.left.and.right"
        case .live:
            "record.circle.fill"
        case .admissionRequest:
            "person.crop.circle.badge.questionmark"
        case .reconnecting:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .ready:
            String(localized: "Clip Live Share is ready")
        case .live:
            String(localized: "Clip Live Share is live")
        case .admissionRequest:
            String(localized: "A participant is waiting to join Clip Live Share")
        case .reconnecting:
            String(localized: "Clip Live Share is reconnecting")
        case .failed:
            String(localized: "Clip Live Share needs attention")
        }
    }

    static func visible(
        base: MeshParticipantMenuBarStatus,
        hasPendingAdmission: Bool
    ) -> MeshParticipantMenuBarStatus {
        if hasPendingAdmission, base != .failed {
            return .admissionRequest
        }
        return base
    }
}

enum MeshRemoteWindowClosePolicy {
    static func shouldConfirmLeave(
        visibleRemoteWindowCount: Int,
        hasRemoteAudio: Bool
    ) -> Bool {
        visibleRemoteWindowCount == 1 && hasRemoteAudio
    }
}

enum MeshLocalSourceOverlayGeometry {
    struct ScreenFrame: Equatable {
        let displayID: CGDirectDisplayID
        let quartzFrame: CGRect
        let appKitFrame: CGRect
    }

    static func appKitFrame(
        for source: LiveShareSource,
        screenFrames: [ScreenFrame],
        quartzWindowFrame: CGRect?
    ) -> CGRect? {
        switch source {
        case let .fullscreen(display):
            return screenFrames.first {
                $0.displayID == display.id.rawValue
            }?.appKitFrame
        case .window:
            guard let quartzWindowFrame else { return nil }
            guard let screen = screenFrames.max(by: {
                intersectionArea($0.quartzFrame, quartzWindowFrame)
                    < intersectionArea($1.quartzFrame, quartzWindowFrame)
            }) else { return nil }
            return LiveShareWindowCoordinateConversion.appKitFrame(
                for: quartzWindowFrame,
                quartzDisplayFrame: screen.quartzFrame,
                appKitDisplayFrame: screen.appKitFrame,
                // The collaboration mask is calculated in WindowServer's
                // full-window coordinate space. Its panel must represent that
                // same extent; clipping here would rescale off-display mask
                // fragments back onto the visible Retina display.
                preservingFullWindowExtent: true
            )
        }
    }

    private static func intersectionArea(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> CGFloat {
        let value = lhs.intersection(rhs)
        guard !value.isNull, !value.isInfinite else { return 0 }
        return max(0, value.width) * max(0, value.height)
    }
}
