import Foundation

/// A timestamp the model put in a note line, resolved against the transcript.
public struct NoteAnchor: Sendable, Equatable, Identifiable {
    /// The timecode as the model wrote it, `HH:MM:SS`.
    public let timecode: String
    /// The transcript line it points at, or nil when the transcript has no
    /// such line.
    public let lineIndex: Int?

    public init(timecode: String, lineIndex: Int?) {
        self.timecode = timecode
        self.lineIndex = lineIndex
    }

    public var id: String { timecode }
    public var isResolved: Bool { lineIndex != nil }
    public var label: String { Timecode.short(timecode) }
}

/// One line of the model's notes, with its timestamps turned into links.
public struct AnchoredLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case heading(level: Int)
        case bullet
        case paragraph
    }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let anchors: [NoteAnchor]

    public init(id: Int, kind: Kind, text: String, anchors: [NoteAnchor]) {
        self.id = id
        self.kind = kind
        self.text = text
        self.anchors = anchors
    }
}

/// The model's notes split into what the transcript backs and what it does not.
public struct AnchoredNotes: Sendable, Equatable {
    public let lines: [AnchoredLine]
    /// Lines the transcript does not back: a timestamp that is not in the
    /// transcript, or a line the model itself filed as unanchored.
    public let unanchored: [String]

    public init(lines: [AnchoredLine], unanchored: [String]) {
        self.lines = lines
        self.unanchored = unanchored
    }

    public var isEmpty: Bool { lines.isEmpty && unanchored.isEmpty }
}

/// Turns the timestamps the model already writes into real links.
///
/// The rule is deliberately strict, and it is one rule and not two: a chip is
/// never given a link that lands on the wrong words. A timecode the transcript
/// does not hold points nowhere. A timecode the transcript holds twice, which
/// is what two people talking in the same second produce, points at the line
/// whose words the note actually quotes, and at nothing at all when the words
/// cannot say which line was meant. Both cases end in the box that says the
/// line is not in the transcript.
public enum NoteAnchoring {

    /// The heading the prompt asks the model to file unanchorable claims under.
    static let unanchoredHeadingMarker = "not anchored"

    /// Every transcript line, grouped by the second it starts in.
    ///
    /// Timecodes are whole seconds and a meeting has two tracks, so two people
    /// who speak in the same second give two lines with one timecode between
    /// them. This is ordinary in a two-sided meeting, not rare.
    public static func linesByTimecode(_ transcript: [TranscriptLine]) -> [String: [TranscriptLine]] {
        var found: [String: [TranscriptLine]] = [:]
        for line in transcript { found[line.timecode, default: []].append(line) }
        return found
    }

    /// The transcript line a timecode points at, decided by the words written
    /// around it.
    ///
    /// One line at that second is the answer. Several lines are decided by how
    /// many words each one shares with the quoted text, and a draw is decided
    /// by nothing: no chip is the right answer when the transcript cannot say
    /// which line was meant. Taking the first line instead lands the chip on
    /// the other speaker about half the time, and shows their words as the
    /// evidence for a claim about what the owner said.
    public static func lineIndex(
        for timecode: String,
        quoting text: String,
        in linesByTimecode: [String: [TranscriptLine]]
    ) -> Int? {
        guard let lines = linesByTimecode[timecode], !lines.isEmpty else { return nil }
        if lines.count == 1 { return lines[0].index }

        let quoted = words(in: text)
        var best: (index: Int, score: Int)?
        var drawn = false
        for line in lines {
            let score = words(in: line.text).intersection(quoted).count
            guard let current = best else {
                best = (line.index, score)
                continue
            }
            if score > current.score {
                best = (line.index, score)
                drawn = false
            } else if score == current.score {
                drawn = true
            }
        }

        guard let best, best.score > 0, !drawn else { return nil }
        return best.index
    }

    /// The words that decide where a timestamp inside prose points.
    ///
    /// An answer is a paragraph, so the words that matter are the ones in the
    /// same sentence as the timestamp. A timestamp written after the full stop
    /// would leave that sentence empty, so sentences are taken backwards until
    /// there is something to compare.
    public static func context(around index: String.Index, in text: String) -> String {
        var end = index
        while end < text.endIndex, !NoteAnchoring.isSentenceEnd(text[end]) {
            end = text.index(after: end)
        }

        var starts: [String.Index] = [text.startIndex]
        var cursor = text.startIndex
        while cursor < index {
            if NoteAnchoring.isSentenceEnd(text[cursor]) { starts.append(text.index(after: cursor)) }
            cursor = text.index(after: cursor)
        }

        for start in starts.reversed() where start <= end {
            let window = String(text[start..<end])
            if words(in: window).count >= 3 { return window }
        }
        return String(text[text.startIndex..<end])
    }

    private static func isSentenceEnd(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character == "\n"
    }

    /// The words a note and a transcript line have in common are what decide an
    /// anchor, so both sides are reduced the same simple way: lower case,
    /// letters and digits only, nothing shorter than three characters, and
    /// nothing from the list below.
    static func words(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && !everySentenceHasThese.contains($0) })
    }

    /// The words that every sentence in a meeting has. Sharing one of them says
    /// nothing about which line a note was written from, and letting one of them
    /// break a draw is how a chip lands on the other speaker.
    private static let everySentenceHasThese: Set<String> = [
        "the", "and", "for", "but", "not", "you", "was", "are", "our", "its", "his", "her",
        "that", "this", "with", "from", "they", "them", "then", "than", "have", "has", "had",
        "will", "would", "should", "could", "there", "their", "what", "when", "were", "been",
        "about", "which", "into", "also", "some", "any", "all", "who", "how", "why", "she",
    ]

    public static func timecodes(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            let candidate = String(rest[rest.index(after: open)..<close])
            if Timecode.seconds(from: candidate) != nil { found.append(candidate) }
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    public static func anchor(_ markdown: String, to transcript: [TranscriptLine]) -> AnchoredNotes {
        let candidates = linesByTimecode(transcript)

        var lines: [AnchoredLine] = []
        var unanchored: [String] = []
        var inUnanchoredSection = false
        var nextID = 0

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let heading = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                inUnanchoredSection = heading.lowercased().contains(unanchoredHeadingMarker)
                if inUnanchoredSection { continue }
                lines.append(AnchoredLine(id: nextID, kind: .heading(level: level), text: heading, anchors: []))
                nextID += 1
                continue
            }

            let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            let stripped = isBullet ? String(line.dropFirst(2)) : line
            let timecodes = self.timecodes(in: stripped)
            let text = clean(stripped)
            if text.isEmpty { continue }

            if inUnanchoredSection {
                unanchored.append(text)
                continue
            }

            // The line the model wrote is the quoted text, so it is also what
            // decides which transcript line the timestamp points at.
            let resolved = timecodes.compactMap { code -> NoteAnchor? in
                guard let index = lineIndex(for: code, quoting: text, in: candidates) else { return nil }
                return NoteAnchor(timecode: code, lineIndex: index)
            }

            if !timecodes.isEmpty && resolved.isEmpty {
                unanchored.append(text)
                continue
            }

            lines.append(
                AnchoredLine(id: nextID, kind: isBullet ? .bullet : .paragraph, text: text, anchors: resolved))
            nextID += 1
        }

        return AnchoredNotes(lines: lines, unanchored: unanchored)
    }

    /// The line without its timestamps and without Markdown emphasis markers,
    /// because the chip carries the timestamp and the pane is not a renderer.
    private static func clean(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            if let close = rest[open...].firstIndex(of: "]"),
                Timecode.seconds(from: String(rest[rest.index(after: open)..<close])) != nil
            {
                out += rest[..<open]
                rest = rest[rest.index(after: close)...]
            } else {
                out += rest[...open]
                rest = rest[rest.index(after: open)...]
            }
        }
        out += rest
        out = out.replacingOccurrences(of: "**", with: "")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
