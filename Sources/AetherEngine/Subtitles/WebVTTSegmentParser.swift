import Foundation

/// One parsed WebVTT segment of an HLS SUBTITLES rendition (AE#359).
///
/// Cue times are in the segment's own LOCAL clock, which is meaningless on its own: providers run it
/// for days (MDR sits at 164 hours) while the program's 90 kHz clock wraps every ~26.5 hours.
/// `anchorLocalSeconds` and `anchorMPEGTS90k` are the `X-TIMESTAMP-MAP` pair that ties the two
/// together, and only that pair makes a cue placeable.
struct WebVTTSegment: Equatable {
    struct Cue: Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    let anchorLocalSeconds: Double
    let anchorMPEGTS90k: Int64
    let cues: [Cue]
}

/// Turns the `.vtt` segments of a live SUBTITLES rendition into engine cues.
///
/// Pure by design: the fetch loop owns the network and the lifetime, this owns the two things that
/// are easy to get silently wrong, the clock mapping and the cross-segment repeats. HLS repeats a
/// cue in every segment it overlaps, clipped to the segment boundary, so a collector that appends
/// publishes the same sentence three times in a row.
enum WebVTTSegmentParser {
    /// 33 bit MPEGTS clock, in seconds.
    static let mpegtsWrapSeconds = 8_589_934_592.0 / 90_000

    /// Cues from adjacent segments count as the same line when their ranges touch. Segment boundaries
    /// are cut on frame times, so the clipped halves rarely meet exactly.
    private static let joinTolerance = 0.25

    static func parse(_ text: String) -> WebVTTSegment? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .hasPrefix("WEBVTT") == true else { return nil }
        guard let mapLine = lines.first(where: { $0.hasPrefix("X-TIMESTAMP-MAP") }),
              let anchor = parseTimestampMap(mapLine) else { return nil }

        var cues: [WebVTTSegment.Cue] = []
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            let line = lines[index]
            guard let arrow = line.range(of: "-->") else { continue }
            let startText = String(line[line.startIndex..<arrow.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // Everything after the second timestamp is cue settings (line:, position:, align: ...),
            // not dialogue.
            let endText = String(line[arrow.upperBound...])
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ").first ?? ""
            guard let start = parseTimestamp(startText), let end = parseTimestamp(endText) else { continue }

            var body: [String] = []
            var cursor = index + 1
            while cursor < lines.count, !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[cursor])
                cursor += 1
            }
            index = cursor
            let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                cues.append(WebVTTSegment.Cue(start: start, end: end, text: joined))
            }
        }
        return WebVTTSegment(anchorLocalSeconds: anchor.local, anchorMPEGTS90k: anchor.mpegts, cues: cues)
    }

    /// Map a segment's cues onto the player clock. `shiftSeconds` is the session's
    /// `playlistShiftSeconds`, the same offset the segment producer applies to the picture, so cues
    /// and frames end up on one axis.
    ///
    /// The duration is carried over rather than mapped a second time: mapping both ends independently
    /// would tear a cue in half across a clock wrap.
    static func cues(from segment: WebVTTSegment, shiftSeconds: Double, nextID: inout Int) -> [SubtitleCue] {
        segment.cues.map { cue in
            let program = Double(segment.anchorMPEGTS90k) / 90_000
                + (cue.start - segment.anchorLocalSeconds)
            let start = wrapSafeDifference(program.truncatingRemainder(dividingBy: mpegtsWrapSeconds),
                                           shiftSeconds)
            let id = nextID
            nextID += 1
            return SubtitleCue(id: id, startTime: start, endTime: start + (cue.end - cue.start),
                               body: .text(cue.text))
        }
    }

    /// Fold a new segment's cues into what is already published: a line whose text is identical and
    /// whose range touches an existing cue extends that cue instead of becoming a second one. Re-feeding
    /// the same segment therefore changes nothing, which is what makes a playlist poll cheap.
    static func merged(into existing: [SubtitleCue], adding: [SubtitleCue],
                       nextID: inout Int) -> [SubtitleCue] {
        var result = existing
        for cue in adding {
            guard case .text(let text) = cue.body else { continue }
            let match = result.firstIndex { candidate in
                guard case .text(let candidateText) = candidate.body, candidateText == text else { return false }
                return cue.startTime <= candidate.endTime + joinTolerance
                    && cue.endTime >= candidate.startTime - joinTolerance
            }
            if let match {
                let old = result[match]
                result[match] = SubtitleCue(id: old.id,
                                            startTime: min(old.startTime, cue.startTime),
                                            endTime: max(old.endTime, cue.endTime),
                                            body: old.body,
                                            placement: old.placement)
            } else {
                result.append(cue)
            }
        }
        return result
    }

    // MARK: - Parsing helpers

    private static func parseTimestampMap(_ line: String) -> (local: Double, mpegts: Int64)? {
        var local: Double?
        var mpegts: Int64?
        // Fields may come in either order: both `LOCAL:...,MPEGTS:...` and the reverse are in the wild.
        for field in line.dropFirst("X-TIMESTAMP-MAP".count).drop(while: { $0 == "=" })
            .components(separatedBy: ",") {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("LOCAL:") {
                local = parseTimestamp(String(trimmed.dropFirst("LOCAL:".count)))
            } else if trimmed.hasPrefix("MPEGTS:") {
                mpegts = Int64(trimmed.dropFirst("MPEGTS:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let local, let mpegts else { return nil }
        return (local, mpegts)
    }

    /// `HH:MM:SS.mmm` or `MM:SS.mmm`; hours are unbounded (providers run the LOCAL clock for days).
    private static func parseTimestamp(_ text: String) -> Double? {
        let parts = text.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let values = parts.compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard values.count == parts.count else { return nil }
        return parts.count == 3
            ? values[0] * 3600 + values[1] * 60 + values[2]
            : values[0] * 60 + values[1]
    }

    /// Difference of two points on a wrapping clock: the shorter way round wins, so a cue just past a
    /// wrap lands a second after the shift instead of a whole period before it.
    private static func wrapSafeDifference(_ program: Double, _ shift: Double) -> Double {
        var delta = program - shift.truncatingRemainder(dividingBy: mpegtsWrapSeconds)
        if delta < -mpegtsWrapSeconds / 2 { delta += mpegtsWrapSeconds }
        if delta > mpegtsWrapSeconds / 2 { delta -= mpegtsWrapSeconds }
        return delta
    }
}
