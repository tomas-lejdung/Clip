import ClipLiveShare
import Foundation

/// One authoritative logical stream whose negotiated WebRTC media track is
/// currently available to the receiver.
public struct RemoteStreamBinding: Equatable, Sendable, Identifiable {
    public let descriptor: ClipLiveShareStreamDescriptor

    public var id: ClipLiveShareStreamID { descriptor.id }
    public var mediaTrackID: ClipLiveShareMediaTrackID { descriptor.mediaTrackID }

    public init(descriptor: ClipLiveShareStreamDescriptor) {
        self.descriptor = descriptor
    }
}

/// A reconciliation change produced when either the authoritative manifest or
/// the native WebRTC receiver tracks change.
public enum RemoteStreamRegistryChange: Equatable, Sendable {
    case bound(RemoteStreamBinding)
    case updated(previous: RemoteStreamBinding, current: RemoteStreamBinding)
    case unbound(RemoteStreamBinding)
}

/// Binds Clip's opaque logical stream identities to native media-track IDs.
///
/// Unified Plan does not guarantee whether `didAddReceiver` or Clip's reliable
/// manifest arrives first. This value type accepts either order and reports a
/// stream only after both halves exist. Replacing a manifest is authoritative:
/// removed/inactive entries are unbound, while tracks can remain negotiated
/// and become bound again if a later manifest activates them.
public struct RemoteStreamRegistry: Sendable {
    private var sessionID: ClipLiveShareSessionID?
    private var descriptorsByStreamID: [
        ClipLiveShareStreamID: ClipLiveShareStreamDescriptor
    ] = [:]
    private var availableMediaTrackIDs: Set<ClipLiveShareMediaTrackID> = []
    private var bindingsByStreamID: [ClipLiveShareStreamID: RemoteStreamBinding] = [:]

    public init() {}

    public var bindings: [RemoteStreamBinding] {
        bindingsByStreamID.values.sorted(by: Self.bindingOrder)
    }

    public var pendingDescriptors: [ClipLiveShareStreamDescriptor] {
        descriptorsByStreamID.values
            .filter { descriptor in
                descriptor.active
                    && !availableMediaTrackIDs.contains(descriptor.mediaTrackID)
            }
            .sorted(by: Self.descriptorOrder)
    }

    public var negotiatedMediaTrackIDs: Set<ClipLiveShareMediaTrackID> {
        availableMediaTrackIDs
    }

    /// Replaces the complete authoritative manifest for one peer session.
    @discardableResult
    public mutating func apply(
        _ manifest: ClipLiveShareStreamManifest
    ) -> [RemoteStreamRegistryChange] {
        if let sessionID, sessionID != manifest.sessionID {
            descriptorsByStreamID.removeAll(keepingCapacity: true)
        }
        sessionID = manifest.sessionID
        descriptorsByStreamID = Dictionary(
            uniqueKeysWithValues: manifest.streams.map { ($0.id, $0) }
        )
        return reconcile()
    }

    /// Records a native video receiver track. Repeated callbacks for the same
    /// track are idempotent, which is important during Unified Plan reoffers.
    @discardableResult
    public mutating func registerMediaTrack(
        _ mediaTrackID: ClipLiveShareMediaTrackID
    ) -> [RemoteStreamRegistryChange] {
        guard availableMediaTrackIDs.insert(mediaTrackID).inserted else { return [] }
        return reconcile()
    }

    @discardableResult
    public mutating func removeMediaTrack(
        _ mediaTrackID: ClipLiveShareMediaTrackID
    ) -> [RemoteStreamRegistryChange] {
        guard availableMediaTrackIDs.remove(mediaTrackID) != nil else { return [] }
        return reconcile()
    }

    /// Clears manifest and track state and returns deterministic unbind events.
    @discardableResult
    public mutating func reset() -> [RemoteStreamRegistryChange] {
        let removed = bindings.map(RemoteStreamRegistryChange.unbound)
        sessionID = nil
        descriptorsByStreamID.removeAll(keepingCapacity: false)
        availableMediaTrackIDs.removeAll(keepingCapacity: false)
        bindingsByStreamID.removeAll(keepingCapacity: false)
        return removed
    }

    private mutating func reconcile() -> [RemoteStreamRegistryChange] {
        let previous = bindingsByStreamID
        let pairs: [(ClipLiveShareStreamID, RemoteStreamBinding)] =
            descriptorsByStreamID.values.compactMap { descriptor in
                guard descriptor.active,
                      availableMediaTrackIDs.contains(descriptor.mediaTrackID) else {
                    return nil
                }
                let binding = RemoteStreamBinding(descriptor: descriptor)
                return (descriptor.id, binding)
            }
        let current: [ClipLiveShareStreamID: RemoteStreamBinding] = Dictionary(
            uniqueKeysWithValues: pairs
        )
        bindingsByStreamID = current

        var changes: [RemoteStreamRegistryChange] = []
        for old in previous.values.sorted(by: Self.bindingOrder) {
            guard let replacement = current[old.id] else {
                changes.append(.unbound(old))
                continue
            }
            if old.mediaTrackID != replacement.mediaTrackID {
                changes.append(.unbound(old))
                changes.append(.bound(replacement))
            } else if old != replacement {
                changes.append(.updated(previous: old, current: replacement))
            }
        }
        for new in current.values.sorted(by: Self.bindingOrder)
            where previous[new.id] == nil
        {
            changes.append(.bound(new))
        }
        return changes
    }

    private static func bindingOrder(
        _ lhs: RemoteStreamBinding,
        _ rhs: RemoteStreamBinding
    ) -> Bool {
        descriptorOrder(lhs.descriptor, rhs.descriptor)
    }

    private static func descriptorOrder(
        _ lhs: ClipLiveShareStreamDescriptor,
        _ rhs: ClipLiveShareStreamDescriptor
    ) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
