import Foundation

/// What happened, in the order it happened, in sentences fit to show the owner.
public struct PipelineEvent: Sendable, Equatable {
    public let message: String
    public let at: Date

    public init(message: String, at: Date = Date()) {
        self.message = message
        self.at = at
    }
}

public struct PipelineOutcome: Sendable {
    public let directory: MeetingDirectory
    public let transcript: Transcript
    public let notes: String?
    public let notesPendingReason: String?
    public let events: [PipelineEvent]

    public var notesArePending: Bool { notes == nil }
}

/// Turns finished recordings into a meeting directory: transcribe each track,
/// merge, write the transcript, ask for notes, write the notes or record that
/// they are waiting, write meta, and delete the audio unless the owner keeps it.
///
/// The transcript is written before the endpoint is called, so a machine being
/// off costs the notes and never the meeting.
public struct MeetingPipeline: Sendable {

    private let store: MeetingStore
    private let transcriber: any Transcribing
    private let notes: any NotesGenerating
    private let settings: AppSettings

    public init(
        settings: AppSettings,
        store: MeetingStore,
        transcriber: any Transcribing,
        notes: any NotesGenerating
    ) {
        self.settings = settings
        self.store = store
        self.transcriber = transcriber
        self.notes = notes
    }

    public func run(
        title: String,
        startedAt: Date,
        ownerNotes: String,
        captures: [CaptureResult],
        missingTracks: [AudioTrack] = [],
        report: (@Sendable (String) -> Void)? = nil
    ) async throws -> PipelineOutcome {

        var events: [PipelineEvent] = []
        func log(_ message: String) {
            events.append(PipelineEvent(message: message))
            report?(message)
        }

        let directory = try store.createMeeting(title: title, date: startedAt)
        log("Meeting folder created at \(directory.url.lastPathComponent).")

        // Written before anything else can fail, and never written again.
        try store.writeBullets(ownerNotes, to: directory)

        var segments: [TranscriptSegment] = []
        var duration: TimeInterval = 0
        var totalProcessing: TimeInterval = 0
        var totalAudio: TimeInterval = 0
        var silentTracks: [AudioTrack] = []
        var recordedTracks: [AudioTrack] = []
        var failedTracks: [TrackFailure] = []

        for capture in captures {
            duration = max(duration, capture.duration)
            log(capture.summary)
            // What the source had to do while it recorded, such as rebuilding a
            // tap that went quiet, belongs in the same log as everything else.
            for note in capture.notes { log(note) }

            if capture.signal.isAllZero {
                silentTracks.append(capture.track)
                log("Skipping transcription of the \(capture.track.label) track because it contains no signal.")
                // A silent file next to a real one looks like a recording that
                // heard nothing. It is discarded and named instead.
                try? FileManager.default.removeItem(at: capture.fileURL)
                log("The \(capture.track.label) recording was discarded rather than saved as a silent file.")
                continue
            }
            recordedTracks.append(capture.track)

            // Move the recording into the meeting folder before anything else
            // touches it.
            let destination = directory.audioURL(for: capture.track)
            if capture.fileURL != destination {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: capture.fileURL, to: destination)
            }

            log("Transcribing the \(capture.track.label) track on this Mac.")
            do {
                let output = try await transcriber.transcribe(fileAt: destination, track: capture.track)
                segments.append(contentsOf: output.segments)
                totalProcessing += output.processingTime
                totalAudio += output.audioDuration
                let factor = output.realtimeFactor
                if factor > 0 {
                    log(String(format: "Transcribed %@ in %.1f s, %.0f times faster than real time.",
                               Timecode.string(from: output.audioDuration), output.processingTime, factor))
                }
            } catch {
                // The speech engine refusing costs the words of this track. It
                // must not cost the meeting. The recording is already in the
                // meeting folder, so the refusal is written down, the audio is
                // kept whatever the delete setting says, and every step below
                // still runs. A meeting that is not written up at all is a
                // meeting the library cannot show and the owner cannot reach.
                failedTracks.append(TrackFailure(track: capture.track, reason: error.localizedDescription))
                log("The \(capture.track.label) track could not be transcribed: \(error.localizedDescription)")
                log("The recording of that track was kept, so it can be transcribed again.")
            }
        }

        let transcript = Transcript(
            segments: segments,
            engine: transcriber.engineName,
            model: transcriber.modelName,
            recordedAt: startedAt,
            duration: duration,
            missingTracks: missingTracks,
            silentTracks: silentTracks,
            failedTracks: failedTracks
        )
        try store.writeTranscript(transcript, title: title, to: directory)
        log("Transcript written.")

        var notesBody: String?
        var pendingReason: String?

        if transcript.segments.isEmpty {
            pendingReason =
                failedTracks.isEmpty
                ? "No speech was recognised, so no notes were requested."
                : "The speech engine could not read this meeting, so no notes were requested. The audio was kept."
            log(pendingReason!)
        } else {
            log("Sending the transcript to \(settings.notesBaseURL) as \(settings.notesModel).")
            do {
                let result = try await notes.enhance(
                    NotesRequest(title: title, ownerNotes: ownerNotes, transcript: transcript.plainText))
                notesBody = result.markdown
                log("Notes written.")
            } catch let error as NotesError {
                pendingReason = error.localizedDescription
                log(pendingReason!)
            }
        }

        try store.writeNotes(
            title: title,
            date: startedAt,
            duration: duration,
            ownerNotes: ownerNotes,
            body: notesBody,
            pendingReason: pendingReason,
            transcriptionEngine: transcriber.engineName,
            transcriptionModel: transcriber.modelName,
            notesEndpoint: settings.notesBaseURL,
            notesModel: settings.notesModel,
            to: directory
        )

        let meta = MeetingMeta(
            title: title,
            startedAt: startedAt,
            durationSeconds: duration,
            transcriptionEngine: transcriber.engineName,
            transcriptionModel: transcriber.modelName,
            transcriptionRealtimeFactor: totalProcessing > 0 ? totalAudio / totalProcessing : nil,
            notesEndpoint: settings.notesBaseURL,
            notesModel: settings.notesModel,
            notesState: notesBody == nil ? "pending" : "written",
            tracksRecorded: recordedTracks.map { $0.rawValue },
            tracksMissing: missingTracks.map { $0.rawValue },
            tracksSilent: silentTracks.map { $0.rawValue },
            tracksNotTranscribed: failedTracks.map { $0.track.rawValue },
            transcriptionFailureReason: failedTracks.first?.reason,
            audioKept: settings.keepAudioAfterTranscription || !failedTracks.isEmpty,
            syncService: store.syncService
        )
        try store.writeMeta(meta, to: directory)

        // Audio goes unless the owner asked to keep it, and only once the
        // transcript is on disk. A track the speech engine refused has no
        // transcript, so its recording is the only record of it and it stays.
        if !settings.keepAudioAfterTranscription && !transcript.segments.isEmpty && failedTracks.isEmpty {
            try store.deleteAudio(in: directory)
            log("Audio deleted. The transcript is what remains.")
        } else if settings.keepAudioAfterTranscription {
            log("Audio kept, because the setting says to keep it.")
        } else if !failedTracks.isEmpty {
            log("Audio kept, because the speech engine could not read it and the recording is all there is.")
        }

        return PipelineOutcome(
            directory: directory,
            transcript: transcript,
            notes: notesBody,
            notesPendingReason: pendingReason,
            events: events
        )
    }
}
