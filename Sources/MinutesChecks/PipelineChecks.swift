import Foundation
import MinutesCore

/// A speech engine that refuses, the way an incomplete model download or a
/// Core ML failure makes the real one refuse.
private struct RefusingTranscriber: Transcribing {
    let engineName = "FluidAudio Parakeet TDT (fake)"
    let modelName = "parakeet-tdt-0.6b-v3-coreml"

    func modelsAreReady() -> Bool { true }
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}

    func transcribe(fileAt url: URL, track: AudioTrack) async throws -> TranscriptionOutput {
        throw TranscriptionError.engineFailure("the model could not be loaded")
    }
}

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

    // Two real tracks: both sides land in the transcript under their own
    // labels, both files are kept, and nothing claims a side is missing.
    do {
        let root = try Scratch.directory("pipeline-two-tracks")
        var settings = AppSettings(notesFolderPath: root.path)
        settings.keepAudioAfterTranscription = true

        let systemURL = root.appendingPathComponent("system-source.wav")
        let tap = SystemAudioCapture(
            watchdogInterval: 0,
            watchesOutputDevice: false,
            source: { FakeSystemAudioSource(value: 0.5, seconds: 1) })
        try tap.start(writingTo: systemURL)
        let systemCapture = try tap.stop()

        let outcome = try await makePipeline(settings: settings, root: root, notes: StubNotes(body: "notes", error: nil))
            .run(
                title: "Both sides",
                startedAt: Date(timeIntervalSince1970: 0),
                ownerNotes: "",
                captures: [try staged(.me, in: root), systemCapture])

        let transcript = try String(contentsOf: outcome.directory.transcriptURL, encoding: .utf8)
        run.expect(transcript.contains("You: Let us talk about pricing."), "your side is labelled You")
        run.expect(transcript.contains("Others: The renewal is in October."), "the tapped side is labelled Others")
        run.expect(
            !transcript.contains("No audio was recorded on"),
            "nothing claims a side is missing when both sides were heard")
        run.expect(
            !transcript.contains("every sample was digital zero"),
            "nothing claims a side was silent when both sides were heard")
        run.expect(outcome.transcript.bothSidesWereHeard, "the transcript knows both sides were heard")

        run.expect(
            FileManager.default.fileExists(atPath: outcome.directory.audioURL(for: .me).path),
            "mic.wav is stored under the meeting")
        run.expect(
            FileManager.default.fileExists(atPath: outcome.directory.audioURL(for: .others).path),
            "system.wav is stored under the meeting")

        let meta = try MeetingStore(root: root).readMeta(in: outcome.directory)
        run.equal(meta.tracksRecorded.sorted(), ["me", "others"], "meta.json records both tracks")
        run.equal(meta.tracksSilent ?? [], [], "meta.json records that neither track was silent")
    }

    // A tap that was granted nothing, next to a working microphone. The second
    // track exists but carried no signal, and that is not the same thing as a
    // meeting that was recorded properly.
    do {
        let root = try Scratch.directory("pipeline-silent-tap")
        var settings = AppSettings(notesFolderPath: root.path)
        settings.keepAudioAfterTranscription = true

        let systemURL = root.appendingPathComponent("silent-source.wav")
        let tap = SystemAudioCapture(
            policy: TapRebuildPolicy(silenceThreshold: 0.2, maximumRebuilds: 1),
            watchdogInterval: 0,
            watchesOutputDevice: false,
            source: { FakeSystemAudioSource(value: 0, seconds: 1) })
        try tap.start(writingTo: systemURL)
        tap.checkForStalledTap()
        let systemCapture = try tap.stop()

        let outcome = try await makePipeline(settings: settings, root: root, notes: StubNotes(body: "notes", error: nil))
            .run(
                title: "One side only",
                startedAt: Date(timeIntervalSince1970: 0),
                ownerNotes: "",
                captures: [try staged(.me, in: root), systemCapture])

        let transcript = try String(contentsOf: outcome.directory.transcriptURL, encoding: .utf8)
        run.expect(
            transcript.contains("The Others track was recorded but every sample was digital zero"),
            "a track that heard nothing is named on the transcript")
        run.expect(!outcome.transcript.bothSidesWereHeard, "a silent second track is not two sides recorded")
        run.expect(
            outcome.transcript.segments.allSatisfy { $0.track == .me },
            "a silent track is never sent to the speech engine")
        run.expect(
            !FileManager.default.fileExists(atPath: outcome.directory.audioURL(for: .others).path),
            "a silent track is discarded rather than saved as if it were a recording")
        run.expect(
            outcome.events.contains { $0.message.contains("Rebuilding the tap") },
            "the rebuild the tap attempted is in the activity log")

        let meta = try MeetingStore(root: root).readMeta(in: outcome.directory)
        run.equal(meta.tracksSilent ?? [], ["others"], "meta.json names the track that heard nothing")
        run.equal(meta.tracksRecorded, ["me"], "meta.json does not count a silent track as recorded")
    }

    // The speech engine refuses. An incomplete model download, a Core ML
    // failure, any engine error. The meeting must survive it: the recording is
    // already in the folder and the folder is the only place it exists.
    do {
        let root = try Scratch.directory("pipeline-engine-failed")
        var settings = AppSettings(notesFolderPath: root.path)
        settings.keepAudioAfterTranscription = false

        let outcome = try await MeetingPipeline(
            settings: settings,
            store: MeetingStore(root: root),
            transcriber: RefusingTranscriber(),
            notes: StubNotes(body: "notes", error: nil)
        ).run(
            title: "The engine gave up",
            startedAt: Date(timeIntervalSince1970: 0),
            ownerNotes: "- do not lose this",
            captures: [try staged(.me, in: root)],
            missingTracks: [.others])

        run.expect(
            FileManager.default.fileExists(atPath: outcome.directory.audioURL(for: .me).path),
            "a speech engine failure keeps the audio, whatever the delete setting says")

        let transcript = try String(contentsOf: outcome.directory.transcriptURL, encoding: .utf8)
        run.expect(
            transcript.contains("the speech engine could not read it"),
            "the transcript says the speech engine refused the track")
        run.expect(
            transcript.contains("the model could not be loaded"),
            "the transcript carries the reason the engine gave")

        let notes = try String(contentsOf: outcome.directory.notesURL, encoding: .utf8)
        run.expect(notes.contains("- do not lose this"), "an engine failure never costs what the owner typed")

        let meta = try MeetingStore(root: root).readMeta(in: outcome.directory)
        run.equal(meta.tracksNotTranscribed ?? [], ["me"], "meta.json names the track the engine refused")
        run.expect(meta.transcriptionFailed, "meta.json records that transcription failed")
        run.expect(meta.audioKept, "meta.json records that the audio was kept")

        // The whole point: the meeting is reachable afterwards.
        if let summary = MeetingSummary.read(outcome.directory) {
            run.equal(
                summary.notesState.label, "Transcription failed",
                "the library row says the transcription failed")
            run.equal(summary.title, "The engine gave up", "the meeting keeps its title in the library")
        } else {
            run.failed("a meeting whose transcription failed must still be a row in the library")
        }
        run.equal(
            try MeetingLibrary(root: root).meetings().count, 1,
            "a speech engine failure never removes the meeting from the library")
    }

    // A track that delivered no frames at all. An empty 44 byte WAV is not a
    // recording of the other side, and must not be written up as one.
    do {
        let root = try Scratch.directory("pipeline-empty-track")
        var settings = AppSettings(notesFolderPath: root.path)
        settings.keepAudioAfterTranscription = true

        let emptyURL = root.appendingPathComponent("no-frames.wav")
        try WAVWriter(url: emptyURL).close()
        let nothing = CaptureResult(track: .others, fileURL: emptyURL, duration: 0, signal: SignalCheck())

        let outcome = try await makePipeline(settings: settings, root: root, notes: StubNotes(body: "notes", error: nil))
            .run(
                title: "No frames on the other side",
                startedAt: Date(timeIntervalSince1970: 0),
                ownerNotes: "",
                captures: [try staged(.me, in: root), nothing])

        let meta = try MeetingStore(root: root).readMeta(in: outcome.directory)
        run.equal(meta.tracksSilent ?? [], ["others"], "a track that delivered no frames is named under tracksSilent")
        run.equal(meta.tracksRecorded, ["me"], "a track that delivered no frames is not a recorded track")
        run.expect(
            outcome.transcript.segments.allSatisfy { $0.track == .me },
            "a track that delivered no frames is never sent to the speech engine")
        run.expect(
            !FileManager.default.fileExists(atPath: outcome.directory.audioURL(for: .others).path),
            "an empty WAV is discarded rather than stored as a recording")
        run.expect(!outcome.transcript.bothSidesWereHeard, "an empty second track is not two sides heard")

        if let summary = MeetingSummary.read(outcome.directory) {
            run.expect(
                !summary.bothSidesRecorded,
                "the meeting does not claim both sides were recorded")
        } else {
            run.failed("the meeting should still be a row in the library")
        }
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

    // What the owner typed belongs to the meeting it was typed for.
    do {
        var draft = MeetingDraft(title: "Pricing call", bullets: "- Bob agreed to 15 percent")
        run.equal(draft.meetingTitle(or: "Meeting 5 August 14:00"), "Pricing call", "a typed title is the title")
        run.equal(
            MeetingDraft(bullets: "x").meetingTitle(or: "Meeting 5 August 14:00"),
            "Meeting 5 August 14:00",
            "an empty title falls back to the time of day")
        run.equal(
            MeetingDraft(title: "   ").meetingTitle(or: "Meeting 5 August 14:00"),
            "Meeting 5 August 14:00",
            "a title of spaces is not a title")

        draft.clearAfterWriteUp()
        run.equal(draft.title, "", "a meeting that was written up does not lend its title to the next one")
        run.equal(draft.bullets, "", "a meeting that was written up does not lend its bullets to the next one")
        run.expect(draft.isEmpty, "nothing at all carries into the next meeting")

        // And the other half of the rule: words that are not on disk yet stay.
        let typedBeforeRecording = MeetingDraft(title: "Pricing call", bullets: "- ask about the renewal")
        run.expect(
            !typedBeforeRecording.isEmpty,
            "what a person typed before pressing record is not cleared by anything but a write-up")
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
