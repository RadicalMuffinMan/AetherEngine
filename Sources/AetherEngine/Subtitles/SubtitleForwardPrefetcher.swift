import Foundation
import Libavcodec
import Libavutil

/// #151: subtitle-only forward side reader. The producer pump harvests subtitle packets only as
/// far as its own forward park (#102), so the drainer's 60 s lead window (`subtitleDrainLeadSeconds`)
/// is empty beyond a few seconds on direct-play sources and a host-applied ADVANCE sync offset
/// finds no cues, text and bitmap alike. This reader fills the same session SubtitlePacketStore
/// up to playhead + lead independently of the producer: it reads every embedded subtitle stream
/// (all other streams discarded, #104), parks on the subtitle PTS axis, and resumes as the
/// playhead advances. Overlapping packets dedupe by PTS in the store; split-PES PGS sets assemble
/// under the `.prefetch` writer key so the pump's in-flight set is never corrupted.
///
/// This is the loop half only; positioning (bounded seek + byte-estimate fallback), lifecycle,
/// and seek re-anchoring live on the engine (`AetherEngine.startSubtitleForwardPrefetcher`),
/// mirroring the native subtitle readers (memory rule: all side readers share positioning fixes).
enum SubtitleForwardPrefetcher {

    /// Why a prefetch session ended (#231).
    ///
    /// The loop used to leave on the first failed read with no way to tell why, and its exit line
    /// reported `cancelled=false` for every one of those reasons. Only `.readFailed` is worth
    /// restarting: EOF is the expected end of a session, cancellation is deliberate, and a source
    /// that will not open is the documented best-effort case.
    enum Exit: Equatable {
        case endOfFile
        case cancelled
        case openFailed
        case readFailed

        var isRestartable: Bool { self == .readFailed }
    }

    struct Outcome {
        let exit: Exit
        let harvested: Int
    }

    /// #231: how many times a failing prefetch session may be restarted, and how long to wait first.
    ///
    /// Two ceilings, because two things look different on the wire. A run of failures with nothing
    /// harvested between them is a dead link, and giving up quickly is right. A session that
    /// produced cues and only then broke is a fresh transport failure, so its budget resets; the
    /// total ceiling is what stops a source that fails in a loop after one packet each time from
    /// reconnecting forever.
    struct RestartBudget {
        let maxConsecutiveFailures: Int
        let maxRestarts: Int
        let backoffNanoseconds: UInt64
        private(set) var consecutiveFailures = 0
        private(set) var restarts = 0

        init(maxConsecutiveFailures: Int, maxRestarts: Int, backoffNanoseconds: UInt64) {
            self.maxConsecutiveFailures = maxConsecutiveFailures
            self.maxRestarts = maxRestarts
            self.backoffNanoseconds = backoffNanoseconds
        }

        /// Charge one failed session to the budget. Returns how long to wait before the next
        /// attempt, or nil when the budget is spent and the prefetcher should stay down.
        mutating func chargeFailure(harvested: Int) -> UInt64? {
            consecutiveFailures = harvested > 0 ? 1 : consecutiveFailures + 1
            restarts += 1
            guard consecutiveFailures <= maxConsecutiveFailures, restarts <= maxRestarts else {
                return nil
            }
            return backoffNanoseconds << min(consecutiveFailures - 1, 3)
        }
    }

    /// Resolve a stream's packet time base, memoizing only usable results (#220).
    ///
    /// The lookup used to memoize its own failure: a nil `stream(at:)` fell back to `0/1`, that
    /// value went into the cache, and the park guard (`tb.num > 0`) then skipped every further
    /// packet on the stream, so the reader ran the rest of the session with no forward park at
    /// all. It also fed `0/1` to the store, where `pts * (num/den)` is zero and every harvested
    /// cue lands at second 0. Caching only valid values makes a failed lookup cost one packet
    /// and retry on the next.
    static func resolveTimeBase(
        streamIndex: Int32,
        cache: inout [Int32: AVRational],
        lookup: (Int32) -> AVRational?
    ) -> AVRational? {
        if let cached = cache[streamIndex] { return cached }
        guard let resolved = lookup(streamIndex), resolved.num > 0, resolved.den > 0 else {
            return nil
        }
        cache[streamIndex] = resolved
        return resolved
    }

    /// Where a packet sits on the source timeline for park purposes, or nil when it carries no
    /// usable timestamp (#230).
    ///
    /// A harvested subtitle packet is placed by PTS, its own cue time. A pacing packet is placed by
    /// DTS, the monotone read position: with B-frames a video PTS runs ahead of the bytes actually
    /// read, and it is the bytes the park exists to bound.
    static func packetSeconds(
        pts: Int64, dts: Int64, timeBase: AVRational, preferDecodeOrder: Bool
    ) -> Double? {
        let raw = preferDecodeOrder
            ? (dts != Int64.min ? dts : pts)
            : (pts != Int64.min ? pts : dts)
        guard raw != Int64.min, timeBase.num > 0, timeBase.den > 0 else { return nil }
        return Double(raw) * Double(timeBase.num) / Double(timeBase.den)
    }

    /// Read/harvest until EOF, error, cancellation, or a nil playhead (engine gone). Returns why it
    /// stopped and how many routed subtitle packets it harvested (#231: a read error is not an EOF
    /// and the caller has to be able to tell them apart). The demuxer must be positioned by the
    /// caller.
    /// Harvest-then-park: the packet whose PTS crosses `playhead + leadSeconds` is stored before
    /// the loop parks, so the store may hold one packet past the lead edge (harmless; the drainer
    /// window decides what decodes). The playhead is snapshot at start and refreshed only inside
    /// the park loop, matching the native readers: no MainActor hop per packet during a backfill
    /// burst.
    ///
    /// #230: `pacingIndex` (-1 when the source has no usable one) names a non-subtitle stream the
    /// caller left at `AVDISCARD_NONKEY`. Its packets are freed unharvested and exist only to park
    /// the loop on the read position. Without one the park is edge-triggered on subtitle packets
    /// alone, so a stretch of the file with no cues is read at full speed however far past the lead
    /// edge it runs: bounded on a dense PGS track, unbounded on a sparse or forced one.
    static func run(
        demuxer: Demuxer,
        store: SubtitlePacketStore,
        streamIndices: Set<Int32>,
        assemblyIndices: Set<Int32>,
        pacingIndex: Int32,
        leadSeconds: Double,
        parkPollNanoseconds: UInt64,
        playhead: @Sendable () async -> Double?
    ) async -> Outcome {
        guard var playheadSnapshot = await playhead() else {
            return Outcome(exit: .cancelled, harvested: 0)
        }
        var harvested = 0
        var timeBaseCache: [Int32: AVRational] = [:]
        var timeBaseFailures = 0
        var exit = Exit.cancelled
        readLoop: while !Task.isCancelled {
            let next: UnsafeMutablePointer<AVPacket>?
            do {
                next = try demuxer.readPacket()
            } catch {
                // #231: a transport failure on the side reader, a stall that exhausts the read
                // deadline, a reconnect that gives up. Distinct from EOF, and restartable.
                EngineLog.emit(
                    "[AetherEngine] #151 forward prefetch read failed after \(harvested) packets: "
                    + "\(error)",
                    category: .engine)
                exit = .readFailed
                break
            }
            guard let pkt = next else {
                exit = .endOfFile
                break
            }
            let streamIdx = pkt.pointee.stream_index
            let isTarget = streamIndices.contains(streamIdx)
            guard isTarget || streamIdx == pacingIndex else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
                continue
            }
            // #220: an unusable time base drops the packet rather than harvesting it against a
            // zero rate (every cue would land at second 0) and rather than parking against a
            // meaningless PTS. It is not cached, so the next packet retries the lookup.
            guard let tb = resolveTimeBase(streamIndex: streamIdx, cache: &timeBaseCache,
                                           lookup: { demuxer.stream(at: $0)?.pointee.time_base })
            else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
                timeBaseFailures += 1
                if timeBaseFailures == 1 {
                    EngineLog.emit(
                        "[AetherEngine] #151 forward prefetch: no usable time base for stream "
                        + "\(streamIdx); packet dropped (logged once)",
                        category: .engine)
                }
                continue
            }
            if isTarget {
                store.harvest(streamIndex: streamIdx, packet: pkt, timeBase: tb,
                              assembleSplitDisplaySets: assemblyIndices.contains(streamIdx),
                              writer: .prefetch)
                harvested += 1
            }
            let position = packetSeconds(pts: pkt.pointee.pts, dts: pkt.pointee.dts,
                                         timeBase: tb, preferDecodeOrder: !isTarget)
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
            // Park once the read passes the lead edge; a packet without a usable timestamp
            // (split-set continuation chunks) never parks, its set's PCS anchor already did the
            // pacing.
            guard let position else { continue }
            while !Task.isCancelled, position > playheadSnapshot + leadSeconds {
                guard let fresh = await playhead() else { break readLoop }
                playheadSnapshot = fresh
                if position <= playheadSnapshot + leadSeconds { break }
                do { try await Task.sleep(nanoseconds: parkPollNanoseconds) } catch { break readLoop }
            }
        }
        return Outcome(exit: exit, harvested: harvested)
    }
}
