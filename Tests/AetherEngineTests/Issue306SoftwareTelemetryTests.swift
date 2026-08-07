import Foundation
import Testing
import AVFoundation
@testable import AetherEngine

/// #306: a software session publishes network telemetry of its own.
///
/// Two separate defects hid behind one symptom. The byte counter the sampler derives every
/// byte-shaped figure from was read through `nativeVideoSession`, which a software session does not
/// have, so bitrate, throughput and transferred bytes were a hard zero for the whole session rather
/// than the real numbers. And the read-ahead the path does hold was computed for the memprobe only,
/// so nothing on the public surface answered "is the network keeping up" where it matters most.
@MainActor
struct Issue306SoftwareTelemetryTests {

    private func makeSoftwareEngine() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.playbackBackend = .software
        return engine
    }

    private func waitUntil(
        timeout: Duration = .seconds(90),
        _ condition: @MainActor () -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while !condition() {
            if clock.now - start > timeout { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: - The byte counter

    /// The precedence, stated directly: only one of the two readers exists per session, and the
    /// software one is the half that used to be dropped on the floor.
    @Test("the pump byte counter prefers the software reader over the native one")
    func pumpBytesPrefersSoftwareReader() {
        #expect(AetherEngine.pumpBytesFetched(software: 4_096, native: nil) == 4_096)
        #expect(AetherEngine.pumpBytesFetched(software: nil, native: 8_192) == 8_192)
        #expect(AetherEngine.pumpBytesFetched(software: nil, native: nil) == 0)
        // A software session that has read nothing yet is still the authority: falling back to the
        // native side here would publish a stale counter from a previous native session.
        #expect(AetherEngine.pumpBytesFetched(software: 0, native: 8_192) == 0)
    }

    // MARK: - The software snapshot

    @Test("a software tick publishes cushion, reader runway and dropped frames")
    func softwareTickPublishesReadAhead() async throws {
        let engine = try makeSoftwareEngine()
        let sampler = LiveTelemetrySampler(engine: engine, softwareRead: { _ in
            SoftwareReadings(
                displayCushionSeconds: 0.36,
                readerWindowAheadBytes: 3_145_728,
                droppedFrameCount: 8,
                accumulatedFrameDelaySeconds: 0.21)
        })
        sampler.start()
        let published = try await waitUntil { engine.diagnostics.liveTelemetry != nil }
        #expect(published)
        let snapshot = engine.diagnostics.liveTelemetry
        #expect(snapshot?.displayCushionSeconds == 0.36)
        #expect(snapshot?.readerWindowAheadBytes == 3_145_728)
        #expect(snapshot?.droppedFrameCount == 8)
        #expect(snapshot?.accumulatedFrameDelaySeconds == 0.21)
        sampler.stop()
    }

    /// The cushion is a fraction of a second on a perfectly healthy session, so publishing it as the
    /// forward buffer would report a near-stall with confidence. It stays nil, and the two fields that
    /// carry the software path's runway say what they are.
    @Test("the forward buffer stays nil on the software path")
    func forwardBufferStaysNilOnSoftware() async throws {
        let engine = try makeSoftwareEngine()
        let sampler = LiveTelemetrySampler(engine: engine, softwareRead: { _ in
            SoftwareReadings(displayCushionSeconds: 0.02)
        })
        sampler.start()
        let published = try await waitUntil { engine.diagnostics.liveTelemetry != nil }
        #expect(published)
        #expect(engine.diagnostics.liveTelemetry?.forwardBufferSeconds == nil)
        #expect(engine.diagnostics.liveTelemetry?.displayCushionSeconds == 0.02)
        sampler.stop()
    }

    /// An OS without `videoPerformanceMetrics`, or a session before the first frame: the fields read
    /// nil rather than zero. Zero is a measurement, nil is "not asked yet", and a host watchdog that
    /// cannot tell them apart reads a cold start as a perfect one.
    @Test("an unavailable metrics read publishes nil, not zero")
    func unavailableMetricsPublishNil() async throws {
        let engine = try makeSoftwareEngine()
        let sampler = LiveTelemetrySampler(engine: engine, softwareRead: { _ in SoftwareReadings() })
        sampler.start()
        let published = try await waitUntil { engine.diagnostics.liveTelemetry != nil }
        #expect(published)
        #expect(engine.diagnostics.liveTelemetry?.droppedFrameCount == nil)
        #expect(engine.diagnostics.liveTelemetry?.displayCushionSeconds == nil)
        #expect(engine.diagnostics.liveTelemetry?.accumulatedFrameDelaySeconds == nil)
        sampler.stop()
    }

    /// The metrics read is async, so a session can end under it. The native branch drops a snapshot
    /// whose player was swapped mid-read; the software branch owes the same guarantee.
    @Test("a backend change during the software read drops the snapshot")
    func backendChangeDuringReadDropsSnapshot() async throws {
        let engine = try makeSoftwareEngine()
        let entered = AtomicBool(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let sampler = LiveTelemetrySampler(engine: engine, softwareRead: { _ in
            entered.set(true)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    release.wait()
                    continuation.resume()
                }
            }
            return SoftwareReadings(displayCushionSeconds: 0.36)
        })
        sampler.start()
        let readStarted = try await waitUntil { entered.get() }
        #expect(readStarted)
        // Teardown seam: the session ends while the metrics read is still in flight.
        engine.playbackBackend = .none
        release.signal()
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.diagnostics.liveTelemetry == nil)
        sampler.stop()
    }

    /// The software fields are not a second name for values the native path already publishes: a
    /// native tick leaves them nil whatever the software read would have returned.
    @Test("a native tick leaves the software fields nil")
    func nativeTickLeavesSoftwareFieldsNil() async throws {
        let engine = try AetherEngine()
        engine.playbackBackend = .native
        engine.currentAVPlayer = AVPlayer(
            playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-306.mp4")))
        let sampler = LiveTelemetrySampler(
            engine: engine,
            nativeRead: { _, _ in NativeAVFReadings(forwardBufferSeconds: 12.0) },
            softwareRead: { _ in SoftwareReadings(displayCushionSeconds: 0.36, droppedFrameCount: 8) })
        sampler.start()
        let published = try await waitUntil { engine.diagnostics.liveTelemetry != nil }
        #expect(published)
        #expect(engine.diagnostics.liveTelemetry?.forwardBufferSeconds == 12.0)
        #expect(engine.diagnostics.liveTelemetry?.displayCushionSeconds == nil)
        #expect(engine.diagnostics.liveTelemetry?.accumulatedFrameDelaySeconds == nil)
        sampler.stop()
    }
}
