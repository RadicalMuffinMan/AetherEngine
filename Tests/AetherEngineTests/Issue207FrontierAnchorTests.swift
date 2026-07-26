import Foundation
import Testing
@testable import AetherEngine

/// AetherEngine#207 follow-up: the reported buffer frontier collapsed to the playhead once an opt-in
/// whole-source prefetch reached its retention budget. The frontier walk anchored on the playhead's
/// segment while `pruneOutsideWindow` anchors on the consumer's fetch target (`lo = target - backwardWindow`),
/// so the playhead's own segment is evictable and really was evicted, leaving the walk to start on a hole
/// every tick. Anchoring the walk at `max(playhead, consumerTarget)` reports the end of the contiguous
/// safe range instead: everything below the fetch target is by definition already in the consumer's buffer.
@Suite("Issue #207 buffer frontier anchor")
struct Issue207FrontierAnchorTests {

    private func makeData(_ n: Int, fill: UInt8 = 0xAA) -> Data { Data(repeating: fill, count: n) }

    /// Reproduces the field report: window past the budget, fetch target ~30 segments ahead of the
    /// playhead, so the playhead's segment falls below `lo` and is evicted as an extra.
    private func makeOptInPrefetchCache() -> SegmentCache {
        // forwardWindow = opt-in whole-source; the kept window alone (31 x 10 B) exceeds the budget,
        // which is exactly the #207 condition that makes the extras eviction run at all.
        let c = SegmentCache(forwardWindow: 2700, backwardWindow: 20, retentionBudgetBytes: 100)
        for i in 0...40 { c.store(index: i, data: makeData(10)) }
        c.declareTarget(30)   // AVPlayer's fetch target runs ahead of the playhead (~120 s)
        return c
    }

    @Test("Extras eviction really does drop the playhead's own segment (the #207 precondition)")
    func playheadSegmentIsEvictedUnderOptInPrefetch() {
        let c = makeOptInPrefetchCache()
        defer { c.close() }
        // lo = 30 - 20 = 10, so 0...9 are extras and the kept window is already over budget.
        #expect(c.peek(index: 0) == nil)
        #expect(c.peek(index: 9) == nil)
        #expect(c.peek(index: 10) != nil)
        #expect(c.peek(index: 40) != nil)
    }

    @Test("Playhead-anchored walk reports nothing cached ahead while 31 segments are resident")
    func playheadAnchoredWalkCollapses() {
        let c = makeOptInPrefetchCache()
        defer { c.close() }
        // The bug: the walk starts on a hole and returns playhead - 1, which fails the caller's
        // `frontier >= playheadIdx` guard and yields a read-ahead of 0.
        #expect(c.contiguousForwardFrontier(from: 0) == -1)
    }

    @Test("Target-anchored walk reports the resident band ahead of the consumer")
    func targetAnchoredWalkReportsFullBand() {
        let c = makeOptInPrefetchCache()
        defer { c.close() }
        #expect(c.contiguousForwardFrontier(fromPlayhead: 0) == 40)
    }

    /// The trap the reporter flagged: simply skipping the leading hole would land on a stale band that
    /// survives a backward seek (nothing forces its eviction while the budget has room) and report it as
    /// buffered, i.e. fail in the dangerous direction. Anchoring on the fetch target must stop at the
    /// hole above the freshly produced band instead.
    @Test("Backward seek does not report the stale band left above the new target")
    func backwardSeekStopsBelowStaleBand() {
        let c = makeOptInPrefetchCache()
        defer { c.close() }
        // Seek back to segment 2. hi = max(2 + 2700, highestStored 40) keeps the old band resident,
        // and the producer has only restarted far enough to write 2 and 3.
        c.declareTarget(2)
        c.store(index: 2, data: makeData(10))
        c.store(index: 3, data: makeData(10))
        #expect(c.peek(index: 40) != nil, "the stale band must still be resident for this to be a real trap")
        #expect(c.contiguousForwardFrontier(fromPlayhead: 2) == 3)
    }

    @Test("A refetch behind the playhead does not drag the anchor backwards")
    func backwardRefetchKeepsPlayheadAnchor() {
        let c = SegmentCache(forwardWindow: 10, backwardWindow: 20)
        defer { c.close() }
        for i in 0...8 { c.store(index: i, data: makeData(10)) }
        // Continuous-Audio handover refetches a segment behind the playhead; the playhead is at 8.
        c.declareTarget(5)
        #expect(c.contiguousForwardFrontier(fromPlayhead: 8) == 8)
    }

    @Test("Default window: anchor stays the playhead, behaviour unchanged")
    func defaultWindowUnchanged() {
        let c = SegmentCache(forwardWindow: 10, backwardWindow: 20)
        defer { c.close() }
        for i in [5, 6, 7, 8, 10] { c.store(index: i, data: makeData(10)) }
        c.declareTarget(5)
        #expect(c.contiguousForwardFrontier(fromPlayhead: 5) == 8)   // stops before the hole at 9
        #expect(c.contiguousForwardFrontier(fromPlayhead: 5) == c.contiguousForwardFrontier(from: 5))
    }

    @Test("Fresh cache with no declared target walks from the playhead")
    func noTargetDeclaredYet() {
        let c = SegmentCache(forwardWindow: 10, backwardWindow: 20)
        defer { c.close() }
        for i in 0...3 { c.store(index: i, data: makeData(10)) }
        // currentTargetIndex is still -1 here; max() must not pull the anchor below the playhead.
        #expect(c.contiguousForwardFrontier(fromPlayhead: 0) == 3)
    }
}
