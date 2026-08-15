import XCTest
@testable import AetherEngine

/// The documentation quotes numbers. "32 entries", "six hours", "a quarter of the tmp volume's free
/// space, capped at 2 GiB", "the historical default of 10". Every one of those is a constant living
/// somewhere in `Sources/`, copied into prose by hand, and nothing has ever held the two together:
/// change the constant and the docs keep asserting the old value in a sentence that still reads
/// perfectly. That is the same failure the API-coverage tests exist for, one level down. A wrong
/// number is worse than a missing one, because a reader budgets against it.
///
/// So each check below pins a documented number to the code that owns it, and names the sentence to
/// fix when it moves. The check is deliberately NOT "the constant is right": that is a product
/// decision and belongs in the test that covers the behaviour. It is "the docs and the code still
/// say the same thing", and the fix for a failure here is usually one word in one Markdown file.
///
/// Adding a number to the docs? Pin it here in the same commit.
@MainActor
final class DocumentedConstantsTests: XCTestCase {

    // MARK: - Documentation corpus

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func documentation() throws -> String {
        let root = Self.repoRoot
        guard let readme = try? String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8),
              let entries = try? FileManager.default.contentsOfDirectory(
                  atPath: root.appendingPathComponent("docs").path)
        else { throw XCTSkip("running outside a source checkout; no docs to check against") }
        let markdown = entries.filter { $0.hasSuffix(".md") }.sorted().compactMap {
            try? String(contentsOf: root.appendingPathComponent("docs/\($0)"), encoding: .utf8)
        }
        return ([readme] + markdown).joined(separator: "\n")
    }

    /// Asserts the docs still contain the sentence fragment that states this number.
    private func assertDocumented(_ phrase: String, _ docs: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(docs.contains(phrase), """
            The documentation no longer contains "\(phrase)".
            Either the wording moved (update this pin) or the statement was dropped (put it back).
            """, file: file, line: line)
    }

    // MARK: - The reroute verdict memory (#199)

    /// docs/api.md and README both state the shape of the memory a same-URL live retune rides on.
    /// A shorter TTL or a smaller table silently makes that paragraph's "cheap" claim wrong.
    func testRerouteVerdictMemoryMatchesItsDocumentedShape() throws {
        let docs = try documentation()
        let now = Date()
        let url = URL(string: "https://origin.example/live/ch1.m3u8")!

        var memory = RerouteVerdictMemory()
        memory.record(url, now: now)

        XCTAssertTrue(memory.remembers(url, now: now.addingTimeInterval(6 * 3600 - 60)),
                      "documented as six hours; a verdict one minute short of that must still hold")
        XCTAssertFalse(memory.remembers(url, now: now.addingTimeInterval(6 * 3600 + 60)),
                       "documented as six hours; past it the origin gets another chance")
        assertDocumented("for six hours, 32 entries", docs)

        // Capacity, from the outside: 32 fresh entries evict the oldest one.
        var full = RerouteVerdictMemory()
        for i in 0..<33 {
            full.record(URL(string: "https://origin.example/ch\(i).m3u8")!,
                        now: now.addingTimeInterval(Double(i)))
        }
        XCTAssertFalse(full.remembers(URL(string: "https://origin.example/ch0.m3u8")!, now: now),
                       "documented as 32 entries; the 33rd must evict the oldest")
        XCTAssertTrue(full.remembers(URL(string: "https://origin.example/ch32.m3u8")!, now: now))
    }

    // MARK: - Forward buffer window

    /// README and docs/api.md both quote the default and the clamp of `forwardBufferSegments`.
    func testForwardWindowDefaultAndClampAreWhatTheDocsSay() throws {
        let docs = try documentation()
        XCTAssertEqual(HLSVideoEngine.clampedForwardWindow(nil), 10, "documented default")
        XCTAssertEqual(HLSVideoEngine.clampedForwardWindow(1), 4, "documented floor")
        XCTAssertEqual(HLSVideoEngine.clampedForwardWindow(Int.max), 2700, "documented ceiling")
        assertDocumented("Clamped to 4...2700", docs)
        assertDocumented("nil (10, about 40 s)", docs)
    }

    // MARK: - Retention budget

    /// The README's Seek row and the `forwardBufferSegments` entry both rest on the 2 GiB cap.
    func testRetentionBudgetCapIsTwoGiB() throws {
        let docs = try documentation()
        XCTAssertEqual(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: nil),
                       2 << 30, "documented as a 2 GiB cap")
        XCTAssertEqual(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: 8 << 30),
                       2 << 30, "a quarter of 8 GiB is the cap itself")
        XCTAssertEqual(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: 4 << 30),
                       1 << 30, "documented as a quarter of the volume's free space below the cap")
        assertDocumented("2 GiB cap", docs)
    }

    // MARK: - Probe budgets

    /// docs/api.md states the defaults a host overrides with `probesize` / `maxAnalyzeDuration`.
    func testProbeBudgetDefaultsAreWhatTheDocsSay() throws {
        let docs = try documentation()
        XCTAssertEqual(DemuxerOpenProfile.playback.probesize, 50 * 1024 * 1024, "documented as 50 MB")
        XCTAssertEqual(DemuxerOpenProfile.playback.maxAnalyzeDuration, 60 * 1_000_000, "documented as 60 s")
        assertDocumented("defaults 50 MB / 60 s", docs)
    }

    // MARK: - Startup ladder

    /// docs/api.md prints the ladder as a table AND states the total under it, which is the number a
    /// host's progress bar divides by. Adding a checkpoint without touching that sentence is exactly
    /// the change this catches.
    func testStartupLadderTotalMatchesTheDocumentedNumber() throws {
        let docs = try documentation()
        XCTAssertEqual(StartupCheckpoint.allCases.count, 9, "documented as nine checkpoints")
        XCTAssertEqual(StartupCheckpoint.total, 8, "documented: .dispatched is the origin, so total is eight")
        XCTAssertEqual(StartupCheckpoint.presenting.rawValue, StartupCheckpoint.total,
                       "the ladder must end exactly at total, or a bar never reaches 100%")
        assertDocumented("`total` is eight", docs)
    }

    // MARK: - Audio tap format

    /// README and docs/api.md both promise mono Float32 48 kHz to anything consuming the tap
    /// (SpeechAnalyzer, ShazamKit), and those consumers are configured against that promise.
    func testAudioTapFormatIsMonoFloat32At48k() throws {
        let docs = try documentation()
        let format = AetherEngine.audioTapFormat
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        assertDocumented("mono Float32 48 kHz", docs)
    }

    // MARK: - External subtitle ids

    /// A host tells its own tracks from the engine's by this base, and docs/api.md prints the number.
    func testExternalSubtitleTrackIDBaseIsDocumented() throws {
        let docs = try documentation()
        XCTAssertEqual(AetherEngine.externalSubtitleTrackIDBase, 100_000)
        assertDocumented("`100_000`", docs)
    }
}
