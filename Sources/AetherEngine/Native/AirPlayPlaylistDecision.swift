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

    /// Whether the master playlist (with its subtitle renditions) can be served to a wireless AirPlay
    /// receiver. False downgrades the rewritten URL to `media.m3u8`, which carries no renditions.
    ///
    /// - Parameters:
    ///   - servingMasterPlaylist: what `HLSVideoEngine.start()` resolved for local playback. When it is
    ///     already the media playlist there is no master to keep.
    ///   - sourceIsHDR: the served variant carries HDR/DV signaling (`HLSVideoEngine.servedSourceIsHDR`).
    static func servesMasterToReceiver(servingMasterPlaylist: Bool, sourceIsHDR: Bool) -> Bool {
        servingMasterPlaylist && !sourceIsHDR
    }

    /// The loopback URL rewritten for the receiver: same port and query, the device's LAN IP for the host
    /// (the receiver cannot reach 127.0.0.1), and the media playlist unless the master is kept. The master's
    /// `EXT-X-MEDIA` URIs are relative, so the renditions resolve against the LAN base with no further work.
    static func receiverURL(base: URL, lanIP: String, keepMaster: Bool) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.host = lanIP
        if !keepMaster { components?.path = "/media.m3u8" }
        return components?.url
    }
}
