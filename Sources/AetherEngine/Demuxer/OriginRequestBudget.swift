import Foundation

/// #377: one request budget per origin, shared by every path the reader fetches on.
///
/// `httpMaximumConnectionsPerHost` is a per-`URLSession` cap, and `AVIOReader` fetches over four
/// pools: `persistentSession` (2) for the pump's ranges, `chunkSession` (2) for detour blocks,
/// `probeSession` on `URLSessionConfiguration.default` (6) for size probes and HEAD, plus a
/// per-call streaming session. Those caps do not compose. Against one signed CDN URL a pump range,
/// a detour block and a probe can all be open at once, and a second reader (the subtitle side
/// demuxer) shares the same static pools, so the ceiling is a sum nobody wrote down.
///
/// The cap also measures the wrong thing. `httpMaximumConnectionsPerHost` bounds TCP connections,
/// and over HTTP/2 URLSession multiplexes every request of a session onto one of them, so a cap of
/// 1 there bounds nothing at all while the origin still counts the requests. This budget counts
/// requests, which is what an origin metering us counts, and is therefore equally true on h2 and
/// http/1.1. `ReaderTransportLog` records which one is actually in use.
///
/// Counting is unconditional; capping is not. With no limit set, `acquire` hands out a ticket
/// immediately and only tallies, so a healthy origin sees exactly the behaviour it saw before this
/// existed. A limit arrives one of two ways: the host names it (`LoadOptions.maxConcurrentSourceRequests`),
/// or the origin does, by answering 429/503/509, after which the budget halves from the concurrency
/// it had actually reached. There is no automatic increase: an origin that has metered us once is
/// treated as metering for the rest of the process, which costs some parallelism and no correctness.
///
/// Deadlock is excluded structurally rather than managed. A reader that already holds a ticket must
/// never block on a second one, so at `limit == 1` the speculative parallel paths (detour blocks,
/// the tail prefetch, the staggered probe fan) are switched off instead of queued, and each of them
/// already has a serial fallback: the detour's is repositioning the persistent connection, the
/// probe fan's is running its probes in order. What remains queueing on the semaphore are requests
/// that no reader holds a ticket across.
final class OriginRequestBudget: @unchecked Sendable {

    static let shared = OriginRequestBudget()

    /// Scheme + host + port, matching `SuffixRangeSupport.originKey`. Deliberately NOT the full
    /// URL: a metered CDN hands out signed URLs with a rotating token, so a per-URL budget would
    /// start at zero on every refresh and cap nothing. What meters us is the host.
    static func originKey(for url: URL) -> String? {
        SuffixRangeSupport.originKey(for: url)
    }

    /// A held slot. Released exactly once, by `release`, whoever ends the request. Not a
    /// `deinit`-based guard on purpose: the pump's slot is held across a connection, so its
    /// lifetime is the connection's, not a scope's.
    struct Ticket {
        let key: String
        let label: String
        /// True when the budget was capped and this ticket waited for room. Diagnostic only.
        let waitedMs: Double
        /// False when no room came free within the caller's budget and it proceeded anyway.
        let granted: Bool
    }

    struct Snapshot {
        var inflight: Int
        var peakInflight: Int
        var limit: Int?
        var refusals: Int
        var secondsSinceLastRefusal: Double?
        /// How many callers are parked waiting for a slot right now. Reported so a test can wait on
        /// the state it means to set up rather than on a sleep long enough to "probably" reach it,
        /// which is a margin against a derived time bound and fails on a slower machine.
        var waiting: Int
    }

    private struct OriginState {
        var inflight = 0
        var peakInflight = 0
        /// nil = count only. Set by the host, or learned from a refusal.
        var limit: Int?
        var hostLimit: Int?
        var refusals = 0
        var lastRefusalAt: DispatchTime?
        /// FIFO of waiters. Front is served first, so the pump cannot re-take the slot it just
        /// released ahead of a detour that has been waiting.
        var waiters: [DispatchSemaphore] = []
    }

    private let lock = NSLock()
    private var origins: [String: OriginState] = [:]

    // MARK: - Acquire / release

    /// Take a slot for one request against `url`, waiting up to `timeout` when the origin is
    /// capped and full.
    ///
    /// Always returns a ticket. A caller that could not be given room within its budget gets one
    /// with `granted == false` and proceeds: the budget is a throttle over an origin's tolerance,
    /// not a correctness barrier, and blocking a read forever to honour a guess about someone
    /// else's rate limiter trades a slow session for a dead one. The un-granted case is counted
    /// and logged, because a budget that is being routinely overrun is worth seeing.
    func acquire(for url: URL, label: String, timeout: TimeInterval) -> Ticket? {
        guard let key = Self.originKey(for: url) else { return nil }

        let started = DispatchTime.now()
        lock.lock()
        var state = origins[key] ?? OriginState()
        if state.limit == nil || state.inflight < (state.limit ?? Int.max) {
            state.inflight += 1
            state.peakInflight = max(state.peakInflight, state.inflight)
            origins[key] = state
            lock.unlock()
            return Ticket(key: key, label: label, waitedMs: 0, granted: true)
        }
        let semaphore = DispatchSemaphore(value: 0)
        state.waiters.append(semaphore)
        origins[key] = state
        lock.unlock()

        let signalled = semaphore.wait(timeout: .now() + timeout) == .success
        let waitedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000

        if signalled {
            // `release` counted us in before signalling, so the slot is already ours.
            return Ticket(key: key, label: label, waitedMs: waitedMs, granted: true)
        }

        // Timed out. Drop out of the queue and proceed uncounted-for: a slot handed to us between
        // the timeout and the lock would otherwise be leaked by a waiter that is no longer waiting.
        lock.lock()
        var timedOut = origins[key] ?? OriginState()
        if let i = timedOut.waiters.firstIndex(where: { $0 === semaphore }) {
            timedOut.waiters.remove(at: i)
            timedOut.inflight += 1   // proceeding anyway; stay honest about what is on the link
        }
        // The `else` is the race where a release signalled us between the timeout firing and this
        // lock: it already removed us from the queue AND counted the slot in, so there is nothing
        // to add. Counting again here would inflate `inflight` by one permanently, since the
        // matching `release` only ever subtracts one.
        timedOut.peakInflight = max(timedOut.peakInflight, timedOut.inflight)
        let limitDesc = timedOut.limit.map(String.init) ?? "none"
        origins[key] = timedOut
        lock.unlock()

        EngineLog.emit(
            "[OriginBudget] \(label) proceeded without a slot after \(Int(waitedMs))ms "
            + "(limit \(limitDesc))",
            category: .demux, level: .verbose)
        return Ticket(key: key, label: label, waitedMs: waitedMs, granted: false)
    }

    /// Take a slot only if one is free right now, never waiting. For SPECULATIVE requests: the tail
    /// prefetch exists to save a round trip it is already racing, so a version of it that queues has
    /// given up the only thing it was for and still costs the origin a request. nil means "do not
    /// make this request at all", which is a complete answer for a fetch nobody is waiting on.
    func tryAcquire(for url: URL, label: String) -> Ticket? {
        guard let key = Self.originKey(for: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var state = origins[key] ?? OriginState()
        guard state.inflight < (state.limit ?? Int.max) else {
            origins[key] = state
            return nil
        }
        state.inflight += 1
        state.peakInflight = max(state.peakInflight, state.inflight)
        origins[key] = state
        return Ticket(key: key, label: label, waitedMs: 0, granted: true)
    }

    func release(_ ticket: Ticket?) {
        guard let ticket else { return }
        lock.lock()
        guard var state = origins[ticket.key] else { lock.unlock(); return }
        state.inflight = max(0, state.inflight - 1)
        // Hand the slot straight to the front of the queue rather than dropping the count and
        // letting whoever locks first take it: without that, a pump reconnecting at a range
        // boundary beats a detour that has been waiting since the last one.
        if !state.waiters.isEmpty, state.inflight < (state.limit ?? Int.max) {
            let next = state.waiters.removeFirst()
            state.inflight += 1
            origins[ticket.key] = state
            lock.unlock()
            next.signal()
            return
        }
        origins[ticket.key] = state
        lock.unlock()
    }

    // MARK: - Learning the limit

    /// The origin answered 429/503/509. Halve the concurrency it was actually given, floor 1.
    ///
    /// Halving from the observed peak rather than dropping straight to 1 keeps the answer
    /// proportionate to what we were doing: an origin refused while four requests were open has
    /// said something about four, not about one. Repeated refusals halve again, so an origin that
    /// really allows one connection reaches 1 within a few refusals. A host limit always wins.
    /// Returns the limit now in force, if any.
    @discardableResult
    func noteRefusal(for url: URL, status: Int) -> Int? {
        guard let key = Self.originKey(for: url) else { return nil }
        lock.lock()
        var state = origins[key] ?? OriginState()
        state.refusals += 1
        state.lastRefusalAt = DispatchTime.now()
        let previous = state.limit
        if let hostLimit = state.hostLimit {
            state.limit = hostLimit
        } else {
            let basis = state.limit ?? max(1, state.peakInflight)
            state.limit = max(1, basis / 2)
        }
        let now = state.limit
        let peak = state.peakInflight
        origins[key] = state
        lock.unlock()

        if previous != now, let now {
            EngineLog.emit(
                "[OriginBudget] \(key) answered \(status); concurrency budget "
                + "\(previous.map(String.init) ?? "uncapped") -> \(now) (peak was \(peak))",
                category: .demux)
        }
        return now
    }

    /// Record that a refusal happened while fetching this source, WITHOUT touching the concurrency
    /// budget of the URL passed in.
    ///
    /// A metered source is routinely two origins: a proxy that mints signed links and 302s to a CDN
    /// that serves them. The refusal comes back from the CDN, so that is the host whose concurrency
    /// budget must come down. But the engine's revive arm only ever knows the URL the host loaded,
    /// which is the proxy's, and asking the proxy's key whether the CDN refused us returns false
    /// forever: the classification would be built, published, and silently never reached. So the
    /// source URL carries the timestamp too, and only the timestamp.
    func noteRefusalWitnessed(for url: URL) {
        guard let key = Self.originKey(for: url) else { return }
        lock.lock(); defer { lock.unlock() }
        var state = origins[key] ?? OriginState()
        state.lastRefusalAt = DispatchTime.now()
        origins[key] = state
    }

    /// True when this origin refused a request within `window`. The engine's revive arm asks this
    /// to tell "the source is gone" from "the source is metering us", which the FFmpeg-side error
    /// code (-1) cannot carry.
    func refusedRecently(_ url: URL, within window: TimeInterval) -> Bool {
        guard let key = Self.originKey(for: url) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let last = origins[key]?.lastRefusalAt else { return false }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
        return elapsed <= window
    }

    /// Host-declared ceiling for this origin. Takes precedence over anything learned, in both
    /// directions: a host that knows its provider allows one connection should not have to wait
    /// for the engine to be refused a few times to find that out.
    func setHostLimit(_ limit: Int?, for url: URL) {
        guard let key = Self.originKey(for: url) else { return }
        lock.lock(); defer { lock.unlock() }
        var state = origins[key] ?? OriginState()
        state.hostLimit = limit.map { max(1, $0) }
        if let hostLimit = state.hostLimit { state.limit = hostLimit }
        origins[key] = state
    }

    /// The effective ceiling for this origin, or nil while it is uncapped.
    func limit(for url: URL) -> Int? {
        guard let key = Self.originKey(for: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return origins[key]?.limit
    }

    /// True when this origin is down to one request at a time. The reader asks this to switch OFF
    /// its speculative parallel paths rather than queue them: a detour block, the tail prefetch and
    /// the staggered probe fan all exist to overlap with the pump, and overlapping is the one thing
    /// a single-slot origin does not allow. Each has a serial fallback, so switching them off costs
    /// throughput and nothing else, while queueing them behind a slot the caller itself holds would
    /// deadlock.
    func requiresSerialRequests(_ url: URL) -> Bool {
        limit(for: url) == 1
    }

    func snapshot(for url: URL) -> Snapshot? {
        guard let key = Self.originKey(for: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let state = origins[key] else { return nil }
        let since = state.lastRefusalAt.map {
            Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000
        }
        return Snapshot(inflight: state.inflight, peakInflight: state.peakInflight,
                        limit: state.limit, refusals: state.refusals,
                        secondsSinceLastRefusal: since, waiting: state.waiters.count)
    }

    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        for (_, state) in origins {
            for waiter in state.waiters { waiter.signal() }
        }
        origins.removeAll()
    }
}

/// #377: which transport a source is actually being fetched over, recorded once per origin.
///
/// The reporter's open question was whether a `httpMaximumConnectionsPerHost` cap does anything
/// against their CDN, and it cannot be answered from outside the engine: over HTTP/2 a URLSession
/// multiplexes its requests onto one connection and the cap bounds nothing, over http/1.1 it bounds
/// connections exactly. `URLSessionTaskMetrics.networkProtocolName` is the only place that says
/// which, so it gets logged once per origin, at the first metrics callback we receive.
///
/// One line per origin, not per request: it is a property of the server, and a line per 32 MB range
/// would say the same thing a few hundred times a session.
enum ReaderTransportLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var logged: Set<String> = []

    static func note(_ metrics: URLSessionTaskMetrics, for url: URL) {
        guard let key = OriginRequestBudget.originKey(for: url),
              let transaction = metrics.transactionMetrics.last,
              let proto = transaction.networkProtocolName else { return }
        lock.lock()
        let isNew = logged.insert(key).inserted
        lock.unlock()
        guard isNew else { return }
        // `reusedConnection` separates "one connection, many requests" from "a connection per
        // request", which is the other half of what a connection-capped origin is counting.
        EngineLog.emit(
            "[AVIOReader] origin transport: \(proto) at \(key) "
            + "(connection \(transaction.isReusedConnection ? "reused" : "new"), "
            + "\(proto.hasPrefix("h2") || proto.hasPrefix("h3") ? "multiplexed, so a per-session connection cap bounds nothing" : "one request per connection"))",
            category: .demux)
    }

    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        logged.removeAll()
    }
}
