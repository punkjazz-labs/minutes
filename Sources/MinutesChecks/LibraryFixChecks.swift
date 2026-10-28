import Foundation
import MinutesCore

/// Settings, front matter, renames, anchors and search, each checked against
/// real files.
func libraryFixChecks(_ run: CheckRun) throws {
    run.section("Settings survive a field they do not know")

    do {
        let blob = """
            {"notesBaseURL":"http://gateway:4000/v1","notesModel":"profile/general",
             "notesFolderPath":"/Users/someone/Meetings","keepAudioAfterTranscription":"yes please",
             "aSettingFromTheFuture":42}
            """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(blob.utf8))
        run.equal(decoded.notesFolderPath, "/Users/someone/Meetings", "the notes folder survives a field that could not be read")
        run.equal(decoded.notesBaseURL, "http://gateway:4000/v1", "the endpoint survives too")
        run.equal(decoded.keepAudioAfterTranscription, false, "the unreadable field falls back to its own default")
        run.equal(decoded.asrModel, .v3, "a missing field falls back to its own default")

        let defaults = UserDefaults(suiteName: "minutes.checks.\(UUID().uuidString)")!
        defaults.set(Data(blob.utf8), forKey: "minutes.settings.v1")
        let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
        run.equal(loaded.notesFolderPath, "/Users/someone/Meetings", "the app does not reset the notes folder over one field")
    }

    run.section("Front matter holds any title")

    do {
        let root = try Scratch.directory("yaml")
        let store = MeetingStore(root: root)
        let directory = try store.createMeeting(title: "escapes", date: Date())
        let title = #"C:\new "quoted" title"# + "\nwith a second line"
        try store.writeNotes(
            title: title, date: Date(), duration: 60, ownerNotes: "", body: "x", pendingReason: nil,
            transcriptionEngine: "engine", transcriptionModel: "model",
            notesEndpoint: "http://127.0.0.1:4000/v1", notesModel: "profile/general", to: directory)
        let written = try String(contentsOf: directory.notesURL, encoding: .utf8)
        let titleLines = written.split(separator: "\n").filter { $0.hasPrefix("title:") }
        run.equal(titleLines.count, 1, "a title with a line break stays on one line of front matter")
        run.equal(
            NotesDocument.parse(at: directory.notesURL)?.frontMatter["title"] ?? "", title,
            "a backslash, quotes and a line break read back exactly")

        let older = NotesDocument.parse("---\ntitle: \"C:\\Users\\bob\"\n---\n")
        run.equal(
            older.frontMatter["title"] ?? "", #"C:\Users\bob"#,
            "a file from an older version with bare backslashes still reads as written")
    }

    run.section("A rename keeps a meta.json it cannot read")

    do {
        let root = try Scratch.directory("rename-unreadable")
        let store = MeetingStore(root: root)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let directory = try store.createMeeting(title: "Old name", date: date)
        try Transcript(
            segments: [TranscriptSegment(track: .me, start: 0, end: 1, text: "Hello.")],
            engine: "e", model: "m", recordedAt: date, duration: 60
        ).markdown(title: "Old name").write(to: directory.transcriptURL, atomically: true, encoding: .utf8)
        let damaged = Data("{\"title\": \"Old name\", \"transcriptionEngine\": \"Parakeet".utf8)
        try damaged.write(to: directory.metaURL)

        guard let summary = MeetingSummary.read(directory) else {
            run.failed("a meeting with a transcript should be listed")
            return
        }
        let renamed = try MeetingLibrary(root: root).rename(summary, to: "New name")
        let kept = renamed.directory.url.appendingPathComponent("meta.unreadable.json")
        run.equal(
            (try? Data(contentsOf: kept)) ?? Data(), damaged,
            "the unreadable meta.json is set aside byte for byte, not written over")
        run.equal(
            (try? store.readMeta(in: renamed.directory))?.title ?? "", "New name",
            "the new title still holds")
    }

    run.section("A note line keeps every timestamp it was written with")

    do {
        let transcript = TranscriptFile.lines(
            markdown: """
                [00:01:00] You: The price holds through March.
                [00:02:00] Others: We agreed on that.
                """)
        let anchored = NoteAnchoring.anchor(
            "- The price holds through March. [00:01:00] [00:09:59]", to: transcript)
        let line = anchored.lines.first
        run.equal(line?.anchors.count ?? 0, 2, "a line with one timestamp that holds and one that does not keeps both")
        run.equal(line?.anchors.filter(\.isResolved).count ?? 0, 1, "the one that holds is a link")
        run.equal(
            line?.anchors.first { !$0.isResolved }?.timecode ?? "", "00:09:59",
            "the one that does not is kept and marked, rather than dropped without a word")
        run.expect(anchored.unanchored.isEmpty, "the line is not moved out of the notes, because part of it holds")
    }

    run.section("A search snippet reads as speech")

    do {
        let root = try Scratch.directory("snippet-speech")
        let store = MeetingStore(root: root)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let directory = try store.createMeeting(title: "Renewal", date: date)
        try Transcript(
            segments: [
                TranscriptSegment(track: .me, start: 252, end: 260, text: "I wanted to start with the contract."),
                TranscriptSegment(track: .others, start: 262, end: 270, text: "Sure, the extension starts in October."),
            ],
            engine: "e", model: "m", recordedAt: date, duration: 600
        ).markdown(title: "Renewal").write(to: directory.transcriptURL, atomically: true, encoding: .utf8)
        let snippet = try MeetingLibrary(root: root).search("extension").first?.snippet
        run.expect(!(snippet?.text.contains("[00:") ?? true), "a snippet carries no timecodes")
        run.expect(snippet?.text.contains("Others: Sure") ?? false, "a snippet still says who was speaking")
    }

    run.section("Search reads a file again only when it changed")

    do {
        let root = try Scratch.directory("search-cache")
        let store = MeetingStore(root: root)
        for title in ["First", "Second"] {
            let date = Date(timeIntervalSince1970: title == "First" ? 1_790_000_000 : 1_790_003_600)
            let directory = try store.createMeeting(title: title, date: date)
            try Transcript(
                segments: [TranscriptSegment(track: .me, start: 0, end: 1, text: "We talked about \(title) things.")],
                engine: "e", model: "m", recordedAt: date, duration: 60
            ).markdown(title: title).write(to: directory.transcriptURL, atomically: true, encoding: .utf8)
        }

        let library = MeetingLibrary(root: root)
        let cache = MeetingTextCache()
        let first = try library.search("things", cache: cache)
        let readsAfterFirst = cache.reads
        _ = try library.search("thing", cache: cache)
        run.equal(first.count, 2, "both meetings match")
        run.equal(cache.reads, readsAfterFirst, "a second keystroke reads no file that has not changed")

        let changed = try store.meetings().first { $0.url.lastPathComponent.hasSuffix("second") }!
        try "[00:00:00] You: A brand new word, pineapple, was said.\n".write(
            to: changed.transcriptURL, atomically: true, encoding: .utf8)
        let found = try library.search("pineapple", cache: cache)
        run.equal(found.count, 1, "a transcript that changed is read again and searched")
        run.equal(cache.reads, readsAfterFirst + 1, "and only that file is read again")
    }
}
