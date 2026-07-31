import CommonCrypto
import Foundation

/// The reader resolves one immutable ENDLIST playlist and exposes its segments
/// as a blocking MPEG-TS stream. Unlike `HLSLiveIngestReader`, seeks restart the
/// same source at the segment preceding the requested playlist time. Demuxer
/// packet gating then discards frames before the exact target.
final class HLSVODIngestReader: TimeSeekableIOReader, @unchecked Sendable {
    private struct ResolvedMedia {
        let url: URL
        let segments: [HLSMediaSegment]
        let starts: [Double]
        let duration: Double
    }

    private static let maximumBufferedBytes = 32 * 1024 * 1024
    private static let maximumPlaylistBytes = 2 * 1024 * 1024
    private static let maximumCarriageProbeBytes = 512 * 1024
    private static let maxConcurrentSegmentFetches = 4

    private let playlistURL: URL
    private let httpHeaders: [String: String]
    private let session: URLSession
    private let ownsSession: Bool
    private let condition = NSCondition()
    private let keyCacheLock = NSLock()
    private var keyCache: [String: Data] = [:]

    private var resolved: ResolvedMedia?
    private var queue: [Data] = []
    private var headOffset = 0
    private var bufferedBytes = 0
    private var bytePosition: Int64 = 0
    private var generation: UInt64 = 0
    private var started = false
    private var finished = false
    private var failed = false
    private var closed = false
    private var producer: Task<Void, Never>?

    init(
        playlistURL: URL,
        httpHeaders: [String: String],
        session: URLSession? = nil
    ) {
        self.playlistURL = playlistURL
        self.httpHeaders = httpHeaders
        if let session {
            self.session = session
            ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 45
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
            ownsSession = true
        }
    }

    /// Returns a pre-resolved reader only when the finite playlist has positive
    /// content evidence for HEVC in MPEG-TS. Unknown, live, fMP4, H.264 and
    /// demuxed-audio shapes stay on the existing native remote-HLS route.
    static func makeIfHEVCMPEGTS(
        playlistURL: URL,
        httpHeaders: [String: String],
        session: URLSession? = nil
    ) async throws -> HLSVODIngestReader? {
        let reader = HLSVODIngestReader(
            playlistURL: playlistURL,
            httpHeaders: httpHeaders,
            session: session
        )
        var accepted = false
        defer {
            if !accepted { reader.close() }
        }
        do {
            let media = try await reader.resolveMedia()
            guard let first = media.segments.first,
                  first.crypt == nil,
                  let segmentURL = HLSPlaylistParser.resolve(
                    uri: first.uri,
                    against: media.url
                  ) else {
                return nil
            }
            let prefix = try await reader.fetchCarriageProbe(segmentURL)
            guard LiveSegmentFormat.classify(prefix) == .mpegts,
                  MPEGTransportStreamCodecProbe.containsHEVC(prefix) else {
                return nil
            }
            reader.condition.withLock {
                reader.resolved = media
            }
            accepted = true
            return reader
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            EngineLog.emit(
                "[HLSVODIngest] carriage probe inconclusive: \(error)",
                category: .engine
            )
            return nil
        }
    }

    var mediaDuration: Double {
        condition.withLock { resolved?.duration ?? 0 }
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        startIfNeeded()
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty, !finished, !failed, !closed {
            condition.wait()
        }
        guard !failed, !closed else { return -1 }
        guard !queue.isEmpty else { return 0 }

        let available = queue[0].count - headOffset
        let count = min(available, Int(size))
        queue[0].withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.update(
                from: base.assumingMemoryBound(to: UInt8.self)
                    .advanced(by: headOffset),
                count: count
            )
        }
        headOffset += count
        bufferedBytes -= count
        bytePosition += Int64(count)
        if headOffset == queue[0].count {
            queue.removeFirst()
            headOffset = 0
        }
        condition.broadcast()
        return Int32(count)
    }

    /// Byte seeks are deliberately unsupported. SEEK_SET(0) is the capability
    /// handshake used by `CustomIOReaderBridge`; real positioning crosses the
    /// `TimeSeekableIOReader` seam in `Demuxer`.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == SEEK_SET, offset == 0 { return 0 }
        if whence == SEEK_CUR, offset == 0 {
            return condition.withLock { bytePosition }
        }
        return -1
    }

    func seek(to seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        startIfNeeded()

        condition.lock()
        while resolved == nil, !failed, !closed {
            condition.wait()
        }
        guard let resolved, !failed, !closed else {
            condition.unlock()
            return false
        }
        let containing = resolved.starts.lastIndex(where: { $0 <= seconds }) ?? 0
        // A playlist need not declare independent segments. Starting one GOP
        // earlier supplies the decoder with a random-access point; the engine's
        // existing target gate drops frames before the requested time.
        let startIndex = max(0, containing - 1)
        let previous = producer
        generation &+= 1
        let currentGeneration = generation
        queue.removeAll(keepingCapacity: true)
        headOffset = 0
        bufferedBytes = 0
        bytePosition = 0
        finished = false
        failed = false
        producer = Task.detached(priority: .userInitiated) { [self] in
            await produce(
                resolved: resolved,
                startIndex: startIndex,
                generation: currentGeneration
            )
        }
        condition.broadcast()
        condition.unlock()
        previous?.cancel()

        let targetText = String(format: "%.2f", seconds)
        let originText = String(format: "%.2f", resolved.starts[startIndex])
        EngineLog.emit(
            "[HLSVODIngest] seek target=\(targetText)s "
                + "segment=\(startIndex) origin=\(originText)s",
            category: .engine
        )
        return true
    }

    func cancel() {
        condition.lock()
        failed = true
        let task = producer
        producer = nil
        condition.broadcast()
        condition.unlock()
        task?.cancel()
    }

    func close() {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        let task = producer
        producer = nil
        queue.removeAll()
        bufferedBytes = 0
        condition.broadcast()
        condition.unlock()
        task?.cancel()
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    func makeIndependentReader() -> IOReader? {
        HLSVODIngestReader(playlistURL: playlistURL, httpHeaders: httpHeaders)
    }

    private func startIfNeeded() {
        condition.lock()
        guard !started, !closed else {
            condition.unlock()
            return
        }
        started = true
        generation &+= 1
        let currentGeneration = generation
        let preResolved = resolved
        producer = Task.detached(priority: .userInitiated) { [self] in
            do {
                let media: ResolvedMedia
                if let preResolved {
                    media = preResolved
                } else {
                    media = try await resolveMedia()
                }
                let accepted = condition.withLock { () -> Bool in
                    guard generation == currentGeneration, !closed else {
                        return false
                    }
                    resolved = media
                    condition.broadcast()
                    return true
                }
                guard accepted else {
                    return
                }
                let durationText = String(format: "%.2f", media.duration)
                EngineLog.emit(
                    "[HLSVODIngest] resolved finite MPEG-TS VOD segments=\(media.segments.count) "
                        + "duration=\(durationText)s",
                    category: .engine
                )
                await produce(
                    resolved: media,
                    startIndex: 0,
                    generation: currentGeneration
                )
            } catch is CancellationError {
            } catch {
                fail(error, generation: currentGeneration)
            }
        }
        condition.unlock()
    }

    private func produce(
        resolved: ResolvedMedia,
        startIndex: Int,
        generation: UInt64
    ) async {
        do {
            let remaining = Array(resolved.segments[startIndex...])
            try await ingestSegmentBatch(
                remaining,
                mediaURL: resolved.url,
                generation: generation
            )
            condition.withLock {
                if self.generation == generation, !closed {
                    finished = true
                    producer = nil
                    condition.broadcast()
                }
            }
        } catch is CancellationError {
        } catch {
            fail(error, generation: generation)
        }
    }

    private func ingestSegmentBatch(
        _ segments: [HLSMediaSegment],
        mediaURL: URL,
        generation: UInt64
    ) async throws {
        let resolvedSegments: [(HLSMediaSegment, URL)] = try segments.map { segment in
            guard let url = HLSPlaylistParser.resolve(uri: segment.uri, against: mediaURL) else {
                throw HLSIngestError.playlistInvalid(reason: "unresolvable segment URI")
            }
            return (segment, url)
        }

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var nextToSpawn = 0
            var nextToCommit = 0
            var ready: [Int: Data] = [:]

            func spawn(_ index: Int) {
                let item = resolvedSegments[index]
                group.addTask {
                    let bytes = try await self.fetch(item.1)
                    guard let crypt = item.0.crypt else { return (index, bytes) }
                    return (
                        index,
                        try await self.decrypt(bytes, crypt: crypt, baseURL: mediaURL)
                    )
                }
            }

            while nextToSpawn < resolvedSegments.count,
                  nextToSpawn < Self.maxConcurrentSegmentFetches {
                spawn(nextToSpawn)
                nextToSpawn += 1
            }
            while nextToCommit < resolvedSegments.count {
                try Task.checkCancellation()
                guard let (index, bytes) = try await group.next() else { break }
                ready[index] = bytes
                while let head = ready.removeValue(forKey: nextToCommit) {
                    if nextToCommit == 0,
                       LiveSegmentFormat.classify(head) != .mpegts {
                        throw HLSIngestError.unsupportedSegmentFormat
                    }
                    nextToCommit += 1
                    guard append(head, generation: generation) else {
                        group.cancelAll()
                        return
                    }
                    while nextToSpawn < resolvedSegments.count,
                          nextToSpawn < nextToCommit + Self.maxConcurrentSegmentFetches {
                        spawn(nextToSpawn)
                        nextToSpawn += 1
                    }
                }
            }
        }
    }

    private func append(_ data: Data, generation: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while self.generation == generation,
              !closed,
              bufferedBytes >= Self.maximumBufferedBytes {
            condition.wait()
        }
        guard self.generation == generation, !closed else { return false }
        queue.append(data)
        bufferedBytes += data.count
        condition.broadcast()
        return true
    }

    private func fail(_ error: Error, generation: UInt64) {
        condition.lock()
        guard self.generation == generation, !closed else {
            condition.unlock()
            return
        }
        failed = true
        producer = nil
        condition.broadcast()
        condition.unlock()
        EngineLog.emit("[HLSVODIngest] terminal: \(error)", category: .engine)
    }

    private func resolveMedia() async throws -> ResolvedMedia {
        let (root, rootURL) = try await fetchPlaylist(playlistURL)
        let media: HLSMediaPlaylist
        let mediaURL: URL
        switch root {
        case .media(let value):
            media = value
            mediaURL = rootURL
        case .master(let master):
            guard let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth }),
                  best.audioGroupID == nil,
                  let url = HLSPlaylistParser.resolve(uri: best.uri, against: rootURL) else {
                throw HLSIngestError.demuxedAudioNotSupported
            }
            let (selected, selectedURL) = try await fetchPlaylist(url)
            guard case .media(let value) = selected else {
                throw HLSIngestError.playlistInvalid(reason: "selected variant is not a media playlist")
            }
            media = value
            mediaURL = selectedURL
        }

        guard media.hasEndList else {
            throw HLSIngestError.playlistInvalid(reason: "finite VOD requires EXT-X-ENDLIST")
        }
        guard !media.hasMap else { throw HLSIngestError.unsupportedSegmentFormat }
        guard !media.hasUnsupportedEncryption else {
            throw HLSIngestError.encryptedNotSupported
        }
        var starts: [Double] = []
        starts.reserveCapacity(media.segments.count)
        var duration = 0.0
        for segment in media.segments {
            guard segment.duration.isFinite, segment.duration > 0 else {
                throw HLSIngestError.playlistInvalid(reason: "segment duration must be positive")
            }
            starts.append(duration)
            duration += segment.duration
        }
        return ResolvedMedia(
            url: mediaURL,
            segments: media.segments,
            starts: starts,
            duration: duration
        )
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await session.data(for: makeRequest(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard data.count <= Self.maximumPlaylistBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "playlist is not bounded UTF-8")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: makeRequest(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), !data.isEmpty else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        return data
    }

    private func fetchCarriageProbe(_ url: URL) async throws -> Data {
        var request = makeRequest(url)
        request.setValue(
            "bytes=0-\(Self.maximumCarriageProbeBytes - 1)",
            forHTTPHeaderField: "Range"
        )
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 || status == 206 else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        var data = Data()
        data.reserveCapacity(Self.maximumCarriageProbeBytes)
        for try await byte in bytes {
            data.append(byte)
            if data.count == Self.maximumCarriageProbeBytes { break }
        }
        guard !data.isEmpty else {
            throw HLSIngestError.unsupportedSegmentFormat
        }
        return data
    }

    private func decrypt(
        _ ciphertext: Data,
        crypt: HLSSegmentCrypt,
        baseURL: URL
    ) async throws -> Data {
        guard let keyURL = HLSPlaylistParser.resolve(uri: crypt.keyURI, against: baseURL) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "unresolvable key URI")
        }
        let key: Data
        if let cached = keyCacheLock.withLock({ keyCache[keyURL.absoluteString] }) {
            key = cached
        } else {
            let fetched = try await fetch(keyURL)
            guard fetched.count == kCCKeySizeAES128 else {
                throw HLSIngestError.segmentDecryptFailed(reason: "key length is not 16 bytes")
            }
            keyCacheLock.withLock { keyCache[keyURL.absoluteString] = fetched }
            key = fetched
        }
        guard let plaintext = HLSSegmentDecryptor.decryptAES128CBC(
            ciphertext,
            key: key,
            iv: crypt.iv
        ) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "AES-128-CBC failed")
        }
        return plaintext
    }
}

/// Bounded MPEG-TS PMT inspection. HEVC is stream_type 0x24; no URL suffix or
/// response MIME type is treated as codec evidence.
enum MPEGTransportStreamCodecProbe {
    private static let packetSize = 188

    static func containsHEVC(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard let syncOffset = (0..<min(packetSize, bytes.count)).first(
            where: { offset in
                offset + packetSize * 2 < bytes.count
                    && bytes[offset] == 0x47
                    && bytes[offset + packetSize] == 0x47
                    && bytes[offset + packetSize * 2] == 0x47
            }
        ) else {
            return false
        }

        var packetStart = syncOffset
        while packetStart + packetSize <= bytes.count {
            if packetContainsHEVC(bytes, packetStart: packetStart) {
                return true
            }
            packetStart += packetSize
        }
        return false
    }

    private static func packetContainsHEVC(
        _ bytes: [UInt8],
        packetStart: Int
    ) -> Bool {
        guard bytes[packetStart] == 0x47,
              bytes[packetStart + 1] & 0x40 != 0 else {
            return false
        }
        let adaptationControl = (bytes[packetStart + 3] >> 4) & 0x03
        guard adaptationControl == 1 || adaptationControl == 3 else {
            return false
        }
        var payload = packetStart + 4
        if adaptationControl == 3 {
            payload += 1 + Int(bytes[payload])
        }
        let packetEnd = packetStart + packetSize
        guard payload < packetEnd else { return false }
        payload += 1 + Int(bytes[payload])
        guard payload + 12 <= packetEnd, bytes[payload] == 0x02 else {
            return false
        }

        let sectionLength =
            (Int(bytes[payload + 1] & 0x0F) << 8)
                | Int(bytes[payload + 2])
        let sectionEnd = min(packetEnd, payload + 3 + sectionLength - 4)
        let programInfoLength =
            (Int(bytes[payload + 10] & 0x0F) << 8)
                | Int(bytes[payload + 11])
        var stream = payload + 12 + programInfoLength
        while stream + 5 <= sectionEnd {
            if bytes[stream] == 0x24 { return true }
            let infoLength =
                (Int(bytes[stream + 3] & 0x0F) << 8)
                    | Int(bytes[stream + 4])
            stream += 5 + infoLength
        }
        return false
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
