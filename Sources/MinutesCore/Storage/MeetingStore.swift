import Foundation

/// Where one meeting lives on disk. Plain files, one directory per meeting, so
/// the owner can read them without this app and can leave whenever they like.
///
///     2026-08-04-1400-pricing-call/
///       notes.md
///       transcript.md
///       audio/mic.wav
///       meta.json
public struct MeetingDirectory: Sendable, Equatable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var audioDirectory: URL { url.appendingPathComponent("audio", isDirectory: true) }
    public var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    public var notesURL: URL { url.appendingPathComponent("notes.md") }
    public var metaURL: URL { url.appendingPathComponent("meta.json") }
    /// What the owner typed, in its own file. Notes can be written again; this
    /// file is only ever read after the meeting ends.
    public var bulletsURL: URL { url.appendingPathComponent("bullets.md") }

    public func audioURL(for track: AudioTrack) -> URL {
        audioDirectory.appendingPathComponent(track.fileName)
    }
}

/// What ran where, written next to the meeting so nothing about provenance
/// has to be remembered.
public struct MeetingMeta: Codable, Sendable, Equatable {
    public var title: String
    public var startedAt: Date
    public var durationSeconds: Double
    public var appVersion: String
    public var transcriptionEngine: String
    public var transcriptionModel: String
    public var transcriptionRanOn: String
    public var transcriptionRealtimeFactor: Double?
    public var notesEndpoint: String?
    public var notesModel: String?
    public var notesState: String
    public var tracksRecorded: [String]
    public var tracksMissing: [String]
    /// Tracks that ran but carried nothing but digital zero. Absent from
    /// meetings written before system audio was captured at all.
    public var tracksSilent: [String]?
    /// Tracks that were recorded and that the speech engine refused. Their
    /// audio is kept whatever the delete setting says, because the recording is
    /// the only record of those words that exists.
    public var tracksNotTranscribed: [String]?
    /// What the speech engine said when it refused.
    public var transcriptionFailureReason: String?
    public var audioKept: Bool
    public var syncService: String?

    /// True when the speech engine refused at least one track of this meeting.
    public var transcriptionFailed: Bool { !(tracksNotTranscribed ?? []).isEmpty }

    public init(
        title: String,
        startedAt: Date,
        durationSeconds: Double,
        appVersion: String = MinutesBuild.version,
        transcriptionEngine: String,
        transcriptionModel: String,
        transcriptionRanOn: String = "this Mac",
        transcriptionRealtimeFactor: Double? = nil,
        notesEndpoint: String? = nil,
        notesModel: String? = nil,
        notesState: String,
        tracksRecorded: [String],
        tracksMissing: [String],
        tracksSilent: [String] = [],
        tracksNotTranscribed: [String] = [],
        transcriptionFailureReason: String? = nil,
        audioKept: Bool,
        syncService: String? = nil
    ) {
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.appVersion = appVersion
        self.transcriptionEngine = transcriptionEngine
        self.transcriptionModel = transcriptionModel
        self.transcriptionRanOn = transcriptionRanOn
        self.transcriptionRealtimeFactor = transcriptionRealtimeFactor
        self.notesEndpoint = notesEndpoint
        self.notesModel = notesModel
        self.notesState = notesState
        self.tracksRecorded = tracksRecorded
        self.tracksMissing = tracksMissing
        self.tracksSilent = tracksSilent
        self.tracksNotTranscribed = tracksNotTranscribed
        self.transcriptionFailureReason = transcriptionFailureReason
        self.audioKept = audioKept
        self.syncService = syncService
    }
}

/// The headings `notes.md` is written with. They are named once so the writer
/// and the reader can never drift apart.
public enum NotesSection {
    public static let owner = "## Notes you typed"
    public static let model = "## Notes written from the transcript"
    public static let pending = "## Notes are waiting"
}

public enum MeetingSlug {
    public static func directoryName(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        // A fixed locale, because a 12-hour locale turns HHmm into "200 PM"
        // and the folder name is a filename, not something to read aloud.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(formatter.string(from: date))-\(slug(title))"
    }

    public static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if trimmed.isEmpty { return "meeting" }
        return String(trimmed.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Creates and writes meeting directories.
public struct MeetingStore: Sendable {

    public let root: URL

    private var fileManager: FileManager { .default }

    public init(root: URL) {
        self.root = root
    }

    public init(settings: AppSettings) {
        self.init(root: settings.notesFolderURL)
    }

    /// The sentence to show about this folder, or nil when it does not sync.
    public var syncWarning: String? { SyncFolderDetector.warning(for: root) }
    public var syncService: String? { SyncFolderDetector.service(for: root) }

    @discardableResult
    public func createMeeting(title: String, date: Date = Date()) throws -> MeetingDirectory {
        var name = MeetingSlug.directoryName(title: title, date: date)
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            name = "\(MeetingSlug.directoryName(title: title, date: date))-\(suffix)"
            candidate = root.appendingPathComponent(name, isDirectory: true)
            suffix += 1
        }
        let directory = MeetingDirectory(url: candidate)
        try fileManager.createDirectory(at: directory.audioDirectory, withIntermediateDirectories: true)
        return directory
    }

    public func writeTranscript(_ transcript: Transcript, title: String, to directory: MeetingDirectory) throws {
        try transcript.markdown(title: title).write(to: directory.transcriptURL, atomically: true, encoding: .utf8)
    }

    /// Notes with front matter naming what produced them. `pendingReason` is
    /// written when the endpoint did not answer, so a meeting is never lost
    /// because a machine was off.
    public func writeNotes(
        title: String,
        date: Date,
        duration: TimeInterval,
        ownerNotes: String,
        body: String?,
        pendingReason: String?,
        transcriptionEngine: String,
        transcriptionModel: String,
        notesEndpoint: String,
        notesModel: String,
        to directory: MeetingDirectory
    ) throws {
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlString(title))")
        lines.append("date: \(ISO8601DateFormatter().string(from: date))")
        lines.append("duration: \(Timecode.string(from: duration))")
        lines.append("transcription_engine: \(yamlString(transcriptionEngine))")
        lines.append("transcription_model: \(yamlString(transcriptionModel))")
        lines.append("notes_endpoint: \(yamlString(notesEndpoint))")
        lines.append("notes_model: \(yamlString(notesModel))")
        lines.append("notes_state: \(body == nil ? "pending" : "written")")
        lines.append("---")
        lines.append("")

        let typed = ownerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            lines.append(NotesSection.owner)
            lines.append("")
            lines.append(typed)
            lines.append("")
        }

        if let body {
            lines.append(NotesSection.model)
            lines.append("")
            lines.append(body)
        } else {
            lines.append(NotesSection.pending)
            lines.append("")
            lines.append(pendingReason ?? "The notes endpoint did not answer. The transcript is saved.")
        }
        lines.append("")

        try lines.joined(separator: "\n").write(to: directory.notesURL, atomically: true, encoding: .utf8)
    }

    /// The owner's own words, written once and read for every re-run. Keeping
    /// them in their own file is what makes "write notes again" safe: the notes
    /// file is rewritten, this one is not.
    public func writeBullets(_ text: String, to directory: MeetingDirectory) throws {
        try text.write(to: directory.bulletsURL, atomically: true, encoding: .utf8)
    }

    public func readBullets(in directory: MeetingDirectory) -> String? {
        try? String(contentsOf: directory.bulletsURL, encoding: .utf8)
    }

    public func writeMeta(_ meta: MeetingMeta, to directory: MeetingDirectory) throws {
        try MeetingStore.metaEncoder.encode(meta).write(to: directory.metaURL, options: .atomic)
    }

    public func readMeta(in directory: MeetingDirectory) throws -> MeetingMeta {
        try MeetingStore.metaDecoder.decode(MeetingMeta.self, from: Data(contentsOf: directory.metaURL))
    }

    /// One encoder and one decoder, so what is written is always what can be
    /// read back. Dates are ISO 8601 on both sides.
    public static let metaEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let metaDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The recording is the most sensitive thing in the directory. Unless the
    /// owner asked to keep it, it goes as soon as the transcript exists.
    public func deleteAudio(in directory: MeetingDirectory) throws {
        guard fileManager.fileExists(atPath: directory.audioDirectory.path) else { return }
        for file in try fileManager.contentsOfDirectory(at: directory.audioDirectory, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: file)
        }
    }

    public func meetings() throws -> [MeetingDirectory] {
        // The URL form of `contentsOfDirectory` refuses a symlink to a
        // directory outright, with POSIX 20, "Not a directory". A notes folder
        // that is itself a link would then show no meetings at all, and an
        // error nobody can act on, while every meeting sits on the disk.
        // Resolving first costs nothing: it is the same folder, so they are the
        // same meetings.
        let folder = root.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        return
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(MeetingDirectory.init(url:))
    }

    private func yamlString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
