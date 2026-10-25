import Foundation
import CoreGraphics

/// Count-bounded LRU cache keyed by mode, requested position, and requested dimensions.
/// Per-mode count limit caps the cache at `thumbnailLimit + snapshotLimit` CGImages.
/// Not thread-safe; FrameExtractor owns the only instance and touches it actor-isolated.
final class FrameCache {
    private struct Key: Hashable {
        let position: Double
        let width: CGFloat
        let height: CGFloat
    }

    private let thumbnailLimit: Int
    private let snapshotLimit: Int
    private let thumbnailBucketSeconds: Double

    // Each FrameMode case needs a matching store + order pair below, plus
    // mirroring in get/set/clear. Add both when introducing a new case.
    /// Use order per mode, front = MRU; holds bucket keys, `store` holds payloads.
    private var thumbnailOrder: [Key] = []
    private var snapshotOrder: [Key] = []
    private var thumbnailStore: [Key: CGImage] = [:]
    private var snapshotStore: [Key: CGImage] = [:]

    init(thumbnailLimit: Int, snapshotLimit: Int, thumbnailBucketSeconds: Double) {
        precondition(thumbnailBucketSeconds > 0, "thumbnailBucketSeconds must be positive")
        self.thumbnailLimit = thumbnailLimit
        self.snapshotLimit = snapshotLimit
        self.thumbnailBucketSeconds = thumbnailBucketSeconds
    }

    private func key(seconds: Double, mode: FrameMode, targetWidth: Int, maxSize: CGSize?) -> Key {
        if mode == .thumbnail {
            let bucket = (max(0, seconds) / thumbnailBucketSeconds).rounded(.down)
            // Preserve the saturating thumbnail bucket for enormous finite requests.
            return Key(position: min(bucket, 0x1p62), width: CGFloat(targetWidth), height: 0)
        }
        // Any two nearby requests can straddle a frame boundary. Accurate extraction must
        // reuse only the same request, rather than guess a frame rate with a time bucket.
        let size = maxSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        return Key(position: max(0, seconds), width: size?.width ?? 0, height: size?.height ?? 0)
    }

    func get(mode: FrameMode, seconds: Double, targetWidth: Int = 0, maxSize: CGSize? = nil) -> CGImage? {
        let key = key(seconds: seconds, mode: mode, targetWidth: targetWidth, maxSize: maxSize)
        switch mode {
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

    func set(_ image: CGImage, mode: FrameMode, seconds: Double,
             targetWidth: Int = 0, maxSize: CGSize? = nil) {
        let key = key(seconds: seconds, mode: mode, targetWidth: targetWidth, maxSize: maxSize)
        switch mode {
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
        thumbnailOrder.removeAll()
        snapshotOrder.removeAll()
        thumbnailStore.removeAll()
        snapshotStore.removeAll()
    }

    private func touch(_ order: inout [Key], _ key: Key) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.insert(key, at: 0)
    }

    private func evict(_ order: inout [Key], _ store: inout [Key: CGImage], limit: Int) {
        while store.count > limit, let lru = order.popLast() {
            store[lru] = nil
        }
    }
}
