import Testing
import Foundation
@testable import AetherEngine

/// #174: the persistent reader applied backpressure by BLOCKING the URLSession delegate
/// callback until the consumer drained below winHighWater. Blocking the delegate has no
/// flow-control contract: whether the connection stops reading from the socket is a
/// transport implementation detail. Plain HTTP/1.1 happens to park after a few MB of
/// internal buffering, but the field crash (HTTPS origin, boringssl in the crashing
/// stack, iPadOS) shows the TLS/H2 path keeps pulling at line rate and buffers the
/// undelivered body in unbounded internal allocations (cold pages compress, then
/// EXC_RESOURCE at the jetsam limit). Real, contractual flow control is task
/// suspend/resume ("a task, while suspended, produces no network traffic"), the same
/// mechanism the streaming path already uses (streamHighWater / streamLowWater).
///
/// These tests run a loopback HTTP/1.1 origin that counts every body byte it manages to
/// write. The load-bearing assertion is the suspend state itself (the transport-agnostic
/// mechanism); the origin byte bound is the regression guard that catches a backpressure
/// removal without a replacement.
@Suite("AVIOReader persistent backpressure (#174)")
struct Issue174PersistentReadBackpressureTests {

    // MARK: - Loopback throttled origin

    /// Minimal blocking HTTP origin on 127.0.0.1: serves `Range: bytes=X-` with a 206 and
    /// an endless zero body, throttled to ~50 MB/s, counting bytes actually written. When
    /// the client stops reading, write() parks on the full socket buffer, so `bytesWritten`
    /// plateauing IS the observable for working flow control.
    private final class ThrottledOriginServer: @unchecked Sendable {
        let port: UInt16
        private let listenFD: Int32
        private let totalSize: Int64
        private let chunkBytes: Int
        private let throttleUs: useconds_t
        private let lock = NSLock()
        private var _bytesWritten: Int64 = 0
        private var _connFDs: [Int32] = []
        private var _stopped = false
        private var _requestedRanges: [(start: Int64, end: Int64?)] = []

        var bytesWritten: Int64 {
            lock.lock(); defer { lock.unlock() }
            return _bytesWritten
        }

        /// #220: what each request actually asked for. `end` is nil for an open-ended
        /// `bytes=X-`, which is what live sources and unresolved sizes keep using.
        var requestedRanges: [(start: Int64, end: Int64?)] {
            lock.lock(); defer { lock.unlock() }
            return _requestedRanges
        }

        var rangeRequestCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _requestedRanges.count
        }

        private var stopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return _stopped
        }

        init?(totalSize: Int64, chunkBytes: Int = 256 * 1024, throttleUs: useconds_t = 5000) {
            self.totalSize = totalSize
            self.chunkBytes = chunkBytes
            self.throttleUs = throttleUs

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, listen(fd, 4) == 0 else {
                close(fd)
                return nil
            }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            guard nameResult == 0 else {
                close(fd)
                return nil
            }
            self.listenFD = fd
            self.port = UInt16(bigEndian: bound.sin_port)

            Thread.detachNewThread { [self] in acceptLoop() }
        }

        func stop() {
            lock.lock()
            let fds = _connFDs
            _connFDs = []
            let alreadyStopped = _stopped
            _stopped = true
            lock.unlock()
            guard !alreadyStopped else { return }
            // shutdown unblocks a write parked on a full socket buffer; close alone may not.
            for fd in fds {
                shutdown(fd, SHUT_RDWR)
                close(fd)
            }
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }

        private func acceptLoop() {
            while true {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 { return }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                lock.lock()
                if _stopped {
                    lock.unlock()
                    shutdown(fd, SHUT_RDWR)
                    close(fd)
                    return
                }
                _connFDs.append(fd)
                lock.unlock()
                Thread.detachNewThread { [self] in serve(fd) }
            }
        }

        /// One connection, many requests: a bounded-range reader issues the next range on the
        /// same socket, so serving exactly one and hanging up would force a new connection per
        /// range and make the pooling measurement meaningless.
        private func serve(_ fd: Int32) {
            while !stopped {
                if !serveOneRequest(fd) { return }
            }
        }

        /// Returns false when the connection should close (client gone, or a malformed request).
        private func serveOneRequest(_ fd: Int32) -> Bool {
            guard let request = readRequestHeader(fd) else { return false }
            var offset: Int64 = 0
            var rangeEnd: Int64? = nil
            if let rangeLine = request.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range:") }),
               let eq = rangeLine.range(of: "bytes="),
               let dash = rangeLine.range(of: "-", range: eq.upperBound..<rangeLine.endIndex) {
                if let start = Int64(rangeLine[eq.upperBound..<dash.lowerBound]) { offset = start }
                let tail = rangeLine[dash.upperBound...].trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty, let end = Int64(tail) { rangeEnd = min(end, totalSize - 1) }
            }
            lock.lock()
            _requestedRanges.append((offset, rangeEnd))
            lock.unlock()

            let last = rangeEnd ?? (totalSize - 1)
            let remaining = last - offset + 1
            // Keep-alive, not close: a bounded range that tears the socket down would make every
            // refill a fresh connection and would hide exactly the pooling question under test.
            let header = "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Range: bytes \(offset)-\(last)/\(totalSize)\r\n"
                + "Content-Length: \(remaining)\r\n"
                + "Accept-Ranges: bytes\r\n"
                + "Connection: keep-alive\r\n\r\n"
            guard writeFully(fd, Array(header.utf8)) else { return false }

            let chunk = [UInt8](repeating: 0x55, count: chunkBytes)
            var served: Int64 = 0
            while served < remaining && !stopped {
                let n = Int(min(Int64(chunkBytes), remaining - served))
                guard writeBody(fd, Array(chunk[0..<n])) else { return false }
                served += Int64(n)
                if throttleUs > 0 { usleep(throttleUs) }
            }
            return true
        }

        private func readRequestHeader(_ fd: Int32) -> String? {
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            var collected = Data()
            let terminator = Data("\r\n\r\n".utf8)
            while collected.range(of: terminator) == nil {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { return nil }
                collected.append(contentsOf: buf[0..<n])
                if collected.count > 128 * 1024 { return nil }
            }
            return String(data: collected, encoding: .utf8)
        }

        private func writeFully(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
            var sent = 0
            while sent < bytes.count {
                let n = bytes[sent...].withUnsafeBytes { raw -> Int in
                    write(fd, raw.baseAddress, raw.count)
                }
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }

        /// Like writeFully but counts every byte the kernel actually accepted, including a
        /// final partial write, so a park mid-chunk is still measured accurately.
        private func writeBody(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
            var sent = 0
            while sent < bytes.count {
                let n = bytes[sent...].withUnsafeBytes { raw -> Int in
                    write(fd, raw.baseAddress, raw.count)
                }
                guard n > 0 else { return false }
                lock.lock()
                _bytesWritten += Int64(n)
                lock.unlock()
                sent += n
            }
            return true
        }
    }

    // MARK: - Tests

    @Test("stalled consumer parks the origin connection instead of buffering at line rate")
    func stalledConsumerParksOrigin() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Nobody consumes: the demux side is deliberately parked, the exact #174 shape
        // (muxer backpressured on SegmentCache high water, no read ever advances position).
        try await Task.sleep(for: .seconds(3))

        // Origin line rate here is ~50 MB/s. Without real flow control the origin keeps
        // serving (~150 MB in 3 s) into URLSession's internal buffering. With task-suspend
        // backpressure it parks at winHighWater plus socket/transport buffer slack.
        #expect(server.bytesWritten < 64 * 1024 * 1024,
                "origin served \(server.bytesWritten / (1024 * 1024)) MB into a stalled consumer")
        #expect(reader.persistentTaskIsSuspendedForTesting,
                "the persistent task must be suspended once the window exceeds winHighWater")
    }

    @Test("resuming consumption after a stall delivers fresh bytes (resume liveness)")
    func drainAfterStallResumesDelivery() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 256 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Stall long enough for the suspend to engage, then consume far more than the
        // window: delivery must keep flowing, which proves the task was resumed.
        try await Task.sleep(for: .seconds(2))

        let sliceCap = 256 * 1024
        let target = 48 * 1024 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        let deadline = Date().addingTimeInterval(30)
        while got < target && Date() < deadline {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got >= target, "only \(got / (1024 * 1024)) MB delivered after the stall")
    }

    @Test("teardown while suspended releases the task and does not hang")
    func teardownWhileSuspended() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        try reader.open()

        try await Task.sleep(for: .seconds(2))

        // Completing without a hang is the assertion; the suspended flag must be cleared
        // so the balanced resume-before-cancel actually happened.
        reader.markClosed()
        reader.close()
        #expect(!reader.persistentTaskIsSuspendedForTesting)
    }

    /// #220: bounded ranges cannot be exercised against an origin that ignores the range end.
    /// It would stream to EOF whatever was asked for, and every later assertion about window
    /// size or request count would be measuring the server's behaviour instead of the reader's.
    @Test("the test origin serves exactly the requested range and no more")
    func originHonoursFiniteRange() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        request.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data.count == 1024 * 1024)
        #expect(server.requestedRanges.first?.end == 1_048_575)
    }
}
