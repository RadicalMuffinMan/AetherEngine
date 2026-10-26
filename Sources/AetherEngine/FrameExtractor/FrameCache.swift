import Foundation
import CoreGraphics

/// Count-bounded LRU cache of rendered frames with mode-specific position keys.
/// Per-mode count limit caps the cache at `thumbnailLimit + previewLimit + snapshotLimit` CGImages.
/// Preview keys include exact requested time and width. Thumbnail and snapshot stores
/// retain their existing position-bucket keys.
/// Not thread-safe; FrameExtractor owns the only instance and touches it actor-isolated.
final class FrameCache {
    private struct PreviewKey: Hashable {
        let seconds: Double
        let width: Int
    }
    private let previewLimit: Int
    private var previewOrder: [PreviewKey] = []
    private var previewStore: [PreviewKey: CGImage] = [:]

    private let thumbnailLimit: Int
    private let snapshotLimit: Int
    private let thumbnailBucketSeconds: Double
    // Snapshots are frame-accurate, so a 0.1 s grid (~3 frames at 30 fps) suffices.
    private static let snapshotBucketSeconds: Double = 0.1

    // Each FrameMode case needs a matching store + order pair below, plus
    // mirroring in get/set/clear. Add both when introducing a new case.
    /// Use order per mode, front = MRU; holds bucket keys, `store` holds payloads.
    private var thumbnailOrder: [Int] = []
    private var snapshotOrder: [Int] = []
    private var thumbnailStore: [Int: CGImage] = [:]
    private var snapshotStore: [Int: CGImage] = [:]

    init(thumbnailLimit: Int, snapshotLimit: Int, thumbnailBucketSeconds: Double, previewLimit: Int = 2) {
        precondition(previewLimit >= 0, "previewLimit must not be negative")
        self.previewLimit = previewLimit
        precondition(thumbnailBucketSeconds > 0, "thumbnailBucketSeconds must be positive")
        self.thumbnailLimit = thumbnailLimit
        self.snapshotLimit = snapshotLimit
        self.thumbnailBucketSeconds = thumbnailBucketSeconds
    }

    private func bucket(_ seconds: Double, mode: FrameMode) -> Int {
        let grid = mode == .thumbnail ? thumbnailBucketSeconds : Self.snapshotBucketSeconds
        let scaled = max(0, seconds) / grid
        // Thumbnails floor to grid; snapshots round to nearest so a value within
        // half a bucket of a stored position resolves to the same entry.
        let rounded = mode == .thumbnail ? scaled.rounded(.down) : scaled.rounded()
        // Audit BIT-105: `Int(_:)` traps past `Int.max`; every such position shares the last bucket.
        return rounded < 0x1p62 ? Int(rounded) : 1 << 62
    }

    func get(mode: FrameMode, seconds: Double, targetWidth: Int = 0) -> CGImage? {
        let key = bucket(seconds, mode: mode)
        switch mode {
        case .preview:
            let previewKey = PreviewKey(seconds: seconds, width: targetWidth)
            guard let img = previewStore[previewKey] else { return nil }
            touch(&previewOrder, previewKey)
            return img
        case .thumbnail:
            guard let img = thumbnailStore[key] else { return nil }
            touch(&thumbnailOrder, key)
            return img
        case .snapshot:
            guard let img = snapshotStore[key] else { return nil }
            touch(&snapshotOrder, key)
            return img
        }
    }

    func set(_ image: CGImage, mode: FrameMode, seconds: Double, targetWidth: Int = 0) {
        let key = bucket(seconds, mode: mode)
        switch mode {
        case .preview:
            let previewKey = PreviewKey(seconds: seconds, width: targetWidth)
            previewStore[previewKey] = image
            touch(&previewOrder, previewKey)
            evict(&previewOrder, &previewStore, limit: previewLimit)
        case .thumbnail:
            thumbnailStore[key] = image
            touch(&thumbnailOrder, key)
            evict(&thumbnailOrder, &thumbnailStore, limit: thumbnailLimit)
        case .snapshot:
            snapshotStore[key] = image
            touch(&snapshotOrder, key)
            evict(&snapshotOrder, &snapshotStore, limit: snapshotLimit)
        }
    }

    func clear() {
        previewOrder.removeAll()
        previewStore.removeAll()
        thumbnailOrder.removeAll()
        snapshotOrder.removeAll()
        thumbnailStore.removeAll()
        snapshotStore.removeAll()
    }

    private func touch<Key: Hashable>(_ order: inout [Key], _ key: Key) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.insert(key, at: 0)
    }

    private func evict<Key: Hashable>(_ order: inout [Key], _ store: inout [Key: CGImage], limit: Int) {
        while store.count > limit, let lru = order.popLast() {
            store[lru] = nil
        }
    }
}
