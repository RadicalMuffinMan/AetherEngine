// AE#886: a constant-rate track on Matroska's 1 ms time base is muxed on its exact frame grid.
import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

@Suite("CFRFrameGrid (AE#886)")
struct CFRFrameGridTests {
    private let ms = AVRational(num: 1, den: 1000)

    /// What mkvmerge writes for frame `n` of a track starting at `origin` ms.
    private func matroskaPts(_ n: Int64, rate: Double, origin: Int64 = 0) -> Int64 {
        origin + Int64((Double(n) * 1000 / rate).rounded())
    }

    @Test("23.976 on 1 ms gets 1/24000 with 1001 ticks a frame")
    func grid23976() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        #expect(grid.outputTimeBase.num == 1 && grid.outputTimeBase.den == 24000)
        #expect(grid.frameTicks == 1001)
    }

    @Test("24, 29.97, 30, 59.94 and 60 get a grid; 25 and 50 fit 1 ms and do not")
    func whichRatesGetAGrid() {
        func frame(_ num: Int32, _ den: Int32) -> Int64? {
            CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: num, den: den), startPts: 0)?.frameTicks
        }
        #expect(frame(24, 1) == 1000)
        #expect(frame(30000, 1001) == 1001)
        #expect(frame(30, 1) == 1000)
        #expect(frame(60000, 1001) == 1001)
        #expect(frame(60, 1) == 1000)
        #expect(frame(25, 1) == nil)
        #expect(frame(50, 1) == nil)
    }

    @Test("A fine time base, an odd rate or a missing rate gets no grid")
    func noGrid() {
        let rate = AVRational(num: 24000, den: 1001)
        #expect(CFRFrameGrid.make(sourceTimeBase: AVRational(num: 1, den: 90000), frameRate: rate, startPts: 0) == nil)
        #expect(CFRFrameGrid.make(sourceTimeBase: AVRational(num: 1, den: 16000), frameRate: rate, startPts: 0) == nil)
        #expect(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 2397, den: 100), startPts: 0) == nil)
        #expect(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 0, den: 1), startPts: 0) == nil)
    }

    @Test("24.000 and 23.976 are never confused")
    func ratesStayApart() throws {
        let grid24 = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24, den: 1), startPts: 0))
        let grid23 = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        #expect(grid24.frameTicks == 1000)
        #expect(grid23.frameTicks == 1001)
    }

    @Test("Millisecond-rounded 23.976 frames land on exact 1001-tick steps across two hours")
    func snapsRoundedFrames() throws {
        let rate = 24000.0 / 1001.0
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        for n in stride(from: Int64(0), to: 172_800, by: 7) {
            #expect(grid.snap(matroskaPts(n, rate: rate)) == n * 1001)
        }
    }

    @Test("The origin is the stream's start time")
    func originFromStartTime() throws {
        let rate = 24000.0 / 1001.0
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 1400))
        for n: Int64 in [0, 1, 2, 3, 1000, 50_001] {
            #expect(grid.snap(matroskaPts(n, rate: rate, origin: 1400)) == 1400 * 24 + n * 1001)
        }
    }

    @Test("A timestamp more than one source tick off the grid keeps its own time")
    func offGridPassesThrough() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        // Frame 1 is 41.708 ms; one source tick is 24 output ticks.
        #expect(grid.snap(41) == 1001)
        #expect(grid.snap(42) == 1001)
        #expect(grid.snap(43) == nil)
        #expect(grid.snap(20) == nil)
        #expect(grid.snap(Int64.min) == nil)
    }

    @Test("A packet keeps reorder order, its DTS never passes its PTS, and the shift moves both")
    func placePacket() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        let b = grid.place(pts: 125, dts: 83, duration: 42, shift: 0)
        #expect(b.pts == 3003 && b.dts == 2002 && b.duration == 1001)
        // DTS repaired off the grid (lastValidDts + 1) stays where the rescale puts it.
        let head = grid.place(pts: 42, dts: 2, duration: 41, shift: 0)
        #expect(head.pts == 1001 && head.dts == 48)
        // A DTS that rounds onto the PTS slot or past it is held at the PTS.
        let flat = grid.place(pts: 42, dts: 43, duration: 42, shift: 0)
        #expect(flat.dts <= flat.pts)
        // Item axis = source - shift; the grid is decided on the source axis.
        let shifted = grid.place(pts: 125 - 1400, dts: 83 - 1400, duration: 42, shift: 1400)
        #expect(shifted.pts == 3003 - 1400 * 24 && shifted.dts == 2002 - 1400 * 24)
        let off = grid.place(pts: 20, dts: 20, duration: 42, shift: 0)
        #expect(!off.onGrid && off.pts == 20 * 24 && off.dts == 20 * 24)
    }

    @Test("A duration spans to the next DTS on the same mapping")
    func durationFollowsTheDtsMapping() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        #expect(grid.place(pts: 42, dts: 42, duration: 84, shift: 0).duration == 2002)
        #expect(grid.place(pts: 42, dts: 42, duration: 0, shift: 0).duration == 0)
    }

    /// Device log 2026-10-29, Apple TV at 24 Hz, 24.000 fps H.264 Matroska: movenc logged
    /// `Packet duration: -16 / dts: 27710016` and `pts has no value` at most segment starts.
    @Test("Telescoped durations end exactly where the next packet starts (#886 seam)")
    func fragmentSeamStaysContiguous() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24, den: 1), startPts: 0))
        // Decode order from that log: a DTS 1.33 ms off its slot, then a keyframe whose PTS is off the grid.
        let packets: [(pts: Int64, dts: Int64)] = [
            (1_154_625, 1_154_500), (1_154_708, 1_154_543), (1_154_668, 1_154_584), (1_154_750, 1_154_626),
        ]
        var placed: [(pts: Int64, dts: Int64, duration: Int64, onGrid: Bool)] = []
        for (i, packet) in packets.enumerated() {
            let duration = i + 1 < packets.count ? packets[i + 1].dts - packet.dts : 42
            placed.append(grid.place(pts: packet.pts, dts: packet.dts, duration: duration, shift: 0))
        }
        for i in 0..<(placed.count - 1) {
            #expect(placed[i].dts + placed[i].duration == placed[i + 1].dts,
                    "packet \(i) ends at \(placed[i].dts + placed[i].duration), packet \(i + 1) starts at \(placed[i + 1].dts)")
        }
        #expect(!placed[2].onGrid)

        // Every millisecond offset a 24 fps title can carry, on and off the grid, in B-frame decode order.
        for jitter: Int64 in 0...2 {
            var last: (dts: Int64, duration: Int64)?
            for n: Int64 in 0..<480 {
                let pts = matroskaPts(n + 2, rate: 24) + (n % 3 == 1 ? jitter : 0)
                let dts = matroskaPts(n, rate: 24) + (n % 5 == 2 ? jitter : 0)
                let next = matroskaPts(n + 1, rate: 24) + ((n + 1) % 5 == 2 ? jitter : 0)
                let out = grid.place(pts: pts, dts: dts, duration: next - dts, shift: 0)
                if let last { #expect(last.dts + last.duration == out.dts, "jitter \(jitter) frame \(n)") }
                last = (out.dts, out.duration)
            }
        }
    }
}
