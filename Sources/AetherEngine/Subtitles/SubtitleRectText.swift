import CoreGraphics
import Foundation
import Libavcodec

extension SubtitleTextRun {
    /// Same styling, different text. Keeps the trim and fold passes from restating every attribute.
    func withText(_ newText: String) -> SubtitleTextRun {
        SubtitleTextRun(text: newText, color: color, isBold: isBold, isItalic: isItalic,
                        isUnderlined: isUnderlined, isStruckThrough: isStruckThrough,
                        fontName: fontName, fontSize: fontSize)
    }
}

/// Plain-text extraction from FFmpeg subtitle rects, shared by `SubtitleDecoder` (sidecar) and `EmbeddedSubtitleDecoder` (in-container) so ASS parsing fixes live in one place.
enum SubtitleRectText {

    /// Plain text for a rect: prefers `text` field, falls back to parsing the raw ASS `Dialogue:` line (strip 8 header fields, clean tags + escapes).
    static func plainText(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        if let textPtr = rect.pointee.text {
            let s = String(cString: textPtr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let assPtr = rect.pointee.ass {
            return plainText(fromASSEventLine: String(cString: assPtr))
        }
        return nil
    }

    /// Plain text from a raw ASS event line (`ReadOrder,Layer,Style,...,Text`), for surfaces that need
    /// plain text out of markup-preserving cues (the WebVTT rendition over tap-harvested stores,
    /// Sodalite#32). Guarded on the first field being the integer ReadOrder so a plain, comma-heavy
    /// line is never misparsed as an event; non-event lines just get tag/escape cleaning.
    static func plainText(fromASSEventLine line: String) -> String? {
        var l = line
        if l.hasPrefix("Dialogue: ") {
            l.removeFirst("Dialogue: ".count)
        }
        // ASS dialogue: 9 comma-separated fields; body is the 9th and may contain commas.
        let parts = l.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        if parts.count == 9, Int(parts[0]) != nil {
            return cleanASSBody(String(parts[8]))
        }
        return cleanASSBody(l)
    }

    /// Raw ASS event line exactly as libavcodec hands it over (`ReadOrder,Layer,Style,...,Text`, tags + escapes intact), for the `preserveASSMarkup` path; nil when the rect carries no ASS payload (bitmap or plain-text-only rects).
    static func rawASSLine(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        guard let assPtr = rect.pointee.ass else { return nil }
        let line = String(cString: assPtr)
        return line.isEmpty ? nil : line
    }

    /// Strip ASS escapes (`\\N` newline, `\\h` hard space) and
    /// `{...}` override tags; nil when nothing displayable remains.
    static func cleanASSBody(_ raw: String) -> String? {
        var s = raw
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        s = s.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Default ASS play resolution (`ASS_DEFAULT_PLAYRESX/Y`, libavcodec/ass.h). Every event line
    /// libavcodec synthesises for SRT, WebVTT and teletext positions against this space, so it is
    /// the right frame of reference unless a real ASS header declares its own.
    static let defaultASSPlayRes = CGSize(width: 384, height: 288)

    /// Play resolution declared by an ASS `[Script Info]` header, or nil when it declares none.
    static func playRes(fromASSHeader header: String) -> CGSize? {
        func value(_ key: String) -> Double? {
            for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.lowercased().hasPrefix(key.lowercased() + ":") else { continue }
                return Double(l.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        guard let x = value("PlayResX"), let y = value("PlayResY"), x > 0, y > 0 else { return nil }
        return CGSize(width: x, height: y)
    }

    /// Accumulated inline ASS override state while walking an event line.
    private struct RunStyle: Equatable {
        var color: SubtitleColor?
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isStruckThrough = false
        var fontName: String?
        var fontSize: Int?

        func run(_ text: String) -> SubtitleTextRun {
            SubtitleTextRun(text: text, color: color, isBold: isBold, isItalic: isItalic,
                            isUnderlined: isUnderlined, isStruckThrough: isStruckThrough,
                            fontName: fontName, fontSize: fontSize)
        }
    }

    /// Parse an ASS event line's Text body into styled runs plus the cue-level placement it asks
    /// for (#233). Every text subtitle format reaches the engine through libavcodec as one of these
    /// lines, so this single parser serves SRT (`ff_htmlmarkup_to_ass`), WebVTT, dvb_teletext
    /// (`txt_format=ass`) and ASS itself.
    ///
    /// Inline state comes from `\c`/`\1c` (BGR; a bare tag or unparseable value resets to the page
    /// default), `\b`, `\i`, `\u`, `\s`, `\fn`, `\fs` and `\r`. Cue-level `\an` and `\pos` are
    /// lifted out into the placement, with `\pos` normalized against `playRes`. Applies `\N`/`\n`
    /// -> newline and `\h` -> space. Tags that merely look like these (`\be`, `\bord`, `\iclip`,
    /// `\shad`, `\fscx`, `\fsp`) are left alone. Adjacent runs of equal styling are collapsed.
    /// nil when nothing displayable remains.
    static func styledRuns(fromASSEventLine line: String,
                           playRes: CGSize = SubtitleRectText.defaultASSPlayRes)
        -> (runs: [SubtitleTextRun], placement: SubtitleTextPlacement?)? {
        var body = line
        if body.hasPrefix("Dialogue: ") { body.removeFirst("Dialogue: ".count) }
        let parts = body.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let text: String = (parts.count == 9 && Int(parts[0]) != nil) ? String(parts[8]) : body

        var pieces: [(style: RunStyle, text: String)] = []
        var current = ""
        var style = RunStyle()
        var alignment: Int?
        var position: CGPoint?

        func flush() {
            guard !current.isEmpty else { return }
            if let last = pieces.indices.last, pieces[last].style == style {
                pieces[last].text += current
            } else {
                pieces.append((style, current))
            }
            current = ""
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "N" || n == "n" { current += "\n"; i += 2; continue }
                if n == "h" { current += " "; i += 2; continue }
            }
            if c == "{" {
                var j = i + 1
                var block = ""
                while j < chars.count, chars[j] != "}" { block.append(chars[j]); j += 1 }
                var next = style
                applyOverrides(block, to: &next, alignment: &alignment,
                               position: &position, playRes: playRes)
                // The text collected so far belongs to the style in force before this block.
                if next != style { flush(); style = next }
                i = (j < chars.count) ? j + 1 : j
                continue
            }
            current.append(c)
            i += 1
        }
        flush()

        var runs = pieces.map { $0.style.run($0.text) }
        let placement = (alignment == nil && position == nil)
            ? nil : SubtitleTextPlacement(alignment: alignment, position: position)
        guard let trimmed = edgeTrimmed(runs) else { return nil }
        runs = trimmed
        return (runs, placement)
    }

    /// Apply one override block's tags. Inline attributes mutate `style`; `\an` and `\pos` are
    /// cue-level and are lifted out instead, so they never split a run.
    private static func applyOverrides(_ block: String, to style: inout RunStyle,
                                       alignment: inout Int?, position: inout CGPoint?,
                                       playRes: CGSize) {
        for tag in block.split(separator: "\\").map(String.init) {
            if tag == "r" || (tag.hasPrefix("r") && !tag.hasPrefix("rnd")) {
                style = RunStyle()
            } else if let color = parseColorTag("\\" + tag) {
                style.color = color   // nil means reset
            } else if let v = intValue(tag, after: "b") {
                style.isBold = v != 0
            } else if let v = intValue(tag, after: "i") {
                style.isItalic = v != 0
            } else if let v = intValue(tag, after: "u") {
                style.isUnderlined = v != 0
            } else if let v = intValue(tag, after: "s") {
                style.isStruckThrough = v != 0
            } else if let v = intValue(tag, after: "an"), (1...9).contains(v) {
                alignment = v
            } else if tag.hasPrefix("fn") {
                let name = String(tag.dropFirst(2))
                style.fontName = name.isEmpty ? nil : name
            } else if tag.hasPrefix("fs"), tag.dropFirst(2).allSatisfy(\.isNumber) {
                style.fontSize = Int(tag.dropFirst(2))
            } else if let p = parsePositionTag(tag, playRes: playRes) {
                position = p
            }
        }
    }

    /// `tag` as `prefix` followed by digits and nothing else, so `\b1` parses while `\bord2`,
    /// `\be1`, `\iclip(...)` and `\shad2` do not.
    private static func intValue(_ tag: String, after prefix: String) -> Int? {
        guard tag.hasPrefix(prefix) else { return nil }
        let rest = tag.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    /// `pos(x,y)` normalized against the play resolution, the same [0, 1] convention
    /// `SubtitleImage.position` uses.
    private static func parsePositionTag(_ tag: String, playRes: CGSize) -> CGPoint? {
        guard tag.hasPrefix("pos("), tag.hasSuffix(")"),
              playRes.width > 0, playRes.height > 0 else { return nil }
        let inner = tag.dropFirst(4).dropLast()
        let parts = inner.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return CGPoint(x: x / playRes.width, y: y / playRes.height)
    }

    /// Trim whitespace and newlines across the edges of a run sequence, so a styled cue matches
    /// what the plain path produces. libzvbi teletext ass can prefix a row-positioning newline that
    /// would otherwise render as a blank line ONLY on styled cues (#107). Interior blank lines are
    /// NOT folded here: that is teletext-specific and lives in `teletextBody`.
    private static func edgeTrimmed(_ runs: [SubtitleTextRun]) -> [SubtitleTextRun]? {
        var cleaned = runs.filter { !$0.text.isEmpty }
        // Edge-trim leading/trailing whitespace and newlines across the run sequence so a coloured
        // cue matches the plain path (teletextBody flattens + trims the .text case). libzvbi
        // teletext ass can prefix a row-positioning newline that would otherwise render as a blank
        // line ONLY on coloured cues (#107). Interior blank lines are folded separately below;
        // single line breaks and colours are preserved.
        while let first = cleaned.first {
            let d = String(first.text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
            if d.isEmpty { cleaned.removeFirst(); continue }
            cleaned[0] = first.withText(d)
            break
        }
        while let last = cleaned.last {
            var s = last.text
            while let c = s.last, c == " " || c == "\t" || c == "\n" { s.removeLast() }
            if s.isEmpty { cleaned.removeLast(); continue }
            cleaned[cleaned.count - 1] = last.withText(s)
            break
        }
        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    /// Collapse interior blank lines across a run sequence (#107). libzvbi joins teletext rows with
    /// `\N`, so a caption whose lines sit on non-adjacent rows (an empty row between them, used only
    /// for vertical placement) arrives as `line1\n\nline2` and would render a blank line the
    /// broadcaster never intended. Consecutive newlines (optionally separated by horizontal
    /// whitespace) fold to one; single line breaks and colours are preserved. The empty row lands
    /// inside a single run in practice, but a colour change at a row boundary could split it, so the
    /// boundary between adjacent runs is folded too.
    private static func collapseInteriorBlankLines(_ runs: [SubtitleTextRun]) -> [SubtitleTextRun] {
        var folded = runs.map { run in
            run.withText(run.text.replacingOccurrences(
                of: #"\n(?:[ \t]*\n)+"#, with: "\n", options: .regularExpression))
        }
        var i = 0
        while i < folded.count - 1 {
            if folded[i].text.hasSuffix("\n") {
                var next = folded[i + 1].text
                while next.hasPrefix("\n") { next.removeFirst() }
                folded[i + 1] = folded[i + 1].withText(next)
            }
            i += 1
        }
        return folded.filter { !$0.text.isEmpty }
    }

    /// Body + placement for any text rect's ASS event line (#233): `.richText` when a run asks for
    /// styling, `.text` (flattened) when none does, nil when empty. An unstyled track therefore
    /// keeps the exact body it produced before, so a host handling only `.text` sees no change.
    static func styledBody(fromASSEventLine line: String,
                           playRes: CGSize = SubtitleRectText.defaultASSPlayRes)
        -> (body: SubtitleCue.Body, placement: SubtitleTextPlacement?)? {
        guard let parsed = styledRuns(fromASSEventLine: line, playRes: playRes) else { return nil }
        return body(for: parsed.runs).map { ($0, parsed.placement) }
    }

    /// Teletext variant (#107): identical, plus the interior blank-line fold libzvbi's row joining
    /// requires. That fold is deliberately teletext-only, since a blank line in an ASS or SRT cue
    /// can be intentional.
    static func teletextBody(fromASSEventLine line: String,
                             playRes: CGSize = SubtitleRectText.defaultASSPlayRes)
        -> (body: SubtitleCue.Body, placement: SubtitleTextPlacement?)? {
        guard let parsed = styledRuns(fromASSEventLine: line, playRes: playRes) else { return nil }
        return body(for: collapseInteriorBlankLines(parsed.runs)).map { ($0, parsed.placement) }
    }

    private static func body(for runs: [SubtitleTextRun]) -> SubtitleCue.Body? {
        if runs.contains(where: \.isStyled) { return .richText(runs) }
        let plain = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : .text(plain)
    }

    /// Parse a `\c`/`\1c` colour override tag body. Returns `.some(nil)` for a reset (bare tag or bad
    /// value), `.some(color)` for a parsed BGR value, and `nil` when the tag is not a colour tag.
    ///
    /// Deviates from the task brief's `-> (value: SubtitleColor?)?` signature: Swift rejects a
    /// single-element labeled tuple as a type ("cannot create a single-element tuple with an element
    /// label"), so this uses the semantically identical `SubtitleColor??` (double optional) instead.
    /// Behaviour (three-way nil / reset / color) is unchanged.
    private static func parseColorTag(_ tag: String) -> SubtitleColor?? {
        // Accept a block that contains \c or \1c (teletext libzvbi emits one tag per block).
        guard let range = tag.range(of: #"\\1?c(?![a-zA-Z])"#, options: .regularExpression) else { return nil }
        let after = tag[range.upperBound...]
        guard let hexRange = after.range(of: #"&H[0-9A-Fa-f]{1,6}&"#, options: .regularExpression) else {
            return .some(nil)   // bare \c => reset
        }
        let hex = after[hexRange].dropFirst(2).dropLast()   // strip &H .. &
        guard let bgr = UInt32(hex, radix: 16) else { return .some(nil) }
        let b = UInt8((bgr >> 16) & 0xFF)
        let g = UInt8((bgr >> 8) & 0xFF)
        let r = UInt8(bgr & 0xFF)
        return .some(SubtitleColor(r: r, g: g, b: b))
    }
}
