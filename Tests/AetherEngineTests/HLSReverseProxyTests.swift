// Addressing and rewriting, none of which reads the trust flag. The live
// proof that a client which never sees the certificate still gets the stream
// lives with the other tests that flip that flag, in EngineTLSHandshakeTests.
import Foundation
import Testing

@testable import AetherEngine

@Suite("HLS reverse proxy addressing and rewriting")
struct HLSReverseProxyAddressingTests {

    @Test("An origin survives the round trip through a proxy URL")
    func roundTrip() throws {
        let origin = URL(
            string: "https://media.example.com:8920/videos/1/master.m3u8"
                + "?ApiKey=abc123&PlaySessionId=x%20y&tag=a+b")!
        let local = try #require(HLSReverseProxyServer.localURL(for: origin, port: 51234))

        #expect(local.host == "127.0.0.1")
        #expect(local.port == 51234)
        let recovered = try #require(HLSReverseProxyServer.originURL(fromTarget: local.path + "?" + (local.query ?? "")))
        #expect(recovered == origin, "recovered \(recovered) from \(origin)")
    }

    @Test("A target that is not the proxy route yields no origin")
    func rejectsForeignTarget() {
        #expect(HLSReverseProxyServer.originURL(fromTarget: "/something?origin=https%3A%2F%2Fa.b") == nil)
        #expect(HLSReverseProxyServer.originURL(fromTarget: HLSReverseProxyServer.proxyPath) == nil)
    }

    @Test("The origin key keeps scheme, host and port apart")
    func originKeys() {
        #expect(HLSReverseProxyServer.originKey(for: URL(string: "https://A.example.com/x")!) == "https://a.example.com")
        #expect(HLSReverseProxyServer.originKey(for: URL(string: "https://a.example.com:8920/x")!) == "https://a.example.com:8920")
        #expect(HLSReverseProxyServer.originKey(for: URL(string: "http://a.example.com/x")!) == "http://a.example.com")
        #expect(HLSReverseProxyServer.originKey(for: URL(string: "file:///tmp/x")!) == nil)
    }

    @Test("Every URI in a media playlist comes back pointing at the proxy")
    func rewritesMediaPlaylist() async throws {
        let server = HLSReverseProxyServer()
        try server.start()
        defer { server.stop() }
        let origin = URL(string: "https://media.example.com/hls/media.m3u8?ApiKey=k")!
        _ = server.proxyURL(for: origin)

        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-MAP:URI="init.mp4"
            #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k1",IV=0x00
            #EXTINF:6.0,
            seg0.ts
            #EXTINF:6.0,
            https://cdn.example.com/seg1.ts
            #EXT-X-ENDLIST
            """

        let rewritten = server.rewritePlaylist(playlist, relativeTo: origin)
        let lines = rewritten.components(separatedBy: "\n")

        #expect(lines.first == "#EXTM3U")
        #expect(rewritten.contains("#EXT-X-TARGETDURATION:6"))
        #expect(rewritten.contains("#EXT-X-ENDLIST"))
        // Nothing that names a resource may still point outside.
        #expect(!rewritten.contains("\"init.mp4\""))
        #expect(!rewritten.contains("URI=\"https://keys.example.com/k1\""))
        for line in lines where !line.hasPrefix("#") && !line.isEmpty {
            #expect(line.hasPrefix("http://127.0.0.1:"), "segment line escaped the proxy: \(line)")
        }
        for line in lines where line.contains("URI=\"") {
            #expect(line.contains("URI=\"http://127.0.0.1:"), "tag escaped the proxy: \(line)")
        }

        // A relative segment resolves against the playlist it came from.
        let segLine = try #require(lines.first { !$0.hasPrefix("#") && !$0.isEmpty })
        let target = segLine.replacingOccurrences(of: "http://127.0.0.1:\(URL(string: segLine)!.port!)", with: "")
        let recovered = try #require(HLSReverseProxyServer.originURL(fromTarget: target))
        #expect(recovered.absoluteString == "https://media.example.com/hls/seg0.ts")
    }

    @Test("A host discovered in a playlist becomes fetchable, one that was never named does not")
    func allowListFollowsThePlaylist() async throws {
        let server = HLSReverseProxyServer()
        try server.start()
        defer { server.stop() }
        // Closed ports on 127.0.0.1, which refuses at once rather than leaving
        // the fetch to time out. Nothing here waits on a name resolving, and
        // the three differ only by port, which the allow list treats as part of
        // the origin.
        let origin = URL(string: "https://127.0.0.1:9/hls/media.m3u8")!
        _ = server.proxyURL(for: origin)

        _ = server.rewritePlaylist(
            "#EXTM3U\n#EXTINF:6.0,\nhttps://127.0.0.1:10/seg1.ts\n", relativeTo: origin)

        let port = server.listeningPort
        let named = try #require(
            HLSReverseProxyServer.localURL(
                for: URL(string: "https://127.0.0.1:10/seg1.ts")!, port: port))
        let stranger = try #require(
            HLSReverseProxyServer.localURL(
                for: URL(string: "https://127.0.0.1:11/x.ts")!, port: port))

        #expect(try await status(of: named) == 502, "the playlist named this host")
        #expect(try await status(of: stranger) == 403, "nothing ever named this host")
    }

    private func status(of url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

#if os(macOS)

    /// Loopback HTTPS origin with the same self-signed certificate the
    /// handshake suite uses, serving a two level playlist and one segment.
    final class SelfSignedHLSOrigin {
        let port: UInt16
        private let process: Process
        private let workDir: URL

        init?() {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("aether-hls-origin-\(UUID().uuidString)")
            guard (try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)) != nil else { return nil }
            workDir = dir
            do {
                try SelfSignedTLSOrigin.certPEM.write(
                    to: dir.appendingPathComponent("cert.pem"), atomically: true, encoding: .utf8)
                try SelfSignedTLSOrigin.keyPEM.write(
                    to: dir.appendingPathComponent("key.pem"), atomically: true, encoding: .utf8)
                try Self.serverPy.write(
                    to: dir.appendingPathComponent("origin.py"), atomically: true, encoding: .utf8)
            } catch { return nil }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [dir.appendingPathComponent("origin.py").path]
            proc.currentDirectoryURL = dir
            let stdout = Pipe()
            proc.standardOutput = stdout
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return nil }
            process = proc

            var readyLine = ""
            var pending = Data()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !readyLine.contains("READY") {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                pending.append(chunk)
                readyLine = String(decoding: pending, as: UTF8.self)
            }
            guard let match = readyLine.split(separator: " ").last,
                let bound = UInt16(match.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                proc.terminate()
                return nil
            }
            port = bound
        }

        func stop() {
            process.terminate()
            try? FileManager.default.removeItem(at: workDir)
        }

        private static let serverPy = """
            import http.server, ssl

            MASTER = (
                "#EXTM3U\\n"
                "#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS=\\"avc1.640028,mp4a.40.2\\"\\n"
                "media.m3u8?token=abc\\n"
            )
            MEDIA = (
                "#EXTM3U\\n"
                "#EXT-X-TARGETDURATION:6\\n"
                "#EXT-X-VERSION:3\\n"
                "#EXTINF:6.0,\\n"
                "seg0.ts\\n"
                "#EXT-X-ENDLIST\\n"
            )
            SEGMENT = b"\\x47" * 4096

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *args):
                    pass

                def do_GET(self):
                    path = self.path.split("?")[0]
                    if path.endswith("master.m3u8"):
                        body, ctype = MASTER.encode(), "application/vnd.apple.mpegurl"
                    elif path.endswith("media.m3u8"):
                        body, ctype = MEDIA.encode(), "application/vnd.apple.mpegurl"
                    elif path.endswith("seg0.ts"):
                        body, ctype = SEGMENT, "video/mp2t"
                    else:
                        self.send_response(404)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", ctype)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain("cert.pem", "key.pem")
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            print("READY", server.server_address[1], flush=True)
            server.serve_forever()
            """
    }

#endif
