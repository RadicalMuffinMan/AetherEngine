import XCTest
@testable import AetherEngine

/// AE#359. Fixtures are real MDR Sachsen segments off
/// `master-subs-1200.m3u8`, including their 164 hour LOCAL clock: the numbers a cue carries are
/// meaningless until X-TIMESTAMP-MAP anchors them to the program's 90 kHz clock.
final class WebVTTSegmentParserTests: XCTestCase {

    private let seg133 = """
    WEBVTT
    X-TIMESTAMP-MAP=LOCAL:159:04:22.306,MPEGTS:183000

    164:04:24.000 --> 164:04:25.440
    Alles klar?
    - Ja, ja.

    164:04:25.920 --> 164:04:26.000
    Fahren wir in die Sachsenklinik!
    - Nein, es geht gleich wieder.
    """

    private let seg134 = """
    WEBVTT
    X-TIMESTAMP-MAP=LOCAL:159:04:22.306,MPEGTS:183000

    164:04:26.000 --> 164:04:28.000
    Fahren wir in die Sachsenklinik!
    - Nein, es geht gleich wieder.
    """

    private func seconds(_ h: Double, _ m: Double, _ s: Double) -> Double { h * 3600 + m * 60 + s }

    // MARK: - Parsing

    func testReadsTheTimestampMapAndBothCues() throws {
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(seg133))
        XCTAssertEqual(segment.anchorMPEGTS90k, 183_000)
        XCTAssertEqual(segment.anchorLocalSeconds, seconds(159, 4, 22.306), accuracy: 0.001)
        XCTAssertEqual(segment.cues.count, 2)
        XCTAssertEqual(segment.cues.first?.text, "Alles klar?\n- Ja, ja.")
        XCTAssertEqual(segment.cues.first?.start ?? 0, seconds(164, 4, 24.0), accuracy: 0.001)
        XCTAssertEqual(segment.cues.first?.end ?? 0, seconds(164, 4, 25.44), accuracy: 0.001)
    }

    /// Without the map there is no way to place a cue on the program clock, and taking the numbers at
    /// face value would put subtitles hours away from the picture. Refusing is the honest outcome.
    func testRefusesASegmentWithoutATimestampMap() {
        XCTAssertNil(WebVTTSegmentParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi"))
    }

    func testAcceptsTheMapWithItsFieldsInEitherOrder() throws {
        let text = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:10.000\n\n00:00:11.000 --> 00:00:12.000\nhi"
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(text))
        XCTAssertEqual(segment.anchorMPEGTS90k, 900_000)
        XCTAssertEqual(segment.anchorLocalSeconds, 10, accuracy: 0.001)
    }

    /// Cue settings sit on the timing line and are not dialogue; an identifier may precede it.
    func testIgnoresCueIdentifiersAndSettings() throws {
        let text = """
        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0

        cue-7
        00:00:01.000 --> 00:00:02.000 line:0 position:50%
        Text
        """
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(text))
        XCTAssertEqual(segment.cues.count, 1)
        XCTAssertEqual(segment.cues.first?.text, "Text")
    }

    // MARK: - Mapping onto the player clock

    func testMapsCueTimesThroughTheAnchorAndTheShift() throws {
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(seg133))
        // Program time of the first cue: anchor 183000/90000 s plus its distance from the LOCAL anchor.
        let expectedProgram = 183_000.0 / 90_000 + (seconds(164, 4, 24.0) - seconds(159, 4, 22.306))
        var nextID = 0
        let cues = WebVTTSegmentParser.cues(from: segment, shiftSeconds: 1000, nextID: &nextID)
        XCTAssertEqual(cues.first?.startTime ?? 0, expectedProgram - 1000, accuracy: 0.01)
    }

    /// The 33 bit MPEGTS clock wraps every ~95443 s. A cue just past a wrap while the session's shift
    /// sits just before it must land a second later, not 95443 seconds earlier.
    func testWrapAroundIsFoldedInsteadOfProducingAHugeJump() throws {
        let range = 8_589_934_592.0 / 90_000
        let text = """
        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:90000

        00:00:01.000 --> 00:00:02.000
        after the wrap
        """
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(text))
        var nextID = 0
        // Shift one second before the wrap point; the cue's program time is 2 s, i.e. just after it.
        let cues = WebVTTSegmentParser.cues(from: segment, shiftSeconds: range - 1, nextID: &nextID)
        XCTAssertEqual(cues.first?.startTime ?? 0, 3, accuracy: 0.01)
    }

    // MARK: - Cross-segment repeats

    func testACueRepeatedInTheNextSegmentExtendsTheExistingOne() throws {
        var nextID = 0
        let first = WebVTTSegmentParser.cues(from: try XCTUnwrap(WebVTTSegmentParser.parse(seg133)),
                                             shiftSeconds: 0, nextID: &nextID)
        let second = WebVTTSegmentParser.cues(from: try XCTUnwrap(WebVTTSegmentParser.parse(seg134)),
                                              shiftSeconds: 0, nextID: &nextID)
        let merged = WebVTTSegmentParser.merged(into: first, adding: second, nextID: &nextID)
        XCTAssertEqual(merged.count, 2, "the repeated line must extend its cue, not become a third one")
        let last = try XCTUnwrap(merged.last)
        XCTAssertEqual(last.endTime - last.startTime, 2.08, accuracy: 0.01)
    }

    func testADifferentLineIsAppended() throws {
        var nextID = 0
        let first = WebVTTSegmentParser.cues(from: try XCTUnwrap(WebVTTSegmentParser.parse(seg133)),
                                             shiftSeconds: 0, nextID: &nextID)
        let other = """
        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:159:04:22.306,MPEGTS:183000

        164:04:26.000 --> 164:04:28.000
        Etwas ganz anderes
        """
        let second = WebVTTSegmentParser.cues(from: try XCTUnwrap(WebVTTSegmentParser.parse(other)),
                                              shiftSeconds: 0, nextID: &nextID)
        XCTAssertEqual(WebVTTSegmentParser.merged(into: first, adding: second, nextID: &nextID).count, 3)
    }

    /// Refetching the same segment (playlist poll before the window moved) must change nothing.
    func testResendingTheSameSegmentIsIdempotent() throws {
        var nextID = 0
        let cues = WebVTTSegmentParser.cues(from: try XCTUnwrap(WebVTTSegmentParser.parse(seg133)),
                                            shiftSeconds: 0, nextID: &nextID)
        let again = WebVTTSegmentParser.cues(from: try XCTUnwrap(WebVTTSegmentParser.parse(seg133)),
                                             shiftSeconds: 0, nextID: &nextID)
        let merged = WebVTTSegmentParser.merged(into: cues, adding: again, nextID: &nextID)
        XCTAssertEqual(merged.count, cues.count)
    }
}
