import Testing
import Foundation
import CoreGraphics
import AetherLibavutil
@testable import AetherEngine

/// Regression: FrameExtractor used coded width/height only, ignoring SAR, so anamorphic DVD
/// thumbnails rendered at 3:2 instead of 4:3. displayDimensions must fold SAR into output height.
struct FrameExtractorSARTests {

    private func ratio(_ wh: (Int, Int)) -> Double { Double(wh.0) / Double(wh.1) }

    @Test("NTSC 4:3 DVD thumbnail comes out 4:3, not 3:2")
    func ntsc43() {
        // 720x480 stored, SAR 8:9 -> displays 4:3.
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 720, srcH: 480, sar: AVRational(num: 8, den: 9), targetWidth: 320)
        #expect(dims.0 == 320)
        #expect(abs(ratio(dims) - 4.0 / 3.0) < 0.01,
                "expected 4:3, got \(dims.0)x\(dims.1) = \(ratio(dims))")
    }

    @Test("Widescreen anamorphic DVD thumbnail comes out 16:9")
    func anamorphic169() {
        // 720x480 stored, SAR 32:27 -> displays 16:9.
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 720, srcH: 480, sar: AVRational(num: 32, den: 27), targetWidth: 320)
        #expect(abs(ratio(dims) - 16.0 / 9.0) < 0.01,
                "expected 16:9, got \(dims.0)x\(dims.1) = \(ratio(dims))")
    }

    @Test("PAL 4:3 DVD thumbnail comes out 4:3")
    func pal43() {
        // 720x576 stored, SAR 16:15 (generic PAL 4:3) -> displays 4:3.
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 720, srcH: 576, sar: AVRational(num: 16, den: 15), targetWidth: 320)
        #expect(abs(ratio(dims) - 4.0 / 3.0) < 0.01,
                "expected 4:3, got \(dims.0)x\(dims.1) = \(ratio(dims))")
    }

    @Test("BT.601 PAL SAR 12:11 applies (slightly wider than exact 4:3)")
    func pal601() {
        // SAR 12:11 yields ~1.364, not exact 4:3; must be applied (square would give 1.25).
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 720, srcH: 576, sar: AVRational(num: 12, den: 11), targetWidth: 320)
        #expect(abs(ratio(dims) - (720.0 * 12.0) / (576.0 * 11.0)) < 0.01,
                "SAR 12:11 not applied: got \(dims.0)x\(dims.1) = \(ratio(dims))")
    }

    @Test("Square-pixel source keeps its coded aspect")
    func squarePixels() {
        // 1920x1080 square pixels -> 16:9 unchanged.
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 1920, srcH: 1080, sar: AVRational(num: 1, den: 1), targetWidth: 320)
        #expect(dims.0 == 320 && dims.1 == 180)
    }

    @Test("Degenerate 0:0 SAR is treated as square")
    func degenerateSAR() {
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 640, srcH: 480, sar: AVRational(num: 0, den: 0), targetWidth: 320)
        #expect(dims.0 == 320 && dims.1 == 240)
    }

    @Test("Snapshot bounds use displayed aspect, including HDR tone mapping", arguments: [false, true])
    func snapshotDisplayBounds(hdr: Bool) async throws {
        let fixture = hdr ? Self.hdrAnamorphic : Self.sdrAnamorphic
        let data = try #require(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
        let probe = FrameDecodeContext(reader: DataIOReader(data: data), formatHint: "mp4")
        try probe.ensureOpen()
        #expect(probe.isHDR == hdr)
        probe.close()
        let extractor = FrameExtractor(reader: DataIOReader(data: data), formatHint: "mp4")
        for maxSize in [CGSize(width: 1000, height: 10), CGSize(width: 12.5, height: 10.5)] {
            let image = try #require(await extractor.snapshot(at: 0, maxSize: maxSize))
            #expect(CGFloat(image.width) <= maxSize.width)
            #expect(CGFloat(image.height) <= maxSize.height)
            #expect(image.width == (maxSize.width > 100 ? 13 : 12))
            #expect(image.height == (maxSize.width > 100 ? 10 : 9))
        }
        let preview = try #require(await extractor.preview(at: 0, maxWidth: 16))
        #expect(preview.width == 16 && preview.height == 12)
        let native = try #require(await extractor.snapshot(at: 0))
        #expect(native.width == 72 && native.height == 54)
        let oversizedPreview = try #require(await extractor.preview(at: 0, maxWidth: 320))
        #expect(oversizedPreview.width == 72 && oversizedPreview.height == 54)
        await extractor.shutdown()
    }

    @Test("HDR tone mapping produces exact square-pixel bounds without falling back")
    func toneMappedDimensions() throws {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        let f = try #require(frame)
        defer { av_frame_free(&frame) }
        f.pointee.width = 72
        f.pointee.height = 48
        f.pointee.format = AV_PIX_FMT_YUV420P10LE.rawValue
        f.pointee.color_primaries = AVCOL_PRI_BT2020
        f.pointee.color_trc = AVCOL_TRC_SMPTE2084
        f.pointee.colorspace = AVCOL_SPC_BT2020_NCL
        f.pointee.color_range = AVCOL_RANGE_MPEG
        let sar = AVRational(num: 8, den: 9)
        f.pointee.sample_aspect_ratio = sar
        try #require(av_frame_get_buffer(f, 32) >= 0)
        for (plane, stride, rows) in [(f.pointee.data.0, f.pointee.linesize.0, 48),
                                     (f.pointee.data.1, f.pointee.linesize.1, 24),
                                     (f.pointee.data.2, f.pointee.linesize.2, 24)] {
            let base = try #require(plane)
            let pixels = UnsafeMutableRawPointer(base).assumingMemoryBound(to: UInt16.self)
            for index in 0..<(Int(stride) * rows / 2) { pixels[index] = 512 }
        }
        for (width, height) in [(13, 10), (12, 9), (320, 54)] {
            var toned = HDRToneMapper.toneMap(frame: f, targetWidth: width,
                timeBase: AVRational(num: 1, den: 1), sar: sar, highQuality: true)
            let output = try #require(toned)
            #expect(output.pointee.width == min(width, 72))
            #expect(output.pointee.height == height)
            av_frame_free(&toned)
        }
    }

    // One synthetic 72x48 H.264 frame, SAR 8:9. Generate with ffmpeg:
    // -f lavfi -i color=c=gray:size=72x48:rate=1:duration=1 -vf setsar=8/9
    // -c:v libx264 -threads 1 -preset ultrafast -crf 20 -pix_fmt yuv420p -movflags +faststart
    // The HDR twin adds setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc
    // after setsar in the filter chain.

    private static let sdrAnamorphic = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMSbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAA
        AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
        Aj10cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
        AAAAAAAAAAAAAABAAAAAAEAAAAAwAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAAAAG1bWRpYQAAACBtZGhk
        AAAAAAAAAAAAAAAAAABAAAAAQABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABYG1p
        bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAASBzdGJsAAAAvHN0c2QA
        AAAAAAAAAQAAAKxhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEgAMABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4
        MjY0AAAAAAAAAAAAAAAAGP//AAAAMmF2Y0MBQsAK/+EAG2dCwAraFfl//AAgACRAAAADAEAAAAMAg8SJqAEABGjOBvIAAAAQcGFz
        cAAAAAgAAAAJAAAAFGJ0cnQAAAAAAAATcAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAAQAAQAAAAAAcc3RzYwAAAAAAAAABAAAAAQAA
        AAEAAAABAAAAFHN0c3oAAAAAAAACbgAAAAEAAAAUc3RjbwAAAAAAAAABAAADQgAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIA
        AAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDIAAAAIZnJl
        ZQAAAnZtZGF0AAACUwYF//9P3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBF
        Ry00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9w
        dGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9
        MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFk
        em9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNs
        aWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50
        cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0w
        IHJjPWNyZiBtYnRyZWU9MCBjcmY9MjAuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40
        MCBhcT0wAIAAAAATZYiEOiYoAMnJycnXXXXXXXXXXg==
        """

    private static let hdrAnamorphic = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMpbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAA
        AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
        AlR0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
        AAAAAAAAAAAAAABAAAAAAEAAAAAwAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAAAAHMbWRpYQAAACBtZGhk
        AAAAAAAAAAAAAAAAAABAAAAAQABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABd21p
        bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAATdzdGJsAAAA03N0c2QA
        AAAAAAAAAQAAAMNhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEgAMABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4
        MjY0AAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBQsAK/+EAH2dCwAraFfl//AAgACWoSIBKAAADAAIAAAMABB4kTUABAARozgbyAAAA
        E2NvbHJuY2x4AAkAEAAJAAAAABBwYXNwAAAACAAAAAkAAAAUYnRydAAAAAAAABNwAAAAAAAAABhzdHRzAAAAAAAAAAEAAAABAABA
        AAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEAAAAUc3RzegAAAAAAAAJuAAAAAQAAABRzdGNvAAAAAAAAAAEAAANZAAAAYXVk
        dGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAAB
        AAAAAExhdmY2My4xLjEwMgAAAAhmcmVlAAACdm1kYXQAAAJTBgX//0/cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIz
        MjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRl
        b2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRp
        YSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxp
        cz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0x
        IGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9j
        b21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTEgc2Nl
        bmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMC4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02
        OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAABNliIQ6JigAycnJydddddddddde
        """
}
