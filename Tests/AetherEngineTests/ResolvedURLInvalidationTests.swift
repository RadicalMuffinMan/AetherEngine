import Testing
import Foundation
@testable import AetherEngine

/// The reader pins the post-redirect URL after the first 200/206 (#12) and previously
/// dropped the pin only for auth-expiry statuses (401/403/404/410). An aggregator whose
/// redirect targets expire per connection answers every later range with a hard 5xx from
/// the pinned URL, and the reader hammered that dead URL forever instead of re-resolving
/// through the source URL for a fresh redirect.
@Suite("Resolved-URL invalidation on hard server errors")
struct ResolvedURLInvalidationTests {

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int64: Int] = [:]
        func next(for offset: Int64) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = (counts[offset] ?? 0) + 1
            counts[offset] = n
            return n
        }
    }

    @Test("a hard 500 from the pinned URL falls back to the source URL for a fresh redirect",
          .timeLimit(.minutes(2)))
    func hard500FallsBackToSourceURL() async throws {
        let firstRange: Int64 = 256 * 1024
        let attempts = AttemptCounter()
        // CDN: serves everything except the FIRST attempt at the boundary refill, which it
        // refuses with a hard 500 — the expired-redirect-target shape.
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange && attempts.next(for: offset) == 1
                    ? .status(500) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        // Source: redirects every request to the CDN, like an Xtream panel's 302 hop.
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) + 256 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == target, "read stopped at \(got) of \(target); the 500 was terminal")

        // The pin sent the refill straight to the CDN (first attempt, 500), and the fix
        // must send the RETRY through the source URL again — visible as a source-server
        // request at the boundary offset, which only exists if the pin was dropped.
        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(!sourceHitsAtBoundary.isEmpty,
                "retry never fell back to the source URL: \(source.requestLog)")
        let cdnAttemptsAtBoundary = cdn.requestLog.filter { $0.start == firstRange }.count
        #expect(cdnAttemptsAtBoundary >= 2,
                "the CDN should see the failed attempt plus the redirected retry")
    }

    @Test("hard-server-error classification excludes rate limiting")
    func classifierExcludesRateLimiting() {
        #expect(AVIOReader.isResolvedHardServerError(500))
        #expect(AVIOReader.isResolvedHardServerError(502))
        #expect(AVIOReader.isResolvedHardServerError(504))
        #expect(!AVIOReader.isResolvedHardServerError(503), "503 is rate limiting (#71)")
        #expect(!AVIOReader.isResolvedHardServerError(429))
        #expect(!AVIOReader.isResolvedHardServerError(404), "auth expiry is its own class")
        #expect(!AVIOReader.isResolvedHardServerError(200))
    }
}
