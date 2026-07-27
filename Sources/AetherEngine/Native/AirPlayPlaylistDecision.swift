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
/// An SDR variant is routing-safe on every receiver, so it keeps the master (and its subtitle
/// renditions). HDR/DV keeps the media downgrade: an SDR-signalled master over HDR/DV content was tried
/// and reverted in #98 Stage 1.5 (the compatibility gate reads the real colr/codec, not the manifest
/// string), so there is no manifest that both survives an SDR receiver and carries renditions.
enum AirPlayPlaylistDecision {

    /// Which of the loopback server's three playlists is handed to a wireless AirPlay receiver.
    enum ReceiverPlaylist: Equatable {
        /// The playlist the session resolved locally, subtitle renditions included.
        case master
        /// `master_hdr.m3u8` (#98): source range kept, DV `SUPPLEMENTAL-CODECS` dropped, renditions kept.
        case reducedHDRMaster
        /// `media.m3u8`: no renditions, the universally routable last resort.
        case media
    }

    /// Whether an HDR source is offered the reduced HDR master instead of dropping straight to media
    /// (#227 follow-up). Device measurement 2026-07-27: the receiver fetches for itself (its own address
    /// shows up in the server log), takes an SDR master including HEVC, and refuses the DV master. What is
    /// untested is whether the DV `SUPPLEMENTAL-CODECS` alone is what it refuses; if so, the reduced master
    /// carries HDR10 plus the subtitle renditions to the receiver and only the DV upgrade is lost on that
    /// hop. Backed by the progress watchdog, because a receiver that refuses this one fails silently too.
    static let attemptReducedHDRMaster = true

    /// Whether the master playlist (with its subtitle renditions) can be served to a wireless AirPlay
    /// receiver. False downgrades the rewritten URL to `media.m3u8`, which carries no renditions.
    ///
    /// Offering the HDR/DV master anyway was tried on device and does not work (2026-07-27, iPhone 17 Pro to
    /// an Apple TV 4K **in HDR mode**, DV P8.1 source): the receiver takes the manifest, the subtitle
    /// rendition is even fetched, and then AVPlayer never hands the stream over. The picture stays at the
    /// start position and AVKit shows its "not playable on this display" sign. It is not a rejection either,
    /// there is no `-11868`/`-11848` and no `.failed` item, so the readiness gate cannot see it: the rate
    /// flickers to `playing` for one tick, `hasEverPlayed` latches, and the gate reads that as ready. DrHurt's
    /// caveat ("TV MUST be in HDR or DV mode") therefore describes a necessary condition, not a sufficient
    /// one. An SDR master over the same route plays with subtitles, verified in the same session.
    ///
    /// - Parameters:
    ///   - servingMasterPlaylist: what `HLSVideoEngine.start()` resolved for local playback. When it is
    ///     already the media playlist there is no master to keep.
    ///   - sourceIsHDR: the served variant advertises HDR (`HLSVideoEngine.servedSourceIsHDR`). Must be the
    ///     real `VIDEO-RANGE`, not the DV-capability-inflated `sourceIsHDR`, or SDR content on a DV-capable
    ///     device takes the HDR branch and the renditions are dropped for no reason.
    static func playlistForReceiver(
        servingMasterPlaylist: Bool,
        sourceIsHDR: Bool,
        attemptReducedHDRMaster: Bool = attemptReducedHDRMaster
    ) -> ReceiverPlaylist {
        guard servingMasterPlaylist else { return .media }
        guard sourceIsHDR else { return .master }
        return attemptReducedHDRMaster ? .reducedHDRMaster : .media
    }

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
        case .reducedHDRMaster: components?.path = "/master_hdr_ap.m3u8"
        case .media: components?.path = "/media.m3u8"
        }
        return components?.url
    }
}
