import Foundation

/// Everything a meeting holds, read from its directory in one go.
public struct MeetingRecord: Sendable {
    public let summary: MeetingSummary
    public let notes: NotesDocument?
    public let transcript: [TranscriptLine]
    /// The owner's own words, from `bullets.md` when it is there and from the
    /// notes file when the meeting predates it.
    public let bullets: String

    public init(summary: MeetingSummary, notes: NotesDocument?, transcript: [TranscriptLine], bullets: String) {
        self.summary = summary
        self.notes = notes
        self.transcript = transcript
        self.bullets = bullets
    }

    public var transcriptText: String { TranscriptFile.plainText(transcript) }

    public var anchoredNotes: AnchoredNotes {
        NoteAnchoring.anchor(notes?.modelText ?? "", to: transcript)
    }

    /// The lines the owner typed, one per line, shown as their own.
    public var ownerLines: [String] {
        bullets
            .split(separator: "\n")
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("- ") || text.hasPrefix("* ") { text = String(text.dropFirst(2)) }
                return text
            }
            .filter { !$0.isEmpty }
    }
}

public enum LibraryError: Error, LocalizedError {
    case notAMeeting(String)
    case noTranscript(String)

    public var errorDescription: String? {
        switch self {
        case .notAMeeting(let name): return "\(name) is not a meeting folder."
        case .noTranscript(let title): return "\(title) has no transcript, so there is nothing to write notes from."
        }
    }
}

/// The meetings on disk, as the library window sees them.
public struct MeetingLibrary: Sendable {

    public let root: URL
    private var fileManager: FileManager { .default }

    public init(root: URL) {
        self.root = root
    }

    public init(settings: AppSettings) {
        self.init(root: settings.notesFolderURL)
    }

    public var store: MeetingStore { MeetingStore(root: root) }
    public var syncService: String? { SyncFolderDetector.service(for: root) }

    /// The folder as the owner wrote it, with the home directory abbreviated.
    public var folderText: String {
        (root.path as NSString).abbreviatingWithTildeInPath
    }

    public func meetings() throws -> [MeetingSummary] {
        try store.meetings()
            .compactMap(MeetingSummary.read)
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func record(for meeting: MeetingSummary) -> MeetingRecord {
        let notes = NotesDocument.parse(at: meeting.directory.notesURL)
        return MeetingRecord(
            summary: meeting,
            notes: notes,
            transcript: TranscriptFile.lines(at: meeting.directory.transcriptURL),
            bullets: store.readBullets(in: meeting.directory) ?? notes?.ownerText ?? "")
    }

    // MARK: - Search

    /// Titles, notes and transcripts. A title match is a hit on its own; a body
    /// match brings back the words around it.
    public func search(_ query: String) throws -> [MeetingSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try meetings()
        guard !needle.isEmpty else { return all.map { MeetingSearchHit(meeting: $0, snippet: nil) } }

        return all.compactMap { meeting in
            // What was said and what was written, not the front matter and the
            // provenance lines around them, so a snippet is always words from
            // the meeting.
            let spoken = TranscriptFile.plainText(TranscriptFile.lines(at: meeting.directory.transcriptURL))
            let document = NotesDocument.parse(at: meeting.directory.notesURL)
            let written = [document?.ownerText, document?.modelText].compactMap { $0 }.joined(separator: "\n")

            let snippet =
                MeetingSearch.snippet(for: needle, in: spoken)
                ?? MeetingSearch.snippet(for: needle, in: written)
            if snippet != nil { return MeetingSearchHit(meeting: meeting, snippet: snippet) }
            if MeetingSearch.matches(needle, meeting.title) {
                return MeetingSearchHit(meeting: meeting, snippet: nil)
            }
            return nil
        }
    }

    // MARK: - Rename and delete

    /// Renames the directory and the title inside `meta.json`. The notes and
    /// the transcript are not rewritten: a rename must never be able to lose
    /// what was said.
    @discardableResult
    public func rename(_ meeting: MeetingSummary, to newTitle: String) throws -> MeetingSummary {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return meeting }
        try guardInsideRoot(meeting.directory.url)

        // The same directory reached two ways is one directory. A notes folder
        // picked through a symlink gives a listed URL and a built URL that
        // never compare equal, and a rename to a name that slugs the same then
        // moves the meeting to a spare -2 directory.
        let current = meeting.directory.url.resolvingSymlinksInPath().standardizedFileURL
        func isTheSameDirectory(_ url: URL) -> Bool {
            url.resolvingSymlinksInPath().standardizedFileURL == current
        }

        let wanted = MeetingSlug.directoryName(title: trimmed, date: meeting.startedAt)
        var name = wanted
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path), !isTheSameDirectory(candidate) {
            name = "\(wanted)-\(suffix)"
            candidate = root.appendingPathComponent(name, isDirectory: true)
            suffix += 1
        }

        if !isTheSameDirectory(candidate) {
            try fileManager.moveItem(at: meeting.directory.url, to: candidate)
        }

        let moved = MeetingDirectory(url: candidate)
        if var meta = try? store.readMeta(in: moved) {
            meta.title = trimmed
            try? store.writeMeta(meta, to: moved)
        } else {
            // A meeting written by an older version, or one whose pipeline
            // stopped before meta.json, has no file that records a title. The
            // front matter of notes.md still holds the old one, so without this
            // the owner watches the title change and then change back, and the
            // directory on disk stops matching the title on screen.
            try? store.writeMeta(minimalMeta(for: meeting, in: moved, title: trimmed), to: moved)
        }

        return MeetingSummary(
            directory: moved,
            title: trimmed,
            startedAt: meeting.startedAt,
            duration: meeting.duration,
            notesState: meeting.notesState,
            tracksRecorded: meeting.tracksRecorded)
    }

    /// The smallest honest `meta.json` for a meeting that has none: the title
    /// the owner just gave it, and everything the meeting can still say about
    /// itself. Nothing is invented.
    ///
    /// The provenance is copied out of the front matter of `notes.md`, which is
    /// where a meeting written before `meta.json` existed keeps it. Writing a
    /// `meta.json` with empty fields does not merely fail to add anything: it
    /// shadows that front matter for every reader that prefers `meta.json`, so
    /// the next re-run writes the engine and the model back as empty strings
    /// and the provenance is gone.
    private func minimalMeta(
        for meeting: MeetingSummary,
        in directory: MeetingDirectory,
        title: String
    ) -> MeetingMeta {
        let front = NotesDocument.parse(at: directory.notesURL)?.frontMatter ?? [:]
        return MeetingMeta(
            title: title,
            startedAt: meeting.startedAt,
            durationSeconds: meeting.duration,
            transcriptionEngine: front["transcription_engine"] ?? "",
            transcriptionModel: front["transcription_model"] ?? "",
            notesEndpoint: front["notes_endpoint"],
            notesModel: front["notes_model"],
            notesState: meeting.notesState == .written ? "written" : "pending",
            tracksRecorded: meeting.tracksRecorded,
            tracksMissing: [],
            audioKept: false)
    }

    /// The whole directory, audio included.
    public func delete(_ meeting: MeetingSummary) throws {
        try guardInsideRoot(meeting.directory.url)
        try fileManager.removeItem(at: meeting.directory.url)
    }

    // MARK: - Writing the notes again

    /// Asks the endpoint for the notes again, from the same two inputs.
    ///
    /// `bullets.md` is read and never written, and `notes.md` is replaced only
    /// once the endpoint has answered, so a failed re-run costs nothing.
    @discardableResult
    public func rewriteNotes(
        for meeting: MeetingSummary,
        using generator: any NotesGenerating,
        endpoint: String,
        model: String
    ) async throws -> MeetingSummary {
        let current = record(for: meeting)
        guard !current.transcript.isEmpty else { throw LibraryError.noTranscript(meeting.title) }

        let result = try await generator.enhance(
            NotesRequest(title: meeting.title, ownerNotes: current.bullets, transcript: current.transcriptText))

        let meta = try? store.readMeta(in: meeting.directory)

        // An empty field in `meta.json` is not an answer, it is the absence of
        // one, so it must not shadow the front matter of `notes.md`. A re-run
        // rewrites that front matter, so preferring the empty field would erase
        // the last record of what transcribed this meeting.
        func provenance(_ recorded: String?, _ frontMatterKey: String) -> String {
            if let recorded, !recorded.isEmpty { return recorded }
            return current.notes?.frontMatter[frontMatterKey] ?? ""
        }
        let engine = provenance(meta?.transcriptionEngine, "transcription_engine")
        let engineModel = provenance(meta?.transcriptionModel, "transcription_model")

        try store.writeNotes(
            title: meeting.title,
            date: meeting.startedAt,
            duration: meeting.duration,
            ownerNotes: current.bullets,
            body: result.markdown,
            pendingReason: nil,
            transcriptionEngine: engine,
            transcriptionModel: engineModel,
            notesEndpoint: endpoint,
            notesModel: model,
            to: meeting.directory)

        if var meta {
            meta.notesState = "written"
            meta.notesEndpoint = endpoint
            meta.notesModel = model
            // The record heals itself, so the next reader does not have to fall
            // back at all.
            meta.transcriptionEngine = engine
            meta.transcriptionModel = engineModel
            try? store.writeMeta(meta, to: meeting.directory)
        }

        return MeetingSummary(
            directory: meeting.directory,
            title: meeting.title,
            startedAt: meeting.startedAt,
            duration: meeting.duration,
            notesState: .written,
            tracksRecorded: meeting.tracksRecorded)
    }

    /// Nothing outside the notes folder is ever moved or removed. Paths are
    /// resolved first, because the same folder can be named two ways.
    private func guardInsideRoot(_ url: URL) throws {
        let parent = url.resolvingSymlinksInPath().deletingLastPathComponent().path
        guard parent == root.resolvingSymlinksInPath().path else {
            throw LibraryError.notAMeeting(url.lastPathComponent)
        }
    }
}
