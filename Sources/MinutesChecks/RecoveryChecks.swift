import Foundation
import MinutesCore

private struct AnsweringNotes: NotesGenerating {
    func enhance(_ request: NotesRequest) async throws -> NotesResult {
        NotesResult(markdown: "## Notes\n\n- recovered", model: "profile/general", endpoint: "http://127.0.0.1:4000/v1")
    }

    func probeModels() async throws -> [String] { ["profile/general"] }
}

/// A recording that outlives the app that made it: a crash, a force quit, or
/// a write-up that failed. The recording and the words typed for it are on
/// disk, and the next run finds them and can write them up.
func recoveryChecks(_ run: CheckRun) async throws {
    run.section("A recording that outlives the app")

    let root = try Scratch.directory("sessions")
    let notesRoot = try Scratch.directory("sessions-notes")
    let started = Date(timeIntervalSince1970: 1_790_000_000)

    let session = try RecordingSession.begin(
        in: root, startedAt: started, draft: MeetingDraft(title: "Renewal call", bullets: "- ask about"))
    run.expect(
        session.audioURL(for: .me).path.hasPrefix(session.directory.path),
        "the recording is written inside its own session folder")
    run.equal(try session.manifest().title, "Renewal call", "the title typed before Record is on disk at once")

    // Typing during the meeting reaches the disk.
    try session.save(draft: MeetingDraft(title: "Renewal call", bullets: "- ask about the renewal\n- price holds"))
    run.equal(
        try session.manifest().bullets, "- ask about the renewal\n- price holds",
        "bullets typed during the meeting are kept on disk as they are typed")

    // The app dies mid-meeting: the writers are never closed.
    let tone = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.4 }
    let mic = try WAVWriter(url: session.audioURL(for: .me))
    try mic.append(tone)
    try mic.append(tone)
    let system = try WAVWriter(url: session.audioURL(for: .others))
    try system.append([Float](repeating: 0, count: 32_000))

    let leftovers = RecordingSession.leftovers(in: root)
    run.equal(leftovers.map(\.id), [session.id], "the next run finds the recording it did not write up")
    run.expect(
        RecordingSession.leftovers(in: root, excluding: [session.id]).isEmpty,
        "the recording that is running now is never offered as an interrupted one")

    guard let found = leftovers.first.flatMap(RecoverableRecording.read) else {
        run.failed("an interrupted recording should be readable")
        return
    }
    run.close(found.duration, 2, 0.01, "the offer says how much audio is kept")
    run.equal(found.manifest.bullets, "- ask about the renewal\n- price holds", "the offer carries the bullets typed for it")
    run.equal(Set(found.tracks), Set(AudioTrack.allCases), "both tracks are found")
    run.equal(found.title(defaultFormatter: { _ in "fallback" }), "Renewal call", "it is offered under its own title")

    let captures = found.session.captures()
    run.expect(
        captures.first { $0.track == .me }.map { !$0.signal.isAllZero } ?? false,
        "the microphone track is measured as carrying sound")
    run.expect(
        captures.first { $0.track == .others }?.signal.isAllZero ?? false,
        "a silent track is measured as silent, so the write-up discards it as it would have")

    // Writing it up.
    let pipeline = MeetingPipeline(
        settings: AppSettings(notesFolderPath: notesRoot.path),
        store: MeetingStore(root: notesRoot),
        transcriber: FixtureTranscriber(
            segments: [TranscriptSegment(track: .me, start: 0, end: 2, text: "Does the price hold?")],
            audioDuration: 2),
        notes: AnsweringNotes())
    let outcome = try await pipeline.run(
        title: found.title(defaultFormatter: { _ in "fallback" }),
        startedAt: found.manifest.startedAt,
        ownerNotes: found.manifest.bullets,
        captures: captures,
        missingTracks: found.missingTracks)
    try found.session.discard()

    let bullets = try String(contentsOf: outcome.directory.bulletsURL, encoding: .utf8)
    run.expect(bullets.contains("price holds"), "the recovered meeting keeps what was typed for it")
    run.expect(
        outcome.directory.url.lastPathComponent.hasPrefix(MeetingSlug.directoryName(title: "x", date: started).prefix(15)),
        "the recovered meeting is filed under the time it was recorded, not the time it was recovered")
    run.expect(RecordingSession.leftovers(in: root).isEmpty, "a written-up session is not offered again")

    // A folder with no manifest is not a session.
    let stray = root.appendingPathComponent("not-a-session", isDirectory: true)
    try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
    run.expect(RecordingSession.leftovers(in: root).isEmpty, "a stray folder is not offered as a recording")

    // Where recordings live while they run.
    let defaultRoot = RecordingSession.defaultRoot.path
    run.expect(defaultRoot.contains("/Library/Application Support/"), "recordings in progress live in Application Support")
    run.expect(
        !defaultRoot.hasPrefix(FileManager.default.temporaryDirectory.path),
        "recordings in progress are not in the temporary folder macOS clears on its own")
    run.expect(
        !defaultRoot.hasPrefix(AppSettings().notesFolderURL.path),
        "recordings in progress are not in the notes folder, which may sync while they grow")

    // The measure used for recovery agrees with the full read.
    let measuredURL = notesRoot.appendingPathComponent("measured.wav")
    let writer = try WAVWriter(url: measuredURL)
    try writer.append(tone)
    try writer.close()
    let measured = try WAVReader.measure(url: measuredURL)
    var expected = SignalCheck()
    expected.observe(try WAVReader.read(url: measuredURL).samples)
    run.equal(measured.signal.frameCount, expected.frameCount, "measuring a file sees every frame")
    run.close(Double(measured.signal.peak), Double(expected.peak), 0.0001, "measuring a file sees the same peak")
    run.close(measured.duration, 1, 0.001, "measuring a file gives its length")
}
