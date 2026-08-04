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

        var segments: [TranscriptSegment] = []
        var duration: TimeInterval = 0
        var totalProcessing: TimeInterval = 0
        var totalAudio: TimeInterval = 0

        for capture in captures {
            duration = max(duration, capture.duration)
            log(capture.summary)

            if capture.signal.isAllZero {
                log("Skipping transcription of the \(capture.track.label) track because it contains no signal.")
                continue
            }

            // Move the recording into the meeting folder before anything else
            // touches it.
            let destination = directory.audioURL(for: capture.track)
            if capture.fileURL != destination {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: capture.fileURL, to: destination)
            }

            log("Transcribing the \(capture.track.label) track on this Mac.")
            let output = try await transcriber.transcribe(fileAt: destination, track: capture.track)
            segments.append(contentsOf: output.segments)
            totalProcessing += output.processingTime
            totalAudio += output.audioDuration
            let factor = output.realtimeFactor
            if factor > 0 {
                log(String(format: "Transcribed %@ in %.1f s, %.0f times faster than real time.",
                           Timecode.string(from: output.audioDuration), output.processingTime, factor))
            }
        }

        let transcript = Transcript(
            segments: segments,
            engine: transcriber.engineName,
            model: transcriber.modelName,
            recordedAt: startedAt,
            duration: duration,
            missingTracks: missingTracks
        )
        try store.writeTranscript(transcript, title: title, to: directory)
        log("Transcript written.")

        var notesBody: String?
        var pendingReason: String?

        if transcript.segments.isEmpty {
            pendingReason = "No speech was recognised, so no notes were requested."
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
            tracksRecorded: captures.map { $0.track.rawValue },
            tracksMissing: missingTracks.map { $0.rawValue },
            audioKept: settings.keepAudioAfterTranscription,
            syncService: store.syncService
        )
        try store.writeMeta(meta, to: directory)

        // Audio goes unless the owner asked to keep it, and only once the
        // transcript is on disk.
        if !settings.keepAudioAfterTranscription && !transcript.segments.isEmpty {
            try store.deleteAudio(in: directory)
            log("Audio deleted. The transcript is what remains.")
        } else if settings.keepAudioAfterTranscription {
            log("Audio kept, because the setting says to keep it.")
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
