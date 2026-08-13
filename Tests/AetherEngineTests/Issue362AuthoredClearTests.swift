import Testing
import Foundation
import CoreGraphics
@testable import AetherEngine

/// #362: a display set closed by its successor instead of by its own clear packet.
///
/// A PGS composition has no end of its own; the decoder stamps FFmpeg's `end_display_time =
/// UINT32_MAX` placeholder and whatever packet follows on that stream closes it. The drain decodes
/// a window bounded at `playhead + lead`, and that forward edge falls wherever it falls: when it
/// lands between a set and the clear 3.5 s later, the set publishes open and the clear is never
/// decoded, because the cursor only moves forward and the next reset starts at a new landing.
/// The set is then closed by whatever composition turns up next, which after a seek burst is tens
/// or hundreds of seconds away (report: 3.55 s authored, 76.7 s delivered).
///
/// The packet store already holds that clear. It is harvested by the pump far ahead of the drain
/// window, so the authored end is available at the moment the set publishes; nothing had asked for
/// it. The numbers below are the report's.
@Suite("#362: an open set takes its end from the next stored packet")
struct Issue362AuthoredClearTests {

    private let placeholder = 4_294_967.295   // UINT32_MAX ms, as EmbeddedSubtitleDecoder stamps it
    private let setStart = 2692.356
    private let authoredClear = 2695.902
    private let successorStart = 2769.141     // what closed it instead

    private func imageCue(id: Int, start: Double, end: Double) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)
        return SubtitleCue(id: id, startTime: start, endTime: end, body: .image(image))
    }

    private func textCue(id: Int, start: Double, end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text("line"))
    }

    /// The report's region, as `ffprobe -show_packets` reads it: sets and their 30-byte clears.
    private func reportedStore() -> SubtitlePacketStore {
        let store = SubtitlePacketStore()
        for (pts, size) in [(2692.356, 25749), (2695.902, 30), (2713.836, 10129), (2715.796, 30),
                            (2716.088, 9234), (2719.342, 30), (2769.141, 12989), (2771.143, 30)] {
            store.append(streamIndex: 3, ptsSeconds: pts, durationSeconds: 0,
                         payload: Data(count: size))
        }
        return store
    }

    // MARK: - The reported case

    @Test("the open set is closed at its own clear packet, not at its successor")
    func openSetTakesTheAuthoredClear() {
        let store = reportedStore()
        var cues = [imageCue(id: 248, start: setStart, end: setStart + placeholder)]
        #expect(AetherEngine.closeOpenEndedCues(&cues, atNextPacket: {
            store.firstPTS(streamIndex: 3, after: $0)
        }))
        #expect(cues[0].endTime == authoredClear)
        #expect(cues[0].endTime != successorStart)
        // 3.546 s authored against the 76.785 s the report measured.
        #expect(cues[0].endTime - cues[0].startTime < 4)
    }

    @Test("the authored end survives the reconstruction-window close that would otherwise launder it")
    func authoredEndSurvivesTheResetBoundary() {
        // Ordering claim: the store close runs while the set is still in the window it was decoded
        // in, so by the time a seek lands and #357's boundary close runs, there is nothing open
        // left to launder. Without it the same cue reads `end = landing - 15`, off by seconds and
        // owned by the seek rather than by the author.
        let store = reportedStore()
        var cues = [imageCue(id: 248, start: setStart, end: setStart + placeholder)]
        _ = AetherEngine.closeOpenEndedCues(&cues, atNextPacket: {
            store.firstPTS(streamIndex: 3, after: $0)
        })
        #expect(!AetherEngine.closeOpenEndedCues(&cues, startingBefore: 2855.15 - 15))
        #expect(cues[0].endTime == authoredClear)
    }

    @Test("every set in the region gets its own clear")
    func wholeRegionIsAuthored() {
        let store = reportedStore()
        var cues = [
            imageCue(id: 248, start: 2692.356, end: 2692.356 + placeholder),
            imageCue(id: 334, start: 2713.836, end: 2713.836 + placeholder),
            imageCue(id: 335, start: 2716.088, end: 2716.088 + placeholder),
        ]
        #expect(AetherEngine.closeOpenEndedCues(&cues, atNextPacket: {
            store.firstPTS(streamIndex: 3, after: $0)
        }))
        #expect(cues[0].endTime == 2695.902)
        #expect(cues[1].endTime == 2715.796)
        #expect(cues[2].endTime == 2719.342)
    }

    // MARK: - What must survive it

    @Test("a set whose successor is not stored yet stays open for the next tick")
    func unstoredSuccessorLeavesItOpen() {
        // The store is the frontier of what the pump has harvested. Beyond it there is no authored
        // answer, and inventing one (the drain window edge, the retention cutoff) is exactly the
        // laundering this fix removes. It stays open, and #357's reset close remains the last
        // resort for a cue a seek then jumps past.
        let store = SubtitlePacketStore()
        store.append(streamIndex: 3, ptsSeconds: setStart, durationSeconds: 0, payload: Data(count: 4))
        var cues = [imageCue(id: 248, start: setStart, end: setStart + placeholder)]
        #expect(!AetherEngine.closeOpenEndedCues(&cues, atNextPacket: {
            store.firstPTS(streamIndex: 3, after: $0)
        }))
        #expect(cues[0].endTime == setStart + placeholder)
    }

    @Test("an authored duration is left alone, however long")
    func authoredDurationUntouched() {
        // Same discriminator as #357: only a placeholder window is unconfirmed. A typeset sign that
        // genuinely runs a minute keeps its end even though a packet follows it.
        let store = reportedStore()
        var cues = [textCue(id: 0, start: 2692.356, end: 2752.356)]
        #expect(!AetherEngine.closeOpenEndedCues(&cues, atNextPacket: {
            store.firstPTS(streamIndex: 3, after: $0)
        }))
        #expect(cues[0].endTime == 2752.356)
    }

    @Test("a closed cue reports no change, so the tick does not publish for nothing")
    func noChangeWithoutAnOpenCue() {
        let store = reportedStore()
        var cues = [imageCue(id: 248, start: setStart, end: authoredClear)]
        #expect(!AetherEngine.closeOpenEndedCues(&cues, atNextPacket: {
            store.firstPTS(streamIndex: 3, after: $0)
        }))
        var empty: [SubtitleCue] = []
        #expect(!AetherEngine.closeOpenEndedCues(&empty, atNextPacket: { _ in 1 }))
    }

    // MARK: - The store query

    @Test("the next packet is strictly after the set, so a same-PTS chunk run cannot close it at itself")
    func samePTSChunksAreSkipped() {
        // A PGS display set reaches the store as one entry per container packet, but a raw SUP
        // stream and a split MPEG-TS PES both put several same-PTS chunks in a row. Closing a set
        // at its own PTS would produce a zero-length cue that renders nowhere.
        let store = SubtitlePacketStore()
        for size in [22, 13, 20, 7618] {   // PCS, WDS, PDS, ODS of one display set
            store.append(streamIndex: 3, ptsSeconds: setStart, durationSeconds: 0,
                         payload: Data(count: size))
        }
        store.append(streamIndex: 3, ptsSeconds: authoredClear, durationSeconds: 0,
                     payload: Data(count: 30))
        #expect(store.firstPTS(streamIndex: 3, after: setStart) == authoredClear)
    }

    // MARK: - The harvest has to lead the decode

    @Test("the forward prefetch parks past the drain window, or the edge set has no answer stored")
    func harvestLeadsTheDecode() {
        // The measured half of the fix. With both lines at 60 s the last set inside the window is
        // systematically the one whose clear is not stored: a fixture run with 25 seeks left 5 sets
        // open and 11 with a laundered end; with the margin, 0 and 1 (the one being a harvest hole,
        // not a window edge). The OCR lead already carries its own margin over the OCR window, which
        // is the same rule applied to the other consumer of this store.
        #expect(AetherEngine.subtitleForwardPrefetchLeadMarginSeconds > 0)
        #expect(AetherEngine.subtitleDrainLeadSeconds
                + AetherEngine.subtitleForwardPrefetchLeadMarginSeconds
                > AetherEngine.subtitleDrainLeadSeconds)
        #expect(AetherEngine.subtitleOCRPrefetchLeadSeconds > AetherEngine.subtitleOCRLeadSeconds)
    }

    @Test("the query answers per stream and reports nothing past the frontier")
    func perStreamAndFrontier() {
        let store = reportedStore()
        #expect(store.firstPTS(streamIndex: 3, after: 0) == 2692.356)
        #expect(store.firstPTS(streamIndex: 3, after: 2771.143) == nil)   // the frontier itself
        #expect(store.firstPTS(streamIndex: 4, after: 0) == nil)          // a stream with nothing
    }
}
