import Foundation
import XCTest
@testable import AetherEngine

/// #268: HEVC carried in finite MPEG-TS HLS must be identified from the
/// playlist and PMT, then exposed through the seekable VOD ingest rather than
/// handed to AVPlayer's black native path.
final class Issue268HLSVODIngestTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Issue268URLProtocol.reset()
    }

    func testDirectMediaPlaylistBuildsSeekableHEVCReader() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/media.m3u8"))
        let segment = try XCTUnwrap(URL(string: "https://vod.test/segment.ts"))
        Issue268URLProtocol.bodyByURL[root.absoluteString] = mediaPlaylist("segment.ts")
        Issue268URLProtocol.bodyByURL[segment.absoluteString] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: ["X-Fixture": "allowed"],
            session: session
        )
        let admitted = try XCTUnwrap(reader)
        defer { admitted.close() }

        XCTAssertEqual(admitted.mediaDuration, 6, accuracy: 0.001)
        XCTAssertTrue(admitted.seek(to: 5))
        var bytes = [UInt8](repeating: 0, count: 188)
        let count = bytes.withUnsafeMutableBufferPointer {
            admitted.read($0.baseAddress, size: Int32($0.count))
        }
        XCTAssertEqual(count, 188)
        XCTAssertEqual(bytes[0], 0x47)
        XCTAssertEqual(
            Issue268URLProtocol.headersByURL[root.absoluteString]?["X-Fixture"],
            "allowed"
        )
        XCTAssertEqual(
            Issue268URLProtocol.headersByURL[segment.absoluteString]?["X-Fixture"],
            "allowed"
        )
    }

    func testMasterPlaylistUsesHighestBandwidthHEVCVariant() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/master.m3u8"))
        let low = try XCTUnwrap(URL(string: "https://vod.test/low.m3u8"))
        let high = try XCTUnwrap(URL(string: "https://vod.test/high.m3u8"))
        let lowSegment = try XCTUnwrap(URL(string: "https://vod.test/low.ts"))
        let highSegment = try XCTUnwrap(URL(string: "https://vod.test/high.ts"))
        Issue268URLProtocol.bodyByURL[root.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000
        high.m3u8
        """.utf8)
        Issue268URLProtocol.bodyByURL[low.absoluteString] = mediaPlaylist("low.ts")
        Issue268URLProtocol.bodyByURL[high.absoluteString] = mediaPlaylist("high.ts")
        Issue268URLProtocol.bodyByURL[lowSegment.absoluteString] = transportStream(streamType: 0x1B)
        Issue268URLProtocol.bodyByURL[highSegment.absoluteString] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: [:],
            session: session
        )
        XCTAssertNotNil(reader)
        reader?.close()
        XCTAssertNil(Issue268URLProtocol.headersByURL[low.absoluteString])
        XCTAssertNotNil(Issue268URLProtocol.headersByURL[high.absoluteString])
        XCTAssertNil(Issue268URLProtocol.headersByURL[lowSegment.absoluteString])
        XCTAssertNotNil(Issue268URLProtocol.headersByURL[highSegment.absoluteString])
    }

    func testH264MPEGTSRemainsOnNativeHLSRoute() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/h264.m3u8"))
        let segment = try XCTUnwrap(URL(string: "https://vod.test/h264.ts"))
        Issue268URLProtocol.bodyByURL[root.absoluteString] = mediaPlaylist("h264.ts")
        Issue268URLProtocol.bodyByURL[segment.absoluteString] = transportStream(streamType: 0x1B)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: [:],
            session: session
        )
        XCTAssertNil(reader)
    }

    func testFMP4AndLivePlaylistsRemainOnExistingRoutes() async throws {
        let fmp4 = try XCTUnwrap(URL(string: "https://vod.test/fmp4.m3u8"))
        let live = try XCTUnwrap(URL(string: "https://vod.test/live.m3u8"))
        Issue268URLProtocol.bodyByURL[fmp4.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        segment.m4s
        #EXT-X-ENDLIST
        """.utf8)
        Issue268URLProtocol.bodyByURL[live.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        segment.ts
        """.utf8)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let fmp4Reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: fmp4,
            httpHeaders: [:],
            session: session
        )
        let liveReader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: live,
            httpHeaders: [:],
            session: session
        )
        XCTAssertNil(fmp4Reader)
        XCTAssertNil(liveReader)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue268URLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func mediaPlaylist(_ segment: String) -> Data {
        Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        \(segment)
        #EXT-X-ENDLIST
        """.utf8)
    }

    private func transportStream(streamType: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 188 * 3)
        for packet in 0..<3 {
            bytes[packet * 188] = 0x47
            bytes[packet * 188 + 3] = 0x10
        }
        bytes[1] = 0x40
        bytes[2] = 0x64
        bytes[4] = 0
        bytes[5] = 0x02
        bytes[6] = 0xB0
        bytes[7] = 18
        bytes[8] = 0
        bytes[9] = 1
        bytes[10] = 0xC1
        bytes[11] = 0
        bytes[12] = 0
        bytes[13] = 0xE1
        bytes[14] = 0
        bytes[15] = 0xF0
        bytes[16] = 0
        bytes[17] = streamType
        bytes[18] = 0xE1
        bytes[19] = 1
        bytes[20] = 0xF0
        bytes[21] = 0
        return Data(bytes)
    }
}

final class Issue268URLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodyByURL: [String: Data] = [:]
    nonisolated(unsafe) static var headersByURL: [String: [String: String]] = [:]

    static func reset() {
        bodyByURL = [:]
        headersByURL = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.headersByURL[url.absoluteString] = request.allHTTPHeaderFields ?? [:]
        guard let data = Self.bodyByURL[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: request.value(forHTTPHeaderField: "Range") == nil ? 200 : 206,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
