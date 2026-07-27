import Foundation

/// Pure playlist choice for the wireless-AirPlay loopback rewrite (#86, #227). Kept separate and pure
/// so the gate is testable offline, matching `MasterFallbackDecision` / `StartupReadinessGate`.
///
/// #86 rewrites the loopback playback URL to the device's LAN IP (the receiver cannot reach 127.0.0.1)
/// and originally forced the MEDIA playlist for every source, on DrHurt's caveat that "AVPlayer will
/// reject a DV/HDR master playlist on an SDR receiver and will not automatically switch". That caveat is
/// about the HDR/DV variant, not about masters as such, but the blanket downgrade also dropped the
/// master-only `EXT-X-MEDIA:TYPE=SUBTITLES` renditions, so `setNativeSubtitleSelected(track:)` had no
/// legible group to select against and native subtitles never reached any receiver (#227, thatcube).
///
/// **What an Apple TV 4K receiver accepts, measured 2026-07-27** (iPhone 17 Pro, receiver in HDR mode;
/// the receiver fetches for itself, its own address shows up in the server log):
///
/// | Master handed over | Result |
/// | --- | --- |
/// | SDR 1080p H.264, BANDWIDTH 7.5 Mbps | plays, subtitles travel |
/// | SDR 720p HEVC, BANDWIDTH 5.0 Mbps | plays |
/// | 4K PQ + DV `SUPPLEMENTAL-CODECS`, 33.8 Mbps | refused |
/// | 4K PQ, DV dropped (`master_hdr`), 33.8 Mbps | refused |
/// | 4K PQ, DV dropped, BANDWIDTH clamped to 8 Mbps | refused |
/// | 4K PQ, DV dropped, RESOLUTION omitted entirely | refused |
///
/// The trigger is `VIDEO-RANGE=PQ`. Not the DV tag, not the declared peak, and not 4K: with RESOLUTION
/// omitted the receiver cannot know the dimensions before the first segment and refuses anyway, while it
/// decodes those same 4K PQ segments happily off the media playlist. Two different Apple TV 4K units
/// behaved identically. The one remaining manifest edit, declaring the range as SDR, was disproven on
/// hardware in #98 Stage 1.5: the compatibility gate reads the real `colr` and codec, not the string.
///
/// **So an HDR or DV source cannot carry subtitle renditions to a wireless AirPlay receiver.** The
/// renditions exist only in a master, and no master describing HDR content is accepted. The media
/// downgrade is not a workaround, it is the only routable manifest, and hosts learn about it through
/// `nativeSubtitleRenditionsServed` going false. SDR keeps its master and its subtitles.
///
/// The refusal is silent, which is why the downgrade is a decision and not a fallback: no `-11868`, no
/// `.failed` item, the rate flickers to `playing` for one tick so even `hasEverPlayed` latches, and the
/// picture simply never starts. `AetherEngine`'s progress watchdog is the only thing that can see it.
enum AirPlayPlaylistDecision {

    /// Which of the loopback server's playlists is handed to a wireless AirPlay receiver.
    enum ReceiverPlaylist: Equatable {
        /// The playlist the session resolved locally, subtitle renditions included.
        case master
        /// `master_hdr_ap.m3u8` (#227 experiment): reduced HDR master with `HDCP-LEVEL=TYPE-1`, the last
        /// manifest attribute never tried. Carries the renditions.
        case receiverHDRMaster
        /// `media.m3u8`: no renditions, the manifest every receiver takes.
        case media
    }

    /// - Parameters:
    ///   - servingMasterPlaylist: what `HLSVideoEngine.start()` resolved for local playback. When it is
    ///     already the media playlist there is no master to hand over.
    ///   - sourceIsHDR: the served variant advertises HDR (`HLSVideoEngine.servedSourceIsHDR`). Must be the
    ///     real `VIDEO-RANGE`, not the DV-capability-inflated `sourceIsHDR`, or SDR content on a DV-capable
    ///     device takes the HDR branch and the renditions are dropped for no reason.
    static func playlistForReceiver(
        servingMasterPlaylist: Bool,
        sourceIsHDR: Bool,
        attemptHDRWithHDCP: Bool = attemptHDRWithHDCP
    ) -> ReceiverPlaylist {
        guard servingMasterPlaylist else { return .media }
        guard sourceIsHDR else { return .master }
        return attemptHDRWithHDCP ? .receiverHDRMaster : .media
    }

    /// #227 experiment switch: offer HDR sources a master declaring HDCP-LEVEL=TYPE-1 instead of dropping
    /// to media. The watchdog covers a refusal, so a wrong guess costs eight seconds, not the session.
    static let attemptHDRWithHDCP = true

    /// Whether the playlist handed to the receiver carries the `EXT-X-MEDIA:TYPE=SUBTITLES` renditions.
    static func carriesSubtitleRenditions(_ playlist: ReceiverPlaylist) -> Bool {
        playlist != .media
    }

    /// The loopback URL rewritten for the receiver: same port and query, the device's LAN IP for the host
    /// (the receiver cannot reach 127.0.0.1), and the path of the chosen playlist. `.master` keeps whatever
    /// the session resolved. The playlists' `EXT-X-MEDIA` and segment URIs are relative, so everything
    /// resolves against the LAN base with no further work.
    static func receiverURL(base: URL, lanIP: String, playlist: ReceiverPlaylist) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.host = lanIP
        switch playlist {
        case .master: break
        case .receiverHDRMaster: components?.path = "/master_hdr_ap.m3u8"
        case .media: components?.path = "/media.m3u8"
        }
        return components?.url
    }
}
