import Foundation

/// One row of the library, built from the files that are actually there.
///
/// `meta.json` is the best source, the front matter of `notes.md` is the next
/// one, and the directory name is the last. A meeting written by an older
/// version, or half written, still gets a row.
public struct MeetingSummary: Sendable, Equatable, Identifiable {

    public let directory: MeetingDirectory
    public let title: String
    public let startedAt: Date
    public let duration: TimeInterval
    public let notesState: NotesState
    public let tracksRecorded: [String]

    public init(
        directory: MeetingDirectory,
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        notesState: NotesState,
        tracksRecorded: [String] = []
    ) {
        self.directory = directory
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.notesState = notesState
        self.tracksRecorded = tracksRecorded
    }

    /// Resolved, because the same folder reached two ways is one meeting and
    /// not two rows.
    public var id: String { directory.url.resolvingSymlinksInPath().path }

    public var lengthText: String { "\(Int((duration / 60).rounded())) min" }

    public var bothSidesRecorded: Bool {
        tracksRecorded.contains(AudioTrack.me.rawValue) && tracksRecorded.contains(AudioTrack.others.rawValue)
    }

    /// Today, then the weekday for the last week, then the date.
    public func dateText(now: Date = Date(), calendar: Calendar = Calendar.current) -> String {
        let time = MeetingSummary.formatter("HH:mm").string(from: startedAt)
        if calendar.isDateInToday(startedAt) { return "Today \(time)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: startedAt), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 { return "\(MeetingSummary.formatter("EEE").string(from: startedAt)) \(time)" }
        return "\(MeetingSummary.formatter("MMM d").string(from: startedAt)) \(time)"
    }

    static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// Reads one meeting directory. Nil when the directory holds no meeting at
    /// all, so a stray folder in the notes folder is not shown as one.
    public static func read(_ directory: MeetingDirectory) -> MeetingSummary? {
        let fileManager = FileManager.default
        let hasTranscript = fileManager.fileExists(atPath: directory.transcriptURL.path)
        let hasNotes = fileManager.fileExists(atPath: directory.notesURL.path)
        let meta = try? MeetingStore(root: directory.url.deletingLastPathComponent()).readMeta(in: directory)
        guard hasTranscript || hasNotes || meta != nil else { return nil }

        let document = hasNotes ? NotesDocument.parse(at: directory.notesURL) : nil
        let fromName = nameParts(directory.url.lastPathComponent)

        let title =
            meta?.title
            ?? document?.frontMatter["title"]
            ?? fromName.title

        let startedAt =
            meta?.startedAt
            ?? document?.frontMatter["date"].flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? fromName.date
            ?? Date(timeIntervalSince1970: 0)

        let duration =
            meta?.durationSeconds
            ?? document?.frontMatter["duration"].flatMap { Timecode.seconds(from: $0) }
            ?? 0

        let state: NotesState
        if meta?.transcriptionFailed == true {
            // The recording is on the disk and the speech engine would not read
            // it. That is the fact the row has to carry, above anything the
            // notes file says, because it is the one the owner can act on.
            state = .transcriptionFailed
        } else if !hasNotes {
            state = .transcriptOnly
        } else if let document {
            state = document.state
        } else {
            state = meta?.notesState == "written" ? .written : .pending
        }

        return MeetingSummary(
            directory: directory,
            title: title,
            startedAt: startedAt,
            duration: duration,
            notesState: state,
            tracksRecorded: meta?.tracksRecorded ?? [])
    }

    /// `yyyy-MM-dd-HHmm-slug` read back, for a meeting with no other record.
    ///
    /// The title is the slug and not the whole directory name. Returning the
    /// whole name puts the date on screen as part of the title, and the rename
    /// field is filled from what is on screen, so the next rename writes the
    /// date into the directory name a second time.
    static func nameParts(_ name: String) -> (date: Date?, title: String) {
        let parts = name.split(separator: "-", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, let date = formatter("yyyy-MM-dd-HHmm").date(from: parts[0...3].joined(separator: "-"))
        else {
            return (nil, name)
        }
        guard parts.count >= 5 else { return (date, name) }
        return (date, parts[4...].joined(separator: "-"))
    }
}
