import Foundation
import MinutesCore

private struct StubGenerator: NotesGenerating {
    let body: String?
    let error: NotesError?

    func enhance(_ request: NotesRequest) async throws -> NotesResult {
        if let error { throw error }
        return NotesResult(markdown: body ?? "", model: "profile/general", endpoint: "http://127.0.0.1:4000/v1")
    }

    func probeModels() async throws -> [String] { ["profile/general"] }
}

/// One meeting written to disk the way the app writes it, so the library is
/// checked against real files and not against a mock of them.
@discardableResult
private func writeFixture(
    in root: URL,
    title: String,
    date: Date,
    bullets: String,
    notesBody: String?,
    pendingReason: String? = nil,
    lines: [TranscriptSegment],
    writeNotesFile: Bool = true
) throws -> MeetingSummary {
    let store = MeetingStore(root: root)
    let directory = try store.createMeeting(title: title, date: date)
    let transcript = Transcript(
        segments: lines,
        engine: "FluidAudio Parakeet TDT (fake)",
        model: "parakeet-tdt-0.6b-v3-coreml",
        recordedAt: date,
        duration: 2_520)

    try store.writeBullets(bullets, to: directory)
    try store.writeTranscript(transcript, title: title, to: directory)
    if writeNotesFile {
        try store.writeNotes(
            title: title,
            date: date,
            duration: 2_520,
            ownerNotes: bullets,
            body: notesBody,
            pendingReason: pendingReason,
            transcriptionEngine: "FluidAudio Parakeet TDT (fake)",
            transcriptionModel: "parakeet-tdt-0.6b-v3-coreml",
            notesEndpoint: "http://127.0.0.1:4000/v1",
            notesModel: "profile/general",
            to: directory)
    }
    try store.writeMeta(
        MeetingMeta(
            title: title,
            startedAt: date,
            durationSeconds: 2_520,
            transcriptionEngine: "FluidAudio Parakeet TDT (fake)",
            transcriptionModel: "parakeet-tdt-0.6b-v3-coreml",
            notesEndpoint: "http://127.0.0.1:4000/v1",
            notesModel: "profile/general",
            notesState: notesBody == nil ? "pending" : "written",
            tracksRecorded: ["me", "others"],
            tracksMissing: [],
            audioKept: false),
        to: directory)

    guard let summary = MeetingSummary.read(directory) else {
        throw LibraryError.notAMeeting(directory.url.lastPathComponent)
    }
    return summary
}

private let fixtureSegments = [
    TranscriptSegment(track: .me, start: 412, end: 418, text: "So where does that leave us on the Q4 numbers?"),
    TranscriptSegment(
        track: .others, start: 430, end: 440,
        text: "We can commit to the Q4 volume, but only if the pricing holds at list through March."),
    TranscriptSegment(track: .me, start: 451, end: 455, text: "Through March. Noted."),
]

func libraryChecks(_ run: CheckRun) async throws {

    // MARK: - Anchors

    run.section("Note anchors")

    let transcript = TranscriptFile.lines(
        markdown: Transcript(
            segments: fixtureSegments, engine: "e", model: "m", recordedAt: Date(), duration: 2_520
        ).markdown(title: "Pricing call"))

    run.equal(transcript.count, 3, "the transcript file is read back into its lines")
    run.equal(transcript.first?.timecode ?? "", "00:06:52", "a line keeps the timecode it was written with")
    run.equal(transcript.first?.speaker ?? "", "You", "a line keeps the track it came from")
    run.expect(transcript.first?.isOwner == true, "your own track is recognised as yours")
    run.expect(
        !transcript.contains { $0.text.contains("Transcribed on this Mac") },
        "the provenance lines are not read back as speech")

    let notes = """
        ## Pricing concerns

        - They commit to Q4 volume only if list price holds through March. [00:07:10]
        - A follow-up call was scheduled for next Tuesday. [00:59:59]
        - No timestamp was given for this one.

        ## Not anchored to the transcript

        - The board has already approved the renewal.
        """
    let anchored = NoteAnchoring.anchor(notes, to: transcript)

    run.equal(NoteAnchoring.timecodes(in: "a [00:07:10] b [bracket] c").count, 1, "only a real timecode is an anchor")
    run.equal(anchored.lines.count, 3, "the heading and the lines the transcript backs are kept")

    let holds = anchored.lines.first { $0.text.contains("list price holds") }
    run.expect(holds?.anchors.first?.isResolved == true, "a timestamp that is in the transcript is anchored")
    run.equal(holds?.anchors.first?.lineIndex ?? -1, 1, "the anchor points at the line that was actually said")
    run.equal(holds?.anchors.first?.label ?? "", "07:10", "the chip drops the hour when the meeting is under one")
    run.expect(!(holds?.text.contains("[00:07:10]") ?? true), "the timestamp is a chip and not left in the prose")

    run.expect(
        anchored.unanchored.contains { $0.contains("follow-up call") },
        "a timestamp that is not in the transcript is not anchored")
    run.expect(
        !anchored.lines.contains { $0.text.contains("follow-up call") },
        "a line the transcript does not back is taken out of the notes")
    run.expect(
        anchored.unanchored.contains { $0.contains("board has already approved") },
        "what the model itself filed as unanchored stays unanchored")
    run.expect(
        anchored.lines.contains { $0.text.contains("No timestamp was given") },
        "a line with no timestamp at all is left where the model put it")
    run.expect(
        anchored.lines.contains { if case .heading = $0.kind { return true } else { return false } },
        "a heading is kept as a heading")

    // Two people talking in the same second. Timecodes are whole seconds, so
    // both lines carry one timecode between them, and taking the first one
    // lands the chip on the other speaker.
    let sameSecond = TranscriptFile.lines(
        markdown: Transcript(
            segments: [
                TranscriptSegment(track: .me, start: 12, end: 14, text: "I think we should hold the price"),
                TranscriptSegment(
                    track: .others, start: 12, end: 15, text: "we can only pay ten thousand for this"),
            ],
            engine: "e", model: "m", recordedAt: Date(), duration: 60
        ).markdown(title: "Two at once"))

    run.equal(sameSecond.count, 2, "both lines of the same second are read back")
    run.equal(sameSecond[0].timecode, sameSecond[1].timecode, "the two lines really do share one timecode")

    let shared = NoteAnchoring.linesByTimecode(sameSecond)
    run.equal(
        NoteAnchoring.lineIndex(
            for: "00:00:12", quoting: "They would only pay ten thousand for this.", in: shared) ?? -1,
        1,
        "a chip lands on the line whose words the note quotes")
    run.equal(
        NoteAnchoring.lineIndex(
            for: "00:00:12", quoting: "You wanted to hold the price.", in: shared) ?? -1,
        0,
        "the same second resolves the other way for the other speaker's words")
    run.expect(
        NoteAnchoring.lineIndex(for: "00:00:12", quoting: "The two sides disagreed.", in: shared) == nil,
        "words that name neither line get no chip at all")
    run.expect(
        NoteAnchoring.lineIndex(for: "00:04:00", quoting: "anything", in: shared) == nil,
        "a timecode the transcript does not hold still points nowhere")

    let ambiguous = NoteAnchoring.anchor(
        "- The two sides did not agree. [00:00:12]", to: sameSecond)
    run.expect(
        ambiguous.lines.isEmpty,
        "a line whose timestamp cannot be decided is taken out of the notes")
    run.expect(
        ambiguous.unanchored.contains { $0.contains("did not agree") },
        "a line whose timestamp cannot be decided goes to the box that says it is not in the transcript")

    let decided = NoteAnchoring.anchor(
        "- They would only pay ten thousand for this. [00:00:12]", to: sameSecond)
    run.equal(
        decided.lines.first?.anchors.first?.lineIndex ?? -1, 1,
        "a note that quotes one of the two lines is anchored to that line")

    // The same rule for an answer, which is prose and not a bullet, so the
    // sentence around the timestamp is what decides it.
    let answer = "Nothing was settled. The other side would only pay ten thousand for this [00:00:12]."
    guard let bracket = answer.firstIndex(of: "[") else {
        run.failed("the check could not find the timestamp in its own fixture")
        return
    }
    run.equal(
        NoteAnchoring.lineIndex(
            for: "00:00:12",
            quoting: NoteAnchoring.context(around: bracket, in: answer),
            in: shared) ?? -1,
        1,
        "a timestamp inside an answer lands on the line that sentence quotes")
    run.expect(
        !NoteAnchoring.context(around: bracket, in: answer).contains("Nothing was settled"),
        "the sentence around the timestamp decides it, and not the whole answer")

    // MARK: - The library and search

    run.section("Meeting library")

    let root = try Scratch.directory("library")
    let library = MeetingLibrary(root: root)
    let calendar = Calendar(identifier: .gregorian)
    let day = calendar.date(from: DateComponents(year: 2_026, month: 7, day: 28, hour: 16))!

    let pricing = try writeFixture(
        in: root,
        title: "Pricing call with the reseller",
        date: day,
        bullets: "- pricing concerns\n- renewal date",
        notesBody: "## Pricing concerns\n\n- List price holds through March. [00:07:10]",
        lines: fixtureSegments)

    let standup = try writeFixture(
        in: root,
        title: "Weekly standup",
        date: calendar.date(from: DateComponents(year: 2_026, month: 7, day: 27, hour: 9, minute: 30))!,
        bullets: "",
        notesBody: nil,
        pendingReason: "The notes endpoint did not answer.",
        lines: [TranscriptSegment(track: .me, start: 10, end: 14, text: "Revisit the pricing page copy before launch.")])

    let bare = try writeFixture(
        in: root,
        title: "Contract draft",
        date: calendar.date(from: DateComponents(year: 2_026, month: 7, day: 26, hour: 11))!,
        bullets: "",
        notesBody: nil,
        lines: [TranscriptSegment(track: .others, start: 5, end: 9, text: "The pricing annex is attached.")],
        writeNotesFile: false)

    let all = try library.meetings()
    run.equal(all.count, 3, "every meeting folder is a row")
    run.equal(all.first?.title ?? "", pricing.title, "the newest meeting is first")
    run.equal(pricing.notesState.label, "Written", "notes that were written say so")
    run.equal(standup.notesState.label, "Waiting for Spark", "a meeting whose notes failed waits for the Spark")
    run.equal(bare.notesState.label, "Transcript only", "a transcript with no notes beside it says so")
    run.equal(pricing.lengthText, "42 min", "the length is shown in minutes")
    run.expect(pricing.bothSidesRecorded, "a meeting with both tracks says both sides were recorded")

    let hits = try library.search("pricing")
    run.equal(hits.count, 3, "search reaches titles, notes and transcripts")

    let transcriptHit = hits.first { $0.meeting.id == pricing.id }
    run.expect(transcriptHit?.snippet != nil, "a transcript hit brings back a snippet")
    run.equal(transcriptHit?.snippet?.match ?? "", "pricing", "the snippet names what matched")
    run.expect(
        transcriptHit?.snippet?.text.contains("holds at list") ?? false,
        "the snippet carries the words around the match")
    run.expect(transcriptHit?.snippet?.before.hasPrefix("...") ?? false, "a snippet cut at the start says so")
    run.expect(
        !(transcriptHit?.snippet?.text.contains("\n") ?? true), "a snippet is one line")

    let titleOnly = try library.search("standup")
    run.equal(titleOnly.count, 1, "a title hit is a hit on its own")
    run.equal(titleOnly.first?.meeting.title ?? "", "Weekly standup", "the title hit is the right meeting")
    run.expect(titleOnly.first?.snippet == nil, "a title hit needs no snippet, the title is on the row")

    run.equal(try library.search("nothing like this is here").count, 0, "a word nobody said is not a hit")
    run.equal(try library.search("").count, 3, "an empty search shows every meeting")
    run.equal(try library.search("PRICING").count, 3, "search does not care about case")

    // MARK: - Rename

    run.section("Rename and delete")

    let beforeTranscript = try Data(contentsOf: pricing.directory.transcriptURL)
    let beforeNotes = try Data(contentsOf: pricing.directory.notesURL)
    let beforeBullets = try Data(contentsOf: pricing.directory.bulletsURL)

    let renamed = try library.rename(pricing, to: "Reseller pricing")
    run.equal(
        renamed.directory.url.lastPathComponent, "2026-07-28-1600-reseller-pricing",
        "the directory is renamed to match the new title")
    run.expect(
        !FileManager.default.fileExists(atPath: pricing.directory.url.path), "the old directory is gone")
    run.equal(try Data(contentsOf: renamed.directory.transcriptURL), beforeTranscript, "the transcript is untouched")
    run.equal(try Data(contentsOf: renamed.directory.notesURL), beforeNotes, "the notes are untouched")
    run.equal(try Data(contentsOf: renamed.directory.bulletsURL), beforeBullets, "what the owner typed is untouched")
    run.equal(
        try MeetingStore(root: root).readMeta(in: renamed.directory).title, "Reseller pricing",
        "meta.json records the new title")
    run.equal(try library.meetings().count, 3, "a rename does not lose or duplicate a meeting")

    let awkward = try library.rename(renamed, to: "  ../escape: attempt  ")
    run.equal(
        awkward.directory.url.deletingLastPathComponent().standardizedFileURL.path,
        root.standardizedFileURL.path,
        "a title full of path characters cannot move a meeting out of the notes folder")
    run.expect(FileManager.default.fileExists(atPath: awkward.directory.notesURL.path), "the files moved with it")

    // MARK: - Writing the notes again

    run.section("Writing the notes again")

    let bulletsBefore = try Data(contentsOf: standup.directory.bulletsURL)
    let ownerWords = "- do not lose this\n- second bullet"
    try MeetingStore(root: root).writeBullets(ownerWords, to: standup.directory)
    let ownerBytes = try Data(contentsOf: standup.directory.bulletsURL)

    let notesBefore = try Data(contentsOf: standup.directory.notesURL)
    do {
        _ = try await library.rewriteNotes(
            for: standup,
            using: StubGenerator(body: nil, error: .unreachable("http://127.0.0.1:4000/v1")),
            endpoint: "http://127.0.0.1:4000/v1",
            model: "profile/general")
        run.failed("a re-run against an endpoint that does not answer must be reported")
    } catch let error as NotesError {
        run.expect(error.isRetryable, "a re-run that cannot reach the endpoint is retryable")
    }
    run.equal(try Data(contentsOf: standup.directory.notesURL), notesBefore, "a failed re-run leaves the notes alone")

    let rewritten = try await library.rewriteNotes(
        for: standup,
        using: StubGenerator(body: "## Standup\n\nNothing to report [00:00:10].", error: nil),
        endpoint: "http://127.0.0.1:4000/v1",
        model: "profile/general")

    run.equal(rewritten.notesState.label, "Written", "a re-run that answers turns waiting into written")
    run.equal(
        try Data(contentsOf: standup.directory.bulletsURL), ownerBytes,
        "a re-run never changes what the owner typed, byte for byte")
    run.expect(bulletsBefore != ownerBytes, "the byte comparison above is comparing something")

    let after = try String(contentsOf: standup.directory.notesURL, encoding: .utf8)
    run.expect(after.contains("- do not lose this"), "the rewritten notes still carry what the owner typed")
    run.expect(after.contains("Nothing to report"), "the rewritten notes carry what the model wrote")
    run.expect(after.contains("notes_state: written"), "the rewritten notes are recorded as written")
    run.equal(
        try MeetingStore(root: root).readMeta(in: standup.directory).notesState, "written",
        "meta.json agrees with the rewritten notes")

    let reread = library.record(for: rewritten)
    run.equal(reread.bullets, ownerWords, "the owner's words are read from their own file")
    run.equal(reread.ownerLines.count, 2, "each of the owner's lines is shown as its own")

    // MARK: - Delete

    try library.delete(bare)
    run.expect(!FileManager.default.fileExists(atPath: bare.directory.url.path), "delete removes the whole meeting")
    run.equal(try library.meetings().count, 2, "the deleted meeting leaves the library")

    let outside = try Scratch.directory("outside")
    let stranger = MeetingSummary(
        directory: MeetingDirectory(url: outside),
        title: "Not ours",
        startedAt: Date(),
        duration: 0,
        notesState: .transcriptOnly)
    do {
        try library.delete(stranger)
        run.failed("a directory outside the notes folder must not be deleted")
    } catch {
        run.expect(FileManager.default.fileExists(atPath: outside.path), "a directory outside the notes folder is safe")
    }
}

/// The question box, against the same stub endpoint the notes use.
func askChecks(_ run: CheckRun) async {
    run.section("Asking about a meeting")

    let transcript = TranscriptFile.lines(
        markdown: Transcript(
            segments: fixtureSegments, engine: "e", model: "m", recordedAt: Date(), duration: 2_520
        ).markdown(title: "Pricing call"))
    let transcriptText = TranscriptFile.plainText(transcript)

    let client = OpenAICompatibleNotesClient(
        baseURL: "http://127.0.0.1:4000/v1",
        model: "profile/general",
        apiKey: "local-placeholder",
        session: StubEndpoint.session())

    let conversation = AskConversation(title: "Pricing call")

    run.expect(conversation.begin("   ", transcript: transcriptText) == nil, "a blank question is not asked")
    run.expect(!conversation.isAsking, "a blank question does not leave the box waiting")

    StubEndpoint.expect(
        json: """
            {"choices":[{"message":{"content":"No discount was agreed. They tied Q4 volume to list price [00:07:10]."}}]}
            """)

    guard let request = conversation.begin("Did we agree to any discount?", transcript: transcriptText) else {
        run.failed("a real question should be asked")
        return
    }
    run.expect(conversation.isAsking, "the box says it is waiting while the endpoint thinks")
    run.expect(conversation.begin("another one", transcript: transcriptText) == nil, "one question at a time")

    do {
        let answer = try await client.ask(request)
        conversation.finish(answer, for: request)

        run.equal(conversation.turns.count, 1, "the answer joins the history")
        run.equal(conversation.turns.first?.question ?? "", "Did we agree to any discount?", "the question is kept")
        run.expect(!conversation.isAsking, "the box stops waiting once the answer is in")
        run.expect(conversation.failure == nil, "a clean answer leaves no error on screen")

        let anchors = NoteAnchoring.anchor(answer.text, to: transcript)
        run.expect(
            anchors.lines.first?.anchors.first?.lineIndex == 1,
            "an answer's timestamp jumps to the line it rests on")
        run.expect(anchors.unanchored.isEmpty, "an answer anchored to the transcript has nothing unanchored")

        let (sent, body) = StubEndpoint.lastRequest()
        run.equal(
            sent?.url?.absoluteString ?? "", "http://127.0.0.1:4000/v1/chat/completions",
            "a question goes to the same chat completions path as the notes")
        let payload = String(decoding: body ?? Data(), as: UTF8.self)
        run.expect(payload.contains("meeting-ask"), "a question is routed under its own operation name")
        run.expect(payload.contains("Did we agree to any discount?"), "the question is sent")
        run.expect(payload.contains("Q4 volume"), "the transcript is sent with it")
        run.expect(payload.contains("Answer only from the transcript"), "the answer is held to the transcript")
        run.expect(!payload.contains("RIFF") && !payload.contains(".wav"), "audio is never sent")
    } catch {
        run.failed("a clean question should not throw: \(error.localizedDescription)")
    }

    // The endpoint is off.
    StubEndpoint.expectFailure(URLError(.cannotConnectToHost))
    guard let refused = conversation.begin("And the renewal date?", transcript: transcriptText) else {
        run.failed("a second question should be asked")
        return
    }
    do {
        let answer = try await client.ask(refused)
        conversation.finish(answer, for: refused)
        run.failed("a refused connection must be reported")
    } catch {
        conversation.fail(error)
    }

    run.expect(!conversation.isAsking, "a refused connection does not leave the box waiting forever")
    run.equal(conversation.turns.count, 1, "a refused connection does not invent an answer")
    run.expect(conversation.failure != nil, "a refused connection is said out loud")
    run.expect(
        conversation.failure?.contains("did not answer") ?? false,
        "the message is the app's own plain one about the endpoint")

    // And the box works again afterwards.
    StubEndpoint.expect(json: "{\"choices\":[{\"message\":{\"content\":\"October [00:07:31].\"}}]}")
    guard let again = conversation.begin("And the renewal date?", transcript: transcriptText) else {
        run.failed("the box should take another question after a failure")
        return
    }
    do {
        conversation.finish(try await client.ask(again), for: again)
        run.equal(conversation.turns.count, 2, "the history keeps both answers")
        run.expect(conversation.failure == nil, "a good answer clears the last error")
    } catch {
        run.failed("the box should recover after a failure: \(error.localizedDescription)")
    }
}
