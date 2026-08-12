import Foundation

/// A piece of a meeting with the match in the middle, so the row can show why
/// it matched instead of only that it did.
public struct SearchSnippet: Sendable, Equatable {
    public let before: String
    public let match: String
    public let after: String

    public init(before: String, match: String, after: String) {
        self.before = before
        self.match = match
        self.after = after
    }

    public var text: String { before + match + after }
}

public struct MeetingSearchHit: Sendable, Equatable, Identifiable {
    public let meeting: MeetingSummary
    /// Nil when only the title matched: the title is already on the row.
    public let snippet: SearchSnippet?

    public init(meeting: MeetingSummary, snippet: SearchSnippet?) {
        self.meeting = meeting
        self.snippet = snippet
    }

    public var id: String { meeting.id }
}

public enum MeetingSearch {

    /// Case insensitive, plain substring. No index and no query language: the
    /// folder is a few hundred meetings of Markdown and the owner is looking
    /// for a word they remember.
    public static func snippet(for query: String, in haystack: String, window: Int = 44) -> SearchSnippet? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }

        let flattened = flatten(haystack)
        guard let range = flattened.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        let start = flattened.index(range.lowerBound, offsetBy: -window, limitedBy: flattened.startIndex)
        let end = flattened.index(range.upperBound, offsetBy: window, limitedBy: flattened.endIndex)

        var before = String(flattened[(start ?? flattened.startIndex)..<range.lowerBound])
        var after = String(flattened[range.upperBound..<(end ?? flattened.endIndex)])
        if start != nil { before = "..." + before }
        if end != nil { after += "..." }

        return SearchSnippet(before: before, match: String(flattened[range]), after: after)
    }

    public static func matches(_ query: String, _ haystack: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// One line, no Markdown scaffolding, so a snippet reads like speech.
    static func flatten(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "#", with: "")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
