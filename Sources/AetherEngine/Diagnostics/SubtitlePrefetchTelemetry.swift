import Foundation
import os

/// #220: live gauge for the #151 subtitle forward prefetcher.
///
/// The prefetcher is a second reader against the same origin, and server-side per-connection
/// byte totals showed it consuming 2.6x media rate at playhead + 333 s against a 60 s lead
/// allowance while the pump stayed exactly paced. That is visible on the wire minutes before
/// the process dies, so it has to be visible in our own log too: `lead` separates "reads fast
/// while building its lead" (normal) from "the lead never settles" (the defect).
///
/// Written from the prefetch task (off the main actor, one lock acquisition per routed subtitle
/// packet, never per demuxed packet) and read by the 30 s memprobe on the main actor. The
/// generation guard keeps a cancelled session's exit from clearing the successor it was
/// replaced by: `startSubtitleForwardPrefetcher` cancels and restarts in the same call, and
/// the outgoing loop can still be unwinding when the new one begins.
enum SubtitlePrefetchTelemetry {

    struct Snapshot: Sendable {
        var generation = 0
        var running = false
        var parked = false
        /// Subtitle-axis seconds of the most recently routed packet, NaN before the first one.
        var lastPacketSeconds = Double.nan
        var harvested = 0
        /// #220 defect 2: times the stream time-base lookup fell back to 0/1. Non-zero means
        /// the park guard was skipped at least once; historically that fallback was cached and
        /// disarmed the park permanently.
        var timeBaseFallbacks = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: Snapshot())

    /// Marks a new prefetch session live and returns its generation for the later `ended` call.
    static func sessionStarted() -> Int {
        state.withLock { s in
            let next = s.generation &+ 1
            s = Snapshot(generation: next, running: true)
            return next
        }
    }

    static func sessionEnded(generation: Int) {
        state.withLock { s in
            guard s.generation == generation else { return }
            s.running = false
            s.parked = false
        }
    }

    static func recordPacket(seconds: Double, harvested: Int) {
        state.withLock { s in
            s.lastPacketSeconds = seconds
            s.harvested = harvested
        }
    }

    static func recordPark(_ parked: Bool) {
        state.withLock { $0.parked = parked }
    }

    static func recordTimeBaseFallback() {
        state.withLock { $0.timeBaseFallbacks &+= 1 }
    }

    static var snapshot: Snapshot { state.withLock { $0 } }

    static func probeFragment(playhead: Double) -> String {
        format(snapshot, playhead: playhead)
    }

    /// One memprobe fragment. `dead` is a real finding on a VOD session with a subtitle track
    /// selected: the loop exits on any read error and nothing restarts it until the next seek,
    /// so a session that harvested and then stopped is distinguishable from one that never ran.
    static func format(_ s: Snapshot, playhead: Double) -> String {
        guard s.running || s.harvested > 0 else { return "prefetch=off " }
        let lead = s.lastPacketSeconds.isFinite && playhead.isFinite
            ? String(format: "%.1f", s.lastPacketSeconds - playhead)
            : "n/a"
        return "prefetch=\(s.running ? (s.parked ? "park" : "read") : "dead") "
            + "prefetchLead=\(lead)s "
            + "prefetchHarvested=\(s.harvested) "
            + "prefetchTbFallback=\(s.timeBaseFallbacks) "
    }
}
