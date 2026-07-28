import Testing
import Foundation
@testable import AetherEngine

/// #220: the reader used to ask for `bytes=X-`, the whole rest of the file, and then regulate
/// the resulting flow by suspending the URLSession task. `suspend()` is advisory, so on a link
/// that never saturates the socket the transport keeps delivering and the window grows without
/// bound. Asking for a fixed amount at a time makes the overshoot impossible rather than caught:
/// the origin cannot send more than was requested.
@Suite("Bounded persistent ranges (#220)")
struct Issue220BoundedRangeTests {

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
    }

    @Test("a VOD read asks for a bounded range, not the rest of the file")
    func vodRequestsBoundedRange() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256 * 1024)
        defer { buf.deallocate() }
        _ = reader.read(into: buf, size: 256 * 1024)

        let ranges = server.requestedRanges
        let bounded = try #require(ranges.first(where: { $0.end != nil }),
                                   "every VOD request was open-ended: \(ranges)")
        #expect(bounded.end! - bounded.start + 1 == AVIOReader.persistentRangeBytes)
    }
}
