import Testing
import CoreMedia
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#739 follow-up: a rebuild that VideoToolbox refused in the foreground is retried at each following
/// keyframe, a bounded number of times, then waits for the next foreground return instead of retrying for ever.
@Suite("Video session retry", .serialized, .timeLimit(.minutes(1)))
struct VideoSessionRetryTests {

    // MARK: - Policy

    @Test("each keyframe while a recovery is owed is one retry, up to the cap, then one give-up")
    func boundedRetries() {
        var policy = VideoSessionRetryPolicy()
        var decisions: [VideoSessionRetryPolicy.Decision] = []
        for i in 0..<(VideoSessionRetryPolicy.maxAttempts + 3) {
            decisions.append(policy.onKeyframe(owed: true, now: Double(i) * 3))
        }
        let expected: [VideoSessionRetryPolicy.Decision] =
            (1...VideoSessionRetryPolicy.maxAttempts).map { .retry(attempt: $0) } + [.giveUp, .none, .none]
        #expect(decisions == expected)
    }

    @Test("a keyframe with nothing owed does nothing and spends no attempt")
    func nothingOwed() {
        var policy = VideoSessionRetryPolicy()
        #expect(policy.onKeyframe(owed: false, now: 0) == .none)
        #expect(policy.attempts == 0)
        #expect(policy.onKeyframe(owed: true, now: 0) == .retry(attempt: 1))
    }

    @Test("keyframes in a burst spend one attempt, then wait out the spacing")
    func spacing() {
        var policy = VideoSessionRetryPolicy()
        #expect(policy.onKeyframe(owed: true, now: 10) == .retry(attempt: 1))
        #expect(policy.onKeyframe(owed: true, now: 10.1) == .none)
        #expect(policy.onKeyframe(owed: true, now: 11.9) == .none)
        #expect(policy.attempts == 1)
        #expect(policy.onKeyframe(owed: true, now: 12.0) == .retry(attempt: 2))
    }

    @Test("a successful rebuild gives the next loss a fresh budget, even after giving up")
    func resetRestoresTheBudget() {
        var policy = VideoSessionRetryPolicy()
        for i in 0...VideoSessionRetryPolicy.maxAttempts { _ = policy.onKeyframe(owed: true, now: Double(i) * 3) }
        #expect(policy.gaveUp)
        policy.reset()
        #expect(policy.onKeyframe(owed: true, now: 0) == .retry(attempt: 1))
    }

    // MARK: - Host: background, give-up and the foreground return

    @Test("a keyframe in the background spends no retry, whether audio-only or a retained paused session")
    func backgroundSpendsNoRetry() {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        host.noteAppInBackground(true)
        host.setVideoSessionRecoveryOwedForTesting()
        for _ in 0..<(VideoSessionRetryPolicy.maxAttempts + 2) {
            host.keyframeWhileSessionLostForTesting()
        }
        #expect(host.videoSessionRetryAttemptsForTesting == 0)
        #expect(!host.videoSessionRetryGaveUpForTesting)
        #expect(host.failure == nil)
    }

    @Test("a spent budget gives up without publishing a failure, so the session is not left in the error state")
    func giveUpPublishesNoFailure() {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        host.spendVideoSessionRetriesForTesting()
        host.setVideoSessionRecoveryOwedForTesting()
        host.keyframeWhileSessionLostForTesting()
        #expect(host.videoSessionRetryGaveUpForTesting)
        #expect(host.failure == nil)
    }

    @Test("the foreground return starts a fresh budget after a give-up")
    func foregroundReturnStartsFreshBudget() {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        host.spendVideoSessionRetriesForTesting()
        host.setVideoSessionRecoveryOwedForTesting()
        host.keyframeWhileSessionLostForTesting()
        #expect(host.videoSessionRetryGaveUpForTesting)
        host.noteAppInBackground(true)
        #expect(host.videoSessionRetryGaveUpForTesting)
        host.noteAppInBackground(false)
        #expect(!host.videoSessionRetryGaveUpForTesting)
        #expect(host.videoSessionRetryAttemptsForTesting == 0)
    }

    // MARK: - Decoder reports keyframes while lost

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private static func withPacket(key: Bool, _ body: (UnsafeMutablePointer<AVPacket>) -> Void) {
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let p = packet else { return }
        p.pointee.flags = key ? AV_PKT_FLAG_KEY : 0
        body(p)
    }

    #if DEBUG
    @Test("a hardware decoder with a lost session reports each keyframe it is fed, and no other packet")
    func hardwareDecoderReportsKeyframes() {
        let decoder = HardwareVideoDecoder()
        let seen = Counter()
        decoder.onKeyframeWhileLost = { seen.bump() }
        // Not lost: nothing to report.
        Self.withPacket(key: true) { decoder.decode(packet: $0, epoch: nil) }
        #expect(seen.value == 0)
        decoder.markSessionLostForTesting()
        #expect(decoder.isSessionLost)
        Self.withPacket(key: false) { decoder.decode(packet: $0, epoch: nil) }
        #expect(seen.value == 0)
        Self.withPacket(key: true) { decoder.decode(packet: $0, epoch: nil) }
        Self.withPacket(key: true) { decoder.decode(packet: $0, epoch: nil) }
        #expect(seen.value == 2)
    }
    #endif
}
