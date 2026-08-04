import Foundation
import MinutesCore

private struct StubNotes: NotesGenerating {
    let body: String?
    let error: NotesError?

    func enhance(_ request: NotesRequest) async throws -> NotesResult {
        if let error { throw error }
        return NotesResult(markdown: body ?? "", model: "profile/general", endpoint: "http://127.0.0.1:4000/v1")
    }

    func probeModels() async throws -> [String] { ["profile/general"] }
}

/// The whole path from finished recordings to files on disk, with the speech
/// engine and the endpoint both faked.
func pipelineChecks(_ run: CheckRun) async throws {
    run.section("Meeting pipeline")

    let goldenSegments = [
        TranscriptSegment(track: .me, start: 0, end: 2, text: "Let us talk about pricing."),
        TranscriptSegment(track: .others, start: 2, end: 4, text: "The renewal is in October."),
    ]

    func makePipeline(settings: AppSettings, root: URL, notes: StubNotes) -> MeetingPipeline {
        MeetingPipeline(
            settings: settings,
            store: MeetingStore(root: root),
            transcriber: FixtureTranscriber(
                engineName: "FluidAudio Parakeet TDT (fake)",
                modelName: "parakeet-tdt-0.6b-v3-coreml",
                segments: goldenSegments,
                audioDuration: 4),
            notes: notes)
    }

    func staged(_ track: AudioTrack, in directory: URL, silent: Bool = false) throws -> CaptureResult {
        let url = directory.appendingPathComponent("staged-\(track.rawValue)-\(UUID().uuidString).wav")
        let samples: [Float] =
            silent
            ? [Float](repeating: 0, count: 16_000)
            : (0..<16_000).map { Float(sin(Double($0) * 0.01)) * 0.3 }
        let capture = FixtureCapture(track: track, samples: samples)
        try capture.start(writingTo: url)
        return try capture.stop()
    }

    // A good run.
    do {
        let root = try Scratch.directory("pipeline-good")
        var settings = AppSettings(notesFolderPath: root.path)
        settings.keepAudioAfterTranscription = false

        let outcome = try await makePipeline(
            settings: settings, root: root,
            notes: StubNotes(body: "## Pricing\n\nRenewal in October [00:00:02].", error: nil)
        ).run(
            title: "Pricing call",
            startedAt: Date(timeIntervalSince1970: 0),
            ownerNotes: "- pricing concerns",
            captures: [try staged(.me, in: root), try staged(.others, in: root)])

        let transcript = try String(contentsOf: outcome.directory.transcriptURL, encoding: .utf8)
        run.expect(transcript.contains("[00:00:00] You: Let us talk about pricing."), "the transcript holds your track")
        run.expect(transcript.contains("[00:00:02] Others: The renewal is in October."), "the transcript holds the other track")

        let notes = try String(contentsOf: outcome.directory.notesURL, encoding: .utf8)
        run.expect(notes.contains("- pricing concerns"), "notes.md keeps what the owner typed")
        run.expect(notes.contains("Renewal in October"), "notes.md holds what the model wrote")
        run.expect(notes.contains("notes_state: written"), "a good run is recorded as written")

        let meta = try MeetingStore(root: root).readMeta(in: outcome.directory)
        run.equal(meta.transcriptionModel, "parakeet-tdt-0.6b-v3-coreml", "meta.json names the engine actually used")
        run.equal(meta.notesState, "written", "meta.json agrees with notes.md")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: outcome.directory.audioDirectory.path)
        run.equal(leftovers.count, 0, "the recording is deleted once the transcript exists")
        run.expect(!outcome.notesArePending, "a good run leaves nothing pending")
    }

    // Audio kept when the setting says so.
    do {
        let root = try Scratch.directory("pipeline-keep")
        var settings = AppSettings(notesFolderPath: root.path)
        settings.keepAudioAfterTranscription = true

        let outcome = try await makePipeline(settings: settings, root: root, notes: StubNotes(body: "notes", error: nil))
            .run(title: "Kept", startedAt: Date(), ownerNotes: "", captures: [try staged(.me, in: root)])

        run.expect(
            FileManager.default.fileExists(atPath: outcome.directory.audioURL(for: .me).path),
            "audio is kept when the setting says to keep it")
        let meta = try MeetingStore(root: root).readMeta(in: outcome.directory)
        run.expect(meta.audioKept, "meta.json records that the audio was kept")
    }

    // The endpoint is off.
    do {
        let root = try Scratch.directory("pipeline-offline")
        let settings = AppSettings(notesFolderPath: root.path)

        let outcome = try await makePipeline(
            settings: settings, root: root,
            notes: StubNotes(body: nil, error: .unreachable("http://127.0.0.1:4000/v1"))
        ).run(
            title: "Offline",
            startedAt: Date(),
            ownerNotes: "- do not lose this",
            captures: [try staged(.me, in: root)])

        run.expect(outcome.notesArePending, "an endpoint that does not answer leaves the notes pending")
        let transcript = try String(contentsOf: outcome.directory.transcriptURL, encoding: .utf8)
        run.expect(transcript.contains("Let us talk about pricing."), "the transcript is written even so")
        let notes = try String(contentsOf: outcome.directory.notesURL, encoding: .utf8)
        run.expect(notes.contains("notes_state: pending"), "the notes file says it is waiting")
        run.expect(notes.contains("- do not lose this"), "a machine being off never costs what the owner typed")
    }

    // A silent track.
    do {
        let root = try Scratch.directory("pipeline-silent")
        let settings = AppSettings(notesFolderPath: root.path)

        let outcome = try await makePipeline(settings: settings, root: root, notes: StubNotes(body: "notes", error: nil))
            .run(
                title: "Silent",
                startedAt: Date(),
                ownerNotes: "",
                captures: [try staged(.me, in: root, silent: true)],
                missingTracks: [.others])

        run.expect(
            outcome.events.contains { $0.message.contains("Nothing was heard") },
            "a silent capture is reported in the activity log")
        run.equal(outcome.transcript.segments.count, 0, "a silent capture is not sent to the speech engine")
        let transcript = try String(contentsOf: outcome.directory.transcriptURL, encoding: .utf8)
        run.expect(transcript.contains("No speech was recognised"), "the transcript says nothing was recognised")
        run.expect(transcript.contains("No audio was recorded on the Others track."), "the missing track is named")
    }

    // Two meetings with the same title and time.
    do {
        let root = try Scratch.directory("pipeline-twice")
        let settings = AppSettings(notesFolderPath: root.path)
        let notes = StubNotes(body: "notes", error: nil)

        let first = try await makePipeline(settings: settings, root: root, notes: notes)
            .run(title: "Same", startedAt: Date(timeIntervalSince1970: 0), ownerNotes: "first",
                 captures: [try staged(.me, in: root)])
        let second = try await makePipeline(settings: settings, root: root, notes: notes)
            .run(title: "Same", startedAt: Date(timeIntervalSince1970: 0), ownerNotes: "second",
                 captures: [try staged(.me, in: root)])

        run.expect(first.directory.url != second.directory.url, "a second meeting never overwrites the first")
        run.expect(
            try String(contentsOf: first.directory.notesURL, encoding: .utf8).contains("first"),
            "the first meeting keeps its own notes")
        run.expect(
            try String(contentsOf: second.directory.notesURL, encoding: .utf8).contains("second"),
            "the second meeting keeps its own notes")
    }
}
