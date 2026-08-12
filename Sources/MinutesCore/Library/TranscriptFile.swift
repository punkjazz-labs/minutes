import Foundation

/// One spoken line as it can be shown on screen and jumped to.
public struct TranscriptLine: Sendable, Equatable, Identifiable {
    public let index: Int
    public let timecode: String
    public let speaker: String
    public let text: String

    public init(index: Int, timecode: String, speaker: String, text: String) {
        self.index = index
        self.timecode = timecode
        self.speaker = speaker
        self.text = text
    }

    public var id: Int { index }

    /// True for the owner's own track. Everything else is the other side.
    public var isOwner: Bool { speaker == AudioTrack.me.label }
}

/// Reads `transcript.md` back into lines.
///
/// The file is the source of truth once a meeting is written, so the library
/// and the detail window parse the file rather than keeping a second copy of
/// the meeting in memory.
public enum TranscriptFile {

    public static func lines(markdown: String) -> [TranscriptLine] {
        var found: [TranscriptLine] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let timecode = String(line[line.index(after: line.startIndex)..<close])
            guard Timecode.seconds(from: timecode) != nil else { continue }

            var rest = line[line.index(after: close)...]
            while rest.first == " " { rest = rest.dropFirst() }
            guard let colon = rest.firstIndex(of: ":") else { continue }

            let speaker = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
            let text = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !speaker.isEmpty, !text.isEmpty else { continue }

            found.append(TranscriptLine(index: found.count, timecode: timecode, speaker: speaker, text: text))
        }
        return found
    }

    public static func lines(at url: URL) -> [TranscriptLine] {
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return lines(markdown: markdown)
    }

    /// The timestamped lines only, in the shape the model is given.
    public static func plainText(_ lines: [TranscriptLine]) -> String {
        lines.map { "[\($0.timecode)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}
