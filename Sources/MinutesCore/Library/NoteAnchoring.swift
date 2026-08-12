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
/// The rule is deliberately strict: a timecode counts as an anchor only when
/// the transcript has a line at exactly that timecode. A line whose timestamps
/// point nowhere is shown as not being in the transcript rather than being
/// given a link that lands on the wrong words.
public enum NoteAnchoring {

    /// The heading the prompt asks the model to file unanchorable claims under.
    static let unanchoredHeadingMarker = "not anchored"

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
        var byTimecode: [String: Int] = [:]
        for line in transcript where byTimecode[line.timecode] == nil {
            byTimecode[line.timecode] = line.index
        }

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

            let resolved = timecodes.compactMap { code -> NoteAnchor? in
                guard let index = byTimecode[code] else { return nil }
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
