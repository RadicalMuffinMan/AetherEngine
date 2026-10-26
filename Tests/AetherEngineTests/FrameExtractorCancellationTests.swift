import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import AetherEngine

@Suite("Still request cancellation", .timeLimit(.minutes(1)))
struct FrameExtractorCancellationTests {
    @Test("A cache hit supersedes an older decode", arguments: [FrameMode.thumbnail, .preview, .snapshot])
    func cacheHitSupersedesDecode(mode: FrameMode) async throws {
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = FrameExtractor(reader: reader, formatHint: "mpegts")
        let cached = try #require(await request(extractor, mode: mode, seconds: 2))
        reader.arm()
        let older = Task { await request(extractor, mode: mode, seconds: 22) }
        defer { reader.release(); older.cancel() }
        try await waitFor { reader.isBlocked }
        let hit = await request(extractor, mode: mode, seconds: 2)
        #expect(hit === cached)
        reader.release()
        #expect(await older.value == nil, "a superseded request must not publish its late frame")
        await extractor.shutdown()
    }

    @Test("Cancelling the caller discards a decode waiting on I/O")
    func callerCancellation() async throws {
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = FrameExtractor(reader: reader, formatHint: "mpegts")
        reader.arm()
        let pending = Task { await extractor.preview(at: 2, maxWidth: 16) }
        defer { reader.release(); pending.cancel() }
        try await waitFor { reader.isBlocked }
        pending.cancel()
        reader.release()
        #expect(await pending.value == nil)
        #expect(await extractor.preview(at: 2, maxWidth: 16) != nil,
                "cancellation must not poison a later request")
        await extractor.shutdown()
    }

    @Test("An already-cancelled caller cannot receive a cached frame")
    func cancelledCacheHit() async throws {
        let extractor = FrameExtractor(reader: DataIOReader(data: try LongGOPTransportStreamFixture.data()),
                                       formatHint: "mpegts")
        _ = try #require(await extractor.preview(at: 2, maxWidth: 16))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await extractor.preview(at: 2, maxWidth: 16)
        }
        #expect(await cancelled.value == nil)
        #expect(await extractor.preview(at: 2, maxWidth: 16) != nil)
        await extractor.shutdown()
    }

    @Test("A yielded preview retires an older decode without starting another")
    func yieldedRequestSupersedesDecode() async throws {
        let starved = Mutex(false)
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = FrameExtractor(reader: reader, formatHint: "mpegts",
                                       yieldWhile: { starved.withLock { $0 } })
        _ = try #require(await extractor.preview(at: 2, maxWidth: 16))
        reader.arm()
        let older = Task { await extractor.preview(at: 22, maxWidth: 16) }
        defer { reader.release(); older.cancel() }
        try await waitFor { reader.isBlocked }
        starved.withLock { $0 = true }
        #expect(await extractor.preview(at: 25, maxWidth: 16) == nil)
        reader.release()
        #expect(await older.value == nil)
        await extractor.shutdown()
    }

    @Test("A cancelled cache request leaves another caller's valid decode alone")
    func cancelledRequestDoesNotSupersedeDecode() async throws {
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = FrameExtractor(reader: reader, formatHint: "mpegts")
        _ = try #require(await extractor.preview(at: 2, maxWidth: 16))
        reader.arm()
        let older = Task { await extractor.preview(at: 22, maxWidth: 16) }
        defer { reader.release(); older.cancel() }
        try await waitFor { reader.isBlocked }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await extractor.preview(at: 2, maxWidth: 16)
        }
        #expect(await cancelled.value == nil)
        reader.release()
        #expect(await older.value != nil)
        await extractor.shutdown()
    }

    private func request(_ extractor: FrameExtractor, mode: FrameMode, seconds: Double) async -> CGImage? {
        switch mode {
        case .thumbnail: await extractor.thumbnail(at: seconds, maxWidth: 16)
        case .preview: await extractor.preview(at: seconds, maxWidth: 16)
        case .snapshot: await extractor.snapshot(at: seconds, maxSize: CGSize(width: 16, height: 16))
        }
    }
}

/// The production decode queue blocks at a real source operation, while the extractor actor can
/// accept a newer request. The condition protects only this one-shot gate; DataIOReader owns its cursor.
private final class StillGateReader: IOReader, @unchecked Sendable {
    private let reader: DataIOReader
    private let condition = NSCondition()
    private var armed = false
    private var blocked = false
    private var released = false

    init(data: Data) { reader = DataIOReader(data: data) }
    var discImageProbeEnabled: Bool { false }
    var isBlocked: Bool {
        condition.lock(); defer { condition.unlock() }
        return blocked
    }
    func arm() {
        condition.lock(); defer { condition.unlock() }
        armed = true
        blocked = false
        released = false
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
    private func waitAtGate() {
        condition.lock(); defer { condition.unlock() }
        guard armed else { return }
        armed = false
        blocked = true
        while !released { condition.wait() }
    }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        waitAtGate()
        return reader.read(buffer, size: size)
    }
    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence != 65536 { waitAtGate() }
        return reader.seek(offset: offset, whence: whence)
    }
    func cancel() { release() }
    func close() { release(); reader.close() }
}
