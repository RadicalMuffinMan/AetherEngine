import Foundation
import Testing
@testable import AetherEngine

struct AirPlayPlaylistDecisionTests {

    @Test("#227: an SDR source keeps its master, so its subtitle renditions travel")
    func sdrKeepsMaster() {
        #expect(AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: true, sourceIsHDR: false, attemptReducedHDRMaster: false) == .master)
        #expect(AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: true, sourceIsHDR: true, attemptReducedHDRMaster: true) == .reducedHDRMaster)
    }

    @Test("#227: an HDR source drops to media when the reduced master is not attempted")
    func hdrFallsToMedia() {
        #expect(AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: true, sourceIsHDR: true, attemptReducedHDRMaster: false) == .media)
    }

    @Test("A session already on the media playlist has no master to hand over")
    func mediaSessionStaysMedia() {
        for attempt in [false, true] {
            #expect(AirPlayPlaylistDecision.playlistForReceiver(
                servingMasterPlaylist: false, sourceIsHDR: false, attemptReducedHDRMaster: attempt) == .media)
            #expect(AirPlayPlaylistDecision.playlistForReceiver(
                servingMasterPlaylist: false, sourceIsHDR: true, attemptReducedHDRMaster: attempt) == .media)
        }
    }

    @Test("Only the media playlist is without subtitle renditions")
    func renditionCarriers() {
        #expect(AirPlayPlaylistDecision.carriesSubtitleRenditions(.master))
        #expect(AirPlayPlaylistDecision.carriesSubtitleRenditions(.reducedHDRMaster))
        #expect(!AirPlayPlaylistDecision.carriesSubtitleRenditions(.media))
    }

    @Test("#86: the rewrite swaps the loopback host for the LAN IP and keeps the port")
    func rewritesHostKeepsPort() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52341/master.m3u8"))
        let url = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", playlist: .master))
        #expect(url.absoluteString == "http://192.168.8.166:52341/master.m3u8")
    }

    @Test("#227: each playlist choice picks its own path")
    func pathPerPlaylist() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52341/master.m3u8"))
        let reduced = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", playlist: .reducedHDRMaster))
        #expect(reduced.absoluteString == "http://192.168.8.166:52341/master_hdr.m3u8")
        let media = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", playlist: .media))
        #expect(media.absoluteString == "http://192.168.8.166:52341/media.m3u8")
    }

    @Test("#227: rewriting the media URL again (the fallback path) is idempotent")
    func mediaRewriteIsIdempotent() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52341/media.m3u8"))
        let url = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", playlist: .media))
        #expect(url.absoluteString == "http://192.168.8.166:52341/media.m3u8")
    }
}
