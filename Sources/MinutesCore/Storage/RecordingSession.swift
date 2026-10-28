import Foundation

/// One meeting while it is being recorded, kept where a crash cannot take it.
///
/// The recordings used to be written to the system's temporary folder. A WAV
/// that is readable after a crash is worth nothing if nothing ever looks for it
/// again, and nothing did: the app forgot the meeting the moment it quit, the
/// owner had no way to know where the file was, and macOS clears that folder on
/// its own schedule. So a meeting now records into its own folder under
/// Application Support, with a small manifest beside the audio that holds the
/// title and the bullets as they are typed, and the app looks for leftovers
/// every time it starts.
///
/// Application Support and not the notes folder, because the notes folder may
/// sync, and a recording that is still growing should not be copied to a cloud
/// service a few seconds at a time.
///
///     recordings-in-progress/<id>/
///       session.json    when it started, the title and the bullets typed so far
///       mic.wav
///       system.wav
public struct RecordingSession: Sendable, Equatable, Identifiable {

    /// What the session knows about its meeting besides the audio.
    public struct Manifest: Codable, Sendable, Equatable {
        public var id: String
        public var startedAt: Date
        public var title: String
        public var bullets: String
        public var appVersion: String

        public init(id: String, startedAt: Date, title: String, bullets: String, appVersion: String = MinutesBuild.version) {
            self.id = id
            self.startedAt = startedAt
            self.title = title
            self.bullets = bullets
            self.appVersion = appVersion
        }

        public var draft: MeetingDraft { MeetingDraft(title: title, bullets: bullets) }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var id: String { directory.lastPathComponent }
    public var manifestURL: URL { directory.appendingPathComponent("session.json") }

    public func audioURL(for track: AudioTrack) -> URL {
        directory.appendingPathComponent(track.fileName)
    }

    /// `~/Library/Application Support/minutes/recordings-in-progress`.
    public static var defaultRoot: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return
            support
            .appendingPathComponent(MinutesBuild.productName, isDirectory: true)
            .appendingPathComponent("recordings-in-progress", isDirectory: true)
    }

    /// Makes the folder and writes the first manifest, before any audio exists.
    public static func begin(in root: URL, startedAt: Date, draft: MeetingDraft) throws -> RecordingSession {
        let id = "\(Int(startedAt.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let session = RecordingSession(directory: root.appendingPathComponent(id, isDirectory: true))
        try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true)
        try session.write(
            Manifest(id: id, startedAt: startedAt, title: draft.title, bullets: draft.bullets))
        return session
    }

    /// Keeps the title and the bullets on disk while they are typed, so a
    /// crash costs neither of them.
    public func save(draft: MeetingDraft) throws {
        var current = try manifest()
        guard current.title != draft.title || current.bullets != draft.bullets else { return }
        current.title = draft.title
        current.bullets = draft.bullets
        try write(current)
    }

    public func manifest() throws -> Manifest {
        try MeetingStore.metaDecoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
    }

    private func write(_ manifest: Manifest) throws {
        try MeetingStore.metaEncoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    /// The tracks this session holds, measured from the files on disk. A track
    /// whose file is missing or unreadable is not in the list.
    public func captures() -> [CaptureResult] {
        AudioTrack.allCases.compactMap { track in
            let url = audioURL(for: track)
            guard FileManager.default.fileExists(atPath: url.path),
                let measured = try? WAVReader.measure(url: url)
            else { return nil }
            return CaptureResult(track: track, fileURL: url, duration: measured.duration, signal: measured.signal)
        }
    }

    /// Removes the session folder. Called once the meeting is written up, or
    /// when the owner chooses to throw an interrupted recording away.
    public func discard() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Sessions left behind by a run that ended before writing them up,
    /// oldest first. The session recording right now is passed in so it is
    /// never offered as an interrupted one.
    public static func leftovers(in root: URL, excluding live: Set<String> = []) -> [RecordingSession] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(RecordingSession.init(directory:))
            .filter { !live.contains($0.id) }
            .filter { FileManager.default.fileExists(atPath: $0.manifestURL.path) }
            .sorted { $0.id < $1.id }
    }
}

/// An interrupted recording, as the menu offers it back.
public struct RecoverableRecording: Sendable, Equatable, Identifiable {
    public let session: RecordingSession
    public let manifest: RecordingSession.Manifest
    public let duration: TimeInterval
    public let tracks: [AudioTrack]

    public var id: String { session.id }

    /// Reads one leftover session. Nil when its manifest cannot be read.
    public static func read(_ session: RecordingSession) -> RecoverableRecording? {
        guard let manifest = try? session.manifest() else { return nil }
        let captures = session.captures()
        return RecoverableRecording(
            session: session,
            manifest: manifest,
            duration: captures.map(\.duration).max() ?? 0,
            tracks: captures.map(\.track))
    }

    /// The title the meeting will be written up under.
    public func title(defaultFormatter: (Date) -> String) -> String {
        manifest.draft.meetingTitle(or: defaultFormatter(manifest.startedAt))
    }

    /// What the write-up needs: the tracks that are there, and the ones that
    /// are not named as missing.
    public var missingTracks: [AudioTrack] {
        AudioTrack.allCases.filter { !tracks.contains($0) }
    }
}
