import Darwin
import Foundation

/// Puts the engine between AVPlayer and an HLS origin.
///
/// AVPlayer resolves a remote URL through its own networking. No delegate on
/// the asset is ever asked about the certificate, and an ATS exception does
/// not cover it either, so an origin behind a self signed or private CA
/// certificate cannot play on the native remote HLS route however the host has
/// configured trust. Pointing the player at a loopback http address moves the
/// https request onto a URLSession the engine owns, which is where `EngineTLS`
/// decides trust.
///
/// Playlists are rewritten on the way through, so every variant, rendition,
/// key and segment the player goes on to ask for arrives here too. Anything
/// that is not a playlist is relayed byte for byte.
final class HLSReverseProxyServer: @unchecked Sendable {

    /// The single path the player is ever pointed at. The origin rides in the
    /// query so one route covers playlists, keys and segments alike.
    static let proxyPath = "/aether-tls-proxy"
    private static let originQueryKey = "origin"

    private let stateLock = NSLock()
    private var listenFd: Int32 = -1
    private var shouldStop = false
    private var clientFds = Set<Int32>()
    private var port: UInt16 = 0

    /// Origins this server will fetch, as scheme://host:port. Seeded by
    /// `proxyURL(for:)` and grown as playlists reveal where their own
    /// sub-resources live, so a stream split across hosts keeps working while
    /// a request naming somewhere nobody advertised is still refused.
    private var allowedOrigins = Set<String>()

    /// Sent upstream on every fetch. Origins that gate on Referer, User-Agent
    /// or Authorization need these, and they can no longer ride on the asset
    /// because the asset now points at loopback.
    private var upstreamHeaders: [String: String] = [:]

    private let acceptQueue = DispatchQueue(
        label: "org.aether.hlsreverseproxy.accept", qos: .userInitiated)
    private let workQueue = DispatchQueue(
        label: "org.aether.hlsreverseproxy.work", qos: .userInitiated, attributes: .concurrent)

    /// Built in init rather than on first use: connections are handled
    /// concurrently, and a lazy var raced by two of them can build two
    /// sessions where only one is ever invalidated.
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(
            configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }

    // MARK: - Lifecycle

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw HLSLocalServerError.socketCreate(errno: errno) }

        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        // Loopback only. This server fetches whatever URL a request names, so
        // unlike the segment server it must not be reachable from the network
        // the device is on.
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw HLSLocalServerError.bind(errno: err)
        }

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw HLSLocalServerError.listen(errno: err)
        }

        var actual = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &actualLen)
            }
        }
        guard nameResult == 0 else {
            let err = errno
            close(fd)
            throw HLSLocalServerError.getsockname(errno: err)
        }

        stateLock.lock()
        listenFd = fd
        port = UInt16(bigEndian: actual.sin_port)
        shouldStop = false
        stateLock.unlock()

        EngineLog.emit(
            "[HLSReverseProxy] listening on 127.0.0.1:\(UInt16(bigEndian: actual.sin_port))",
            category: .hlsServer)

        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        stateLock.lock()
        shouldStop = true
        let fdToClose = listenFd
        listenFd = -1
        port = 0
        allowedOrigins.removeAll()
        upstreamHeaders.removeAll()
        let clients = clientFds
        clientFds.removeAll()
        stateLock.unlock()

        // shutdown before close, and shutdown only on the client fds, for the
        // same reasons the segment server does it: a released fd number can be
        // recycled while a handler still believes it owns it.
        if fdToClose >= 0 {
            shutdown(fdToClose, SHUT_RDWR)
            close(fdToClose)
        }
        for fd in clients { shutdown(fd, SHUT_RDWR) }
        session.invalidateAndCancel()
    }

    // MARK: - Address the player is given

    /// Loopback URL standing in for `origin`, or nil when the server is not
    /// listening or the origin has no host to fetch from.
    func proxyURL(for origin: URL, httpHeaders: [String: String] = [:]) -> URL? {
        guard let key = Self.originKey(for: origin) else { return nil }
        stateLock.lock()
        let listeningPort = port
        allowedOrigins.insert(key)
        if !httpHeaders.isEmpty { upstreamHeaders = httpHeaders }
        stateLock.unlock()
        guard listeningPort != 0 else { return nil }
        return Self.localURL(for: origin, port: listeningPort)
    }

    /// Port the server bound, or 0 when it is not listening.
    var listeningPort: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return port
    }

    /// scheme://host:port for `url`, which is the granularity the allow list
    /// works at. Nil when the URL names no host.
    static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    static func localURL(for origin: URL, port: UInt16) -> URL? {
        // Encoding everything outside the alphanumerics keeps the origin's own
        // query, which on a Jellyfin stream carries the api key and the play
        // session, from being read as part of this URL's query.
        guard
            let encoded = origin.absoluteString.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(
            string: "http://127.0.0.1:\(port)\(proxyPath)?\(originQueryKey)=\(encoded)")
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let stopping = shouldStop
            let fd = listenFd
            stateLock.unlock()
            if stopping || fd < 0 { return }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &clientLen)
                }
            }
            if clientFd < 0 {
                let err = errno
                if err == EBADF || err == EINVAL { return }
                if err == EINTR || err == EAGAIN || err == ECONNABORTED { continue }
                EngineLog.emit("[HLSReverseProxy] accept failed errno=\(err)", category: .hlsServer)
                continue
            }

            var on: Int32 = 1
            _ = setsockopt(
                clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 60, tv_usec: 0)
            _ = setsockopt(
                clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            stateLock.lock()
            clientFds.insert(clientFd)
            stateLock.unlock()

            workQueue.async { [weak self] in self?.handleConnection(clientFd) }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer {
            stateLock.lock()
            clientFds.remove(fd)
            stateLock.unlock()
            close(fd)
        }
        while true {
            stateLock.lock()
            let stopping = shouldStop
            stateLock.unlock()
            if stopping { return }
            guard let request = readHTTPRequest(fd) else { return }
            guard handle(request: request, on: fd) else { return }
        }
    }

    /// Reads to the end of the headers. A proxied URL carries the whole origin
    /// percent encoded, so the ceiling is well above the segment server's.
    private func readHTTPRequest(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n == 0 { return nil }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                return nil
            }
            buffer.append(chunk, count: n)
            if let end = HLSLocalServer.findHeadersTerminator(buffer) {
                return buffer.prefix(end + 4)
            }
            if buffer.count > 65536 {
                EngineLog.emit(
                    "[HLSReverseProxy] request too large bytes=\(buffer.count)",
                    category: .hlsServer)
                return nil
            }
        }
    }

    // MARK: - Request handling

    /// Returns false when the connection should close.
    private func handle(request: Data, on fd: Int32) -> Bool {
        let text = String(decoding: request, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return sendStatus("400 Bad Request", to: fd) }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            return sendStatus("405 Method Not Allowed", to: fd)
        }

        guard let origin = Self.originURL(fromTarget: String(parts[1])) else {
            return sendStatus("400 Bad Request", to: fd)
        }
        guard let key = Self.originKey(for: origin) else {
            return sendStatus("400 Bad Request", to: fd)
        }

        stateLock.lock()
        let permitted = allowedOrigins.contains(key)
        let headers = upstreamHeaders
        stateLock.unlock()
        guard permitted else {
            EngineLog.emit(
                "[HLSReverseProxy] -> 403 origin was never advertised: \(key)",
                category: .hlsServer)
            return sendStatus("403 Forbidden", to: fd)
        }

        let range = Self.headerValue(named: "range", in: lines)
        guard let fetched = fetch(origin: origin, headers: headers, range: range) else {
            return sendStatus("502 Bad Gateway", to: fd)
        }

        var body = fetched.body
        var contentType = fetched.contentType ?? "application/octet-stream"
        if Self.looksLikePlaylist(url: origin, contentType: fetched.contentType) {
            let rewritten = rewritePlaylist(
                String(decoding: body, as: UTF8.self), relativeTo: origin)
            body = Data(rewritten.utf8)
            contentType = "application/vnd.apple.mpegurl"
        }

        var header = "HTTP/1.1 \(fetched.status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        if let contentRange = fetched.contentRange {
            header += "Content-Range: \(contentRange)\r\n"
        }
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: keep-alive\r\n\r\n"

        guard writeAll(fd: fd, data: Data(header.utf8)) else { return false }
        if method == "HEAD" { return true }
        return writeAll(fd: fd, data: body)
    }

    /// Pulls the origin back out of a request target such as
    /// `/aether-tls-proxy?origin=https%3A%2F%2F...`.
    static func originURL(fromTarget target: String) -> URL? {
        guard let marker = target.range(of: "?\(originQueryKey)=") else { return nil }
        guard target.hasPrefix(proxyPath) else { return nil }
        let encoded = String(target[marker.upperBound...])
        guard let decoded = encoded.removingPercentEncoding, !decoded.isEmpty else { return nil }
        return URL(string: decoded)
    }

    static func headerValue(named name: String, in lines: [String]) -> String? {
        let wanted = name.lowercased() + ":"
        for line in lines where line.lowercased().hasPrefix(wanted) {
            return line.dropFirst(wanted.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func looksLikePlaylist(url: URL, contentType: String?) -> Bool {
        if let type = contentType?.lowercased(), type.contains("mpegurl") || type.contains("m3u") {
            return true
        }
        let path = url.path.lowercased()
        return path.hasSuffix(".m3u8") || path.hasSuffix(".m3u")
    }

    // MARK: - Upstream

    private struct UpstreamResponse {
        let status: String
        let body: Data
        let contentType: String?
        let contentRange: String?
    }

    /// Blocking fetch. Each connection already runs on its own work queue slot,
    /// and the socket write that follows is blocking too, so waiting here costs
    /// nothing the response was not going to wait for anyway.
    private func fetch(origin: URL, headers: [String: String], range: String?)
        -> UpstreamResponse?
    {
        var request = URLRequest(url: origin)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }

        // The completion writes the box before it signals and nothing reads it
        // until the wait returns, so the semaphore is the whole synchronisation.
        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome.failure = error
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            outcome.response = UpstreamResponse(
                status: "\(http.statusCode) \(Self.reasonPhrase(http.statusCode))",
                body: data ?? Data(),
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                contentRange: http.value(forHTTPHeaderField: "Content-Range"))
        }
        task.resume()
        semaphore.wait()

        if let failure = outcome.failure {
            EngineLog.emit(
                "[HLSReverseProxy] upstream failed \(origin.lastPathComponent): "
                    + "\((failure as NSError).code) \(failure.localizedDescription)",
                category: .hlsServer)
            return nil
        }
        return outcome.response
    }

    private final class Outcome: @unchecked Sendable {
        var response: UpstreamResponse?
        var failure: Error?
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    // MARK: - Playlist rewriting

    /// Sends every URI in the playlist back through this server. A relative URI
    /// is resolved against the playlist it came from first, so what the player
    /// sees is always absolute and always local.
    func rewritePlaylist(_ playlist: String, relativeTo origin: URL) -> String {
        stateLock.lock()
        let listeningPort = port
        stateLock.unlock()
        guard listeningPort != 0 else { return playlist }

        var discovered = Set<String>()
        let rewriteOne: (String) -> String = { raw in
            guard let resolved = URL(string: raw, relativeTo: origin)?.absoluteURL,
                let local = Self.localURL(for: resolved, port: listeningPort)
            else { return raw }
            if let key = Self.originKey(for: resolved) { discovered.insert(key) }
            return local.absoluteString
        }

        var output: [String] = []
        // Split on \n and drop a trailing \r rather than splitting on any
        // newline, which would read a CRLF playlist as having a blank line
        // between every real one. The output is \n throughout, which AVPlayer
        // reads the same as what came in.
        for rawLine in playlist.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                output.append(line)
            } else if trimmed.hasPrefix("#") {
                output.append(Self.rewriteURIAttribute(in: line, using: rewriteOne))
            } else {
                output.append(rewriteOne(trimmed))
            }
        }

        if !discovered.isEmpty {
            stateLock.lock()
            allowedOrigins.formUnion(discovered)
            stateLock.unlock()
        }
        return output.joined(separator: "\n")
    }

    /// Rewrites the `URI="..."` value a tag carries, which is how keys, maps,
    /// renditions and i-frame variants name what they need. Tags without one
    /// come back untouched.
    static func rewriteURIAttribute(in line: String, using rewrite: (String) -> String) -> String {
        guard let attr = line.range(of: "URI=\"") else { return line }
        let afterQuote = attr.upperBound
        guard let closing = line[afterQuote...].firstIndex(of: "\"") else { return line }
        let value = String(line[afterQuote..<closing])
        guard !value.isEmpty else { return line }
        return line.replacingCharacters(in: afterQuote..<closing, with: rewrite(value))
    }

    // MARK: - Socket writes

    private func sendStatus(_ status: String, to fd: Int32) -> Bool {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Length: 0\r\n"
        header += "Connection: keep-alive\r\n\r\n"
        return writeAll(fd: fd, data: Data(header.utf8))
    }

    @discardableResult
    private func writeAll(fd: Int32, data: Data) -> Bool {
        var written = 0
        let total = data.count
        if total == 0 { return true }
        while written < total {
            let result = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base.advanced(by: written), total - written, 0)
            }
            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            if result == 0 { return false }
            written += result
        }
        return true
    }
}
