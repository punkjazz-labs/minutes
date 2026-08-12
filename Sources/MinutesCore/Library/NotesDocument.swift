import Foundation

/// Where a meeting stands, in the three words the library shows.
public enum NotesState: String, Sendable, Equatable, CaseIterable {
    /// The model answered and the notes are on disk.
    case written
    /// The transcript is on disk and the endpoint did not answer.
    case pending
    /// A transcript with no notes file beside it at all.
    case transcriptOnly

    public var label: String {
        switch self {
        case .written: return "Written"
        case .pending: return "Waiting for Spark"
        case .transcriptOnly: return "Transcript only"
        }
    }
}

/// `notes.md` read back into its parts: the front matter that names what wrote
/// it, the owner's own words, and the model's.
public struct NotesDocument: Sendable, Equatable {

    public var frontMatter: [String: String]
    public var ownerText: String
    public var modelText: String
    public var pendingReason: String?

    public init(
        frontMatter: [String: String] = [:],
        ownerText: String = "",
        modelText: String = "",
        pendingReason: String? = nil
    ) {
        self.frontMatter = frontMatter
        self.ownerText = ownerText
        self.modelText = modelText
        self.pendingReason = pendingReason
    }

    public var state: NotesState {
        if frontMatter["notes_state"] == "written" { return .written }
        if frontMatter["notes_state"] == "pending" { return .pending }
        return modelText.isEmpty ? .pending : .written
    }

    public static func parse(_ markdown: String) -> NotesDocument {
        var document = NotesDocument()
        var body = Substring(markdown)

        if markdown.hasPrefix("---\n") {
            let afterOpen = markdown.index(markdown.startIndex, offsetBy: 4)
            if let closeRange = markdown.range(of: "\n---\n", range: afterOpen..<markdown.endIndex) {
                document.frontMatter = parseFrontMatter(String(markdown[afterOpen..<closeRange.lowerBound]))
                body = markdown[closeRange.upperBound...]
            }
        }

        var current: String?
        var buckets: [String: [String]] = [:]
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            switch line {
            case NotesSection.owner, NotesSection.model, NotesSection.pending:
                current = line
            default:
                if let current { buckets[current, default: []].append(line) }
            }
        }

        func text(_ heading: String) -> String {
            (buckets[heading] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        document.ownerText = text(NotesSection.owner)
        document.modelText = text(NotesSection.model)
        let waiting = text(NotesSection.pending)
        document.pendingReason = waiting.isEmpty ? nil : waiting
        return document
    }

    public static func parse(at url: URL) -> NotesDocument? {
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(markdown)
    }

    /// Front matter is written by this app alone, one `key: value` per line,
    /// so it is read the same narrow way rather than with a YAML parser.
    private static func parseFrontMatter(_ text: String) -> [String: String] {
        var found: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            found[key] = value
        }
        return found
    }
}
