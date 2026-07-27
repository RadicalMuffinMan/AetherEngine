import Foundation
import Testing
@testable import AetherEngine

struct AirPlayPlaylistDecisionTests {

    @Test("#227: an SDR master survives the AirPlay rewrite, so its subtitle renditions travel")
    func sdrMasterIsKept() {
        #expect(AirPlayPlaylistDecision.servesMasterToReceiver(
            servingMasterPlaylist: true, sourceIsHDR: false))
    }

    @Test("#86: an HDR/DV master is still downgraded (an SDR receiver rejects it)")
    func hdrMasterIsDowngraded() {
        #expect(!AirPlayPlaylistDecision.servesMasterToReceiver(
            servingMasterPlaylist: true, sourceIsHDR: true))
    }

    @Test("A session already on the media playlist has no master to keep")
    func mediaSessionStaysMedia() {
        #expect(!AirPlayPlaylistDecision.servesMasterToReceiver(
            servingMasterPlaylist: false, sourceIsHDR: false))
        #expect(!AirPlayPlaylistDecision.servesMasterToReceiver(
            servingMasterPlaylist: false, sourceIsHDR: true))
    }

    @Test("#86: the rewrite swaps the loopback host for the LAN IP and keeps the port")
    func rewritesHostKeepsPort() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52341/master.m3u8"))
        let url = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", keepMaster: true))
        #expect(url.absoluteString == "http://192.168.8.166:52341/master.m3u8")
    }

    @Test("#86: without keepMaster the path is forced to the media playlist")
    func forcesMediaPath() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52341/master.m3u8"))
        let url = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", keepMaster: false))
        #expect(url.absoluteString == "http://192.168.8.166:52341/media.m3u8")
    }

    @Test("#227: rewriting the media URL again (the fallback path) is idempotent")
    func mediaRewriteIsIdempotent() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52341/media.m3u8"))
        let url = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", keepMaster: false))
        #expect(url.absoluteString == "http://192.168.8.166:52341/media.m3u8")
    }
}
