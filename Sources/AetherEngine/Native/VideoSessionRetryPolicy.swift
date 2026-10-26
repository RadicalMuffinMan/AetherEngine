import Foundation

/// When to retry a video-session rebuild that VideoToolbox refused while the app is in the foreground.
///
/// A refused rebuild leaves the decoder dropping every packet, with audio still playing. The retry is keyed
/// on the stream, not on a timer: each keyframe fed while the session is still lost is one chance, because
/// from a keyframe on a new session could show a picture again. The attempts are capped, so a session the
/// system will not give back ends in an error instead of a frozen picture that retries for ever.
struct VideoSessionRetryPolicy: Equatable {
    /// Keyframes at which a rebuild is tried before the session is given up as unrecoverable.
    static let maxAttempts = 4
    /// Wall-clock seconds between attempts. A lost decoder enqueues nothing, so the demux loop is not
    /// paced and keyframes can arrive in a burst: without a gap the whole budget would go in milliseconds,
    /// leaving a short-lived refusal no time to clear.
    static let minSpacing: TimeInterval = 2.0

    enum Decision: Equatable {
        /// Try the rebuild now.
        case retry(attempt: Int)
        /// The cap was just reached: surface the failure, once.
        case giveUp
        /// Nothing to do: recovery is not owed, or the failure was already surfaced.
        case none
    }

    private(set) var attempts = 0
    private(set) var gaveUp = false
    private var lastAttempt: TimeInterval?

    /// A keyframe was fed while the session is lost. `owed` is whether the host still owes a recovery.
    mutating func onKeyframe(owed: Bool, now: TimeInterval) -> Decision {
        guard owed, !gaveUp else { return .none }
        if let lastAttempt, now - lastAttempt < Self.minSpacing { return .none }
        if attempts >= Self.maxAttempts {
            gaveUp = true
            return .giveUp
        }
        attempts += 1
        lastAttempt = now
        return .retry(attempt: attempts)
    }

    /// A rebuild succeeded, or the app returned to the foreground: the next loss starts a fresh budget.
    mutating func reset() {
        attempts = 0
        gaveUp = false
        lastAttempt = nil
    }
}
