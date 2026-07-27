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
///
/// So neither the DV tag nor the declared peak is the trigger, and the receiver decodes those very
/// segments happily off the media playlist. HDR and 4K are still perfectly confounded in that table: every
/// accepted master was 1080p or below, every refused one was 4K, and no 4K SDR or 1080p HDR source was
/// available to separate them. Which of the two it is decides whether HDR can ever carry renditions here,
/// so `.receiverHDRMaster` drops the optional RESOLUTION attribute to take 4K out of what the receiver can
/// filter on. (Misdeclaring the range instead is not an option: #98 Stage 1.5 showed `VIDEO-RANGE=SDR` over
/// HDR content does not fool the compatibility gate, which reads the real `colr` and codec.)
///
/// The refusal is silent, which is why the downgrade is a decision and not a fallback: no `-11868`, no
/// `.failed` item, the rate flickers to `playing` for one tick so even `hasEverPlayed` latches, and the
/// picture simply never starts. `AetherEngine`'s progress watchdog is the only thing that can see it.
enum AirPlayPlaylistDecision {

    /// Which of the loopback server's playlists is handed to a wireless AirPlay receiver.
    enum ReceiverPlaylist: Equatable {
        /// The playlist the session resolved locally, subtitle renditions included.
        case master
        /// `master_hdr_ap.m3u8` (#227 experiment): DV dropped and no RESOLUTION, to find out whether the
        /// receiver's variant filter trips on 4K or on PQ. Carries the renditions.
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
        attemptHDRWithoutResolution: Bool = attemptHDRWithoutResolution
    ) -> ReceiverPlaylist {
        guard servingMasterPlaylist else { return .media }
        guard sourceIsHDR else { return .master }
        return attemptHDRWithoutResolution ? .receiverHDRMaster : .media
    }

    /// #227 experiment switch: offer HDR sources a master without the RESOLUTION attribute instead of
    /// dropping to media. Set to false once the question is settled; the watchdog covers a refusal.
    static let attemptHDRWithoutResolution = true

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
