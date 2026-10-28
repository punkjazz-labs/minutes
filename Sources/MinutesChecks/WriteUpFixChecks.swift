import Foundation
import MinutesCore

/// A speech engine that hears no words in audio that carried sound, which is
/// what music, or speech it cannot read, produces.
private struct HearsNothing: Transcribing {
    let engineName = "FluidAudio Parakeet TDT (fake)"
    let modelName = "parakeet-tdt-0.6b-v3-coreml"
    func modelsAreReady() -> Bool { true }
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}
    func transcribe(fileAt url: URL, track: AudioTrack) async throws -> TranscriptionOutput {
        TranscriptionOutput(segments: [], audioDuration: 1, processingTime: 0.01)
    }
}

private struct OddFailure: Error, LocalizedError {
    var errorDescription: String? { "the endpoint failed in a way nobody planned for" }
}

/// An endpoint that fails with an error that is not one of the notes errors.
private struct OddlyFailingNotes: NotesGenerating {
    func enhance(_ request: NotesRequest) async throws -> NotesResult { throw OddFailure() }
    func probeModels() async throws -> [String] { [] }
}

private struct AnsweringNotes: NotesGenerating {
    func enhance(_ request: NotesRequest) async throws -> NotesResult {
        NotesResult(markdown: "## Notes\n\n- fine", model: "profile/general", endpoint: "http://127.0.0.1:4000/v1")
    }
    func probeModels() async throws -> [String] { ["profile/general"] }
}

private func stagedTone(in directory: URL) throws -> CaptureResult {
    let capture = FixtureCapture(
        track: .me, samples: (0..<16_000).map { Float(sin(Double($0) * 0.01)) * 0.3 })
    try capture.start(writingTo: directory.appendingPathComponent("tone-\(UUID().uuidString).wav"))
    return try capture.stop()
}

private func hasAudio(_ directory: MeetingDirectory) -> Bool {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.audioDirectory.path)) ?? []
    return !files.isEmpty
}

/// The write-up, the endpoint and the privacy claim, held to what actually
/// happened.
func writeUpFixChecks(_ run: CheckRun) async throws {
    run.section("What meta.json says about the audio is what happened to it")

    // Sound, and no words found in it.
    do {
        let root = try Scratch.directory("no-words")
        let outcome = try await MeetingPipeline(
            settings: AppSettings(notesFolderPath: root.path),
            store: MeetingStore(root: root),
            transcriber: HearsNothing(),
            notes: AnsweringNotes()
        ).run(
            title: "Music only", startedAt: Date(), ownerNotes: "",
            captures: [try stagedTone(in: root)], missingTracks: [.others])

        let meta = try MeetingStore(root: root).readMeta(in: outcome.directory)
        run.expect(hasAudio(outcome.directory), "a recording in which no words were found is kept, because it is all there is")
        run.equal(meta.audioKept, hasAudio(outcome.directory), "meta.json says the audio was kept when it was")
        run.expect(
            outcome.events.contains { $0.message.contains("no speech was recognised") },
            "the activity log says why the audio was kept")
    }

    // Words found: the audio goes, and meta.json says so.
    do {
        let root = try Scratch.directory("words")
        let outcome = try await MeetingPipeline(
            settings: AppSettings(notesFolderPath: root.path),
            store: MeetingStore(root: root),
            transcriber: FixtureTranscriber(
                segments: [TranscriptSegment(track: .me, start: 0, end: 1, text: "Hello there.")], audioDuration: 1),
            notes: AnsweringNotes()
        ).run(
            title: "Words", startedAt: Date(), ownerNotes: "",
            captures: [try stagedTone(in: root)], missingTracks: [.others])
        let meta = try MeetingStore(root: root).readMeta(in: outcome.directory)
        run.expect(!hasAudio(outcome.directory), "audio is deleted once there is a transcript, as the setting says")
        run.equal(meta.audioKept, hasAudio(outcome.directory), "meta.json says the audio went when it went")
    }

    run.section("Any endpoint failure costs the notes and nothing else")

    do {
        let root = try Scratch.directory("odd-failure")
        let outcome = try await MeetingPipeline(
            settings: AppSettings(notesFolderPath: root.path),
            store: MeetingStore(root: root),
            transcriber: FixtureTranscriber(
                segments: [TranscriptSegment(track: .me, start: 0, end: 1, text: "Hello there.")], audioDuration: 1),
            notes: OddlyFailingNotes()
        ).run(
            title: "Odd", startedAt: Date(), ownerNotes: "- keep me",
            captures: [try stagedTone(in: root)], missingTracks: [.others])

        run.expect(outcome.notesArePending, "an unexpected failure leaves the notes waiting")
        run.expect(
            FileManager.default.fileExists(atPath: outcome.directory.metaURL.path),
            "meta.json is still written")
        let notes = try String(contentsOf: outcome.directory.notesURL, encoding: .utf8)
        run.expect(notes.contains("nobody planned for"), "notes.md says what the endpoint did")
        run.expect(notes.contains("keep me"), "notes.md still keeps what was typed")
    }

    run.section("A failed connection says what failed")

    func client(_ base: String = "http://example.lan:4000/v1") -> OpenAICompatibleNotesClient {
        OpenAICompatibleNotesClient(
            baseURL: base, model: "profile/general", apiKey: "local-placeholder", timeout: 300,
            session: StubEndpoint.session())
    }

    func failure(for code: URLError.Code) async -> NotesError? {
        StubEndpoint.expectFailure(URLError(code))
        do {
            _ = try await client().enhance(NotesRequest(title: "T", ownerNotes: "", transcript: "x"))
            return nil
        } catch {
            return error as? NotesError
        }
    }

    if let refused = await failure(for: .appTransportSecurityRequiresSecureConnection) {
        run.expect(refused.localizedDescription.contains("macOS blocked"), "macOS refusing plain http is named as that")
        run.expect(!refused.localizedDescription.contains("did not answer"), "and is not blamed on the machine")
        run.expect(!refused.isRetryable, "a refusal on this Mac is not retried as if the machine were off")
    } else {
        run.failed("a plain http refusal should be a notes error")
    }
    if let slow = await failure(for: .timedOut) {
        run.expect(slow.localizedDescription.contains("timed out"), "a timeout is called a timeout")
        run.expect(slow.isRetryable, "a timeout is retryable")
    } else {
        run.failed("a timeout should be a notes error")
    }
    if let tls = await failure(for: .secureConnectionFailed) {
        run.expect(tls.localizedDescription.contains("secure connection"), "a TLS failure is named as one")
        run.expect(!tls.localizedDescription.contains("did not answer"), "and is not blamed on the machine")
        run.expect(!tls.isRetryable, "a certificate problem is not retried as if the machine were off")
    } else {
        run.failed("a TLS failure should be a notes error")
    }
    if let off = await failure(for: .cannotConnectToHost) {
        run.expect(off.localizedDescription.contains("did not answer"), "a machine that is off is still called that")
    } else {
        run.failed("a refused connection should be a notes error")
    }

    run.section("The privacy claim says only what minutes knows")

    let local = PrivacyClaim.text(endpoint: "http://127.0.0.1:4000/v1", syncService: nil)
    run.expect(local.contains("minutes sends nothing to any other service"), "the claim speaks for minutes")
    run.expect(
        local.contains("set by the endpoint, not by minutes"),
        "the claim does not speak for the gateway, which decides where the transcript goes next")
    run.expect(!local.contains("unencrypted"), "plain http to this Mac is not called unencrypted network traffic")
    run.expect(
        PrivacyClaim.text(endpoint: "http://192.168.1.129:4000/v1", syncService: nil).contains("unencrypted"),
        "plain http to another machine says the transcript crosses the network unencrypted")
    run.expect(
        !PrivacyClaim.text(endpoint: "https://gateway.example/v1", syncService: nil).contains("unencrypted"),
        "https is not called unencrypted")
    run.expect(!PrivacyClaim.isPlainHTTPToAnotherMachine("http://localhost:4000/v1"), "localhost is this Mac")
}
