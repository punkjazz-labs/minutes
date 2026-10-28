import AppKit
import Foundation
import MinutesCore
import SwiftUI

/// Drives one meeting: start both tracks, keep the meter honest while they
/// run, then hand the recordings to the pipeline.
@MainActor
final class RecordingController: ObservableObject {

    /// The phase, and the only changes to it that are allowed, live in
    /// `MinutesCore`, so the rule that a second Record press can never start a
    /// second recording is a rule the checks can drive.
    @Published private(set) var state = RecordingState()
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var capturedSilence = false
    @Published private(set) var systemAudioSilence = false
    @Published private(set) var log: [String] = []
    @Published private(set) var lastMeetingURL: URL?
    @Published private(set) var modelReady: Bool
    @Published private(set) var modelDownloadProgress: Double?
    @Published private(set) var microphonePermission: MicrophoneCapture.PermissionState
    @Published private(set) var userError: String?
    @Published private(set) var completionNotice: String?
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var isTestingEndpoint = false
    @Published private(set) var settingsMessage: String?
    @Published private(set) var microphoneStarved = false
    @Published private(set) var systemAudioStarved = false
    /// Recordings an earlier run left behind without writing them up.
    @Published private(set) var recoverable: [RecoverableRecording] = []
    /// Meetings being written up in the background, oldest first. Recording
    /// the next meeting does not wait for them.
    @Published private(set) var writingUp: [RunningWriteUp] = []

    struct RunningWriteUp: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// What the owner typed for the meeting being recorded now, or for the one
    /// about to be recorded. Kept on disk with the recording while it runs,
    /// and cleared when Stop hands it to the write-up.
    @Published var draft = MeetingDraft()
    @Published var settings: AppSettings
    @Published var apiKeyField: String = ""
    @Published var endpointStatus: String?

    private let settingsStore: any SettingsStoring
    private let keyStore: any APIKeyStoring
    private let microphone = MicrophoneCapture()
    private let systemAudio = SystemAudioCapture()
    private var transcriber: FluidAudioTranscriber
    private var ticker: Timer?
    private var startedAt: Date?
    private let sessionsRoot: URL
    /// The meeting being recorded, kept where a crash cannot take it.
    private var session: RecordingSession?
    private var savedDraft = MeetingDraft()
    private var systemAudioRunning = false
    private var systemNotesShown = 0
    private var microphoneNotesShown = 0
    private var lastMicrophoneFrames = 0
    private var lastSystemFrames = 0
    /// Settings, transcriber, and notes client captured before the first await
    /// of a start, so the pipeline runs against what the meeting began with.
    private var sessionSettings: AppSettings?
    private var sessionTranscriber: FluidAudioTranscriber?
    private var sessionNotes: OpenAICompatibleNotesClient?
    private var activeDownloadID: UUID?
    /// The title the controller generated for the current draft, so the
    /// generated value can be refreshed without overwriting a title the
    /// owner typed themselves.
    private var generatedDraftTitle = ""

    private let firstRunKey = "minutes.firstRunNoticeAcknowledged"

    init(
        settingsStore: any SettingsStoring = UserDefaultsSettingsStore(),
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        sessionsRoot: URL = RecordingSession.defaultRoot
    ) {
        self.settingsStore = settingsStore
        self.keyStore = keyStore
        self.sessionsRoot = sessionsRoot
        let loaded = settingsStore.load()
        self.settings = loaded
        self.transcriber = FluidAudioTranscriber(model: loaded.asrModel)
        self.modelReady = FluidAudioTranscriber(model: loaded.asrModel).modelsAreReady()
        self.apiKeyField = keyStore.readKey() ?? ""
        self.microphonePermission = MicrophoneCapture.permissionState
        refreshDraftTitle()
        refreshRecoverable()
    }

    // MARK: - Permissions and settings locking

    func refreshPermissions() {
        let oldPermission = microphonePermission
        microphonePermission = MicrophoneCapture.permissionState
        if microphonePermission == .granted,
            oldPermission == .denied || oldPermission == .restricted,
            let error = userError,
            error.lowercased().contains("microphone")
        {
            userError = nil
        }
        objectWillChange.send()
    }

    func openMicrophoneSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        {
            NSWorkspace.shared.open(url)
        }
    }

    var microphoneBlocked: Bool {
        microphonePermission == .denied || microphonePermission == .restricted
    }

    var settingsLocked: Bool {
        state.phase == .starting || state.isRecording || state.phase.isBusy
            || modelDownloadProgress != nil || !writingUp.isEmpty
    }

    // MARK: - Facts shown on screen

    var phase: RecordingPhase { state.phase }
    var isRecording: Bool { state.isRecording }

    /// What to say about the other side of the meeting. Before recording this
    /// is how the permission works, because macOS never reports it. While
    /// recording it is what the track has actually carried so far, which is the
    /// only honest thing an app can say about a tap.
    var systemAudioNotice: String? {
        if let reason = systemAudio.unavailableReason { return reason }
        guard isRecording else { return SystemAudioCapture.permissionNotice }
        guard systemAudioRunning else {
            return
                "The system audio tap is not running, so only your side of this meeting is being recorded."
        }
        if systemAudioStarved {
            return "The system audio tap stopped delivering audio. minutes is rebuilding it."
        }
        if systemAudioSilence {
            return
                "Nothing has been heard from the other side yet. That is either a quiet meeting or a permission macOS never granted, and minutes cannot tell which until something is heard."
        }
        return nil
    }

    var microphoneNotice: String? { microphone.unavailableReason }

    var store: MeetingStore { MeetingStore(settings: settings) }

    var privacyClaim: String {
        PrivacyClaim.text(endpoint: settings.notesBaseURL, syncService: store.syncService)
    }

    var syncWarning: String? { store.syncWarning }

    var firstRunNoticeNeeded: Bool {
        #if DEBUG
        if let firstRunOverride { return firstRunOverride }
        #endif
        return !UserDefaults.standard.bool(forKey: firstRunKey)
    }

    #if DEBUG
    /// Set only by the snapshot renderer, so a picture never depends on what
    /// this Mac's defaults happen to hold.
    private var firstRunOverride: Bool?
    #endif

    func acknowledgeFirstRunNotice() {
        UserDefaults.standard.set(true, forKey: firstRunKey)
        objectWillChange.send()
    }

    var statusLine: String {
        switch phase {
        case .idle:
            if microphoneBlocked {
                return "Microphone access blocked"
            }
            if let error = userError { return error }
            if !modelReady { return "Download the speech model in Settings" }
            if let writing = writingUpLine { return writing }
            if let notice = completionNotice { return notice }
            return "Ready"
        case .starting:
            return "Starting…"
        case .recording:
            if microphoneStarved { return "No audio from the microphone · reopening it" }
            return capturedSilence ? "No microphone signal" : "Recording"
        case .working:
            return "Processing…"
        case .finished:
            if let writing = writingUpLine { return writing }
            if let notice = completionNotice { return notice }
            if let error = userError { return error }
            return "Saved"
        }
    }

    /// What is being written up behind the next meeting, if anything.
    private var writingUpLine: String? {
        guard let first = writingUp.first else { return nil }
        return writingUp.count == 1
            ? "Writing up \u{201C}\(first.title)\u{201D}…"
            : "Writing up \(writingUp.count) meetings…"
    }

    // MARK: - Settings

    func saveSettings() {
        guard !settingsLocked else {
            settingsMessage = "Settings are locked while processing"
            return
        }
        var candidate = settings
        candidate.notesBaseURL = candidate.notesBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.notesModel = candidate.notesModel.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.notesFolderPath = candidate.notesFolderPath.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let problems = candidate.problems
        guard problems.isEmpty else {
            settingsMessage = "Check settings: " + problems.joined(separator: " ")
            return
        }
        let previousModel = settingsStore.load().asrModel
        settings = candidate
        settingsStore.save(candidate)
        // The transcriber is only rebuilt when the chosen model changed; a
        // rebuild would otherwise drop a loaded model for nothing.
        if candidate.asrModel != previousModel {
            transcriber = FluidAudioTranscriber(model: candidate.asrModel)
            modelReady = transcriber.modelsAreReady()
        }
        endpointStatus = nil
        if userError == "Save valid settings in Settings before recording." { userError = nil }
        settingsMessage = "Settings saved."
        objectWillChange.send()
    }

    func saveAPIKey() {
        do {
            let trimmed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try keyStore.deleteKey()
                endpointStatus = "Key cleared"
            } else {
                try keyStore.writeKey(trimmed)
                endpointStatus = "Key saved"
            }
        } catch {
            endpointStatus = error.localizedDescription
        }
    }

    func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.notesFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.notesFolderPath = url.path
            saveSettings()
        }
    }

    func openNotesFolder() {
        let url = lastMeetingURL ?? settings.notesFolderURL
        try? FileManager.default.createDirectory(
            at: settings.notesFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func testEndpoint() {
        guard !isTestingEndpoint else { return }
        let problems = settings.problems
        guard problems.isEmpty else {
            settingsMessage =
                "Fix the settings before testing the endpoint: " + problems.joined(separator: " ")
            return
        }
        let client = notesClient()
        let wanted = settings.notesModel
        let baseURL = settings.notesBaseURL
        isTestingEndpoint = true
        endpointStatus = "Checking connection…"
        Task { @MainActor in
            defer { isTestingEndpoint = false }
            do {
                let models = try await client.probeModels()
                // The result only stands for the settings it was asked about.
                guard settings.notesBaseURL == baseURL, settings.notesModel == wanted else { return }
                if models.contains(wanted) {
                    endpointStatus = "Connected"
                } else {
                    endpointStatus = "Model unavailable"
                }
            } catch {
                guard settings.notesBaseURL == baseURL, settings.notesModel == wanted else { return }
                endpointStatus = error.localizedDescription
            }
        }
    }

    func downloadModel() {
        guard !settingsLocked, modelDownloadProgress == nil else { return }
        saveSettings()
        guard settings == settingsStore.load(), settings.problems.isEmpty else { return }
        let choice = settings.asrModel
        let downloadID = UUID()
        activeDownloadID = downloadID
        modelDownloadProgress = 0
        Task { @MainActor in
            do {
                _ = try await FluidAudioTranscriber.downloadModels(choice) { fraction in
                    Task { @MainActor in
                        guard self.activeDownloadID == downloadID else { return }
                        self.modelDownloadProgress = fraction
                    }
                }
                activeDownloadID = nil
                modelDownloadProgress = nil
                // Only replace the transcriber if the owner still wants the
                // model that finished downloading.
                if settings.asrModel == choice {
                    transcriber = FluidAudioTranscriber(model: choice)
                    modelReady = transcriber.modelsAreReady()
                    userError = nil
                }
                append("Speech model downloaded.")
            } catch {
                activeDownloadID = nil
                modelDownloadProgress = nil
                userError = "The speech model did not download: \(error.localizedDescription)"
                append(userError!)
            }
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopAndWriteUp()
        } else {
            start()
        }
    }

    func start() {
        // Setup gates run before the start slot is claimed, so no permission
        // prompt or state change happens while the meeting cannot begin.
        guard phase == .idle || phase == .finished else { return }
        if modelDownloadProgress != nil {
            userError = "Wait for the speech model download to finish."
            return
        }
        guard settings.problems.isEmpty, settings == settingsStore.load() else {
            userError = "Save valid settings in Settings before recording."
            return
        }
        modelReady = transcriber.modelsAreReady()
        if !modelReady {
            userError = "Download the speech model in Settings before recording."
            return
        }
        // The slot is taken here, synchronously, in the same run of main actor
        // code that decided to take it. Opening a device is asynchronous, so a
        // phase written after the devices are open would leave a gap in which a
        // second Record press reads the same idle phase and starts a second
        // recording against the same two sources. `claimStart` cannot be
        // separated that way: it does not open anything and there is nothing
        // inside it to await.
        guard state.claimStart() else { return }
        refreshDraftTitle()
        // Snapshot everything the meeting will use before any await, so a
        // settings change mid-meeting cannot swap the engine under it.
        sessionSettings = settings
        sessionTranscriber = transcriber
        sessionNotes = notesClient()
        userError = nil
        completionNotice = nil
        systemLevel = 0
        log = []
        capturedSilence = false
        microphoneStarved = false
        systemAudioSilence = false
        systemAudioStarved = false
        systemNotesShown = 0
        microphoneNotesShown = 0
        lastMicrophoneFrames = 0
        lastSystemFrames = 0
        elapsed = 0
        level = 0

        Task { @MainActor in
            if MicrophoneCapture.permissionState == .undetermined {
                _ = await MicrophoneCapture.requestPermission()
            }
            refreshPermissions()
            // A recording that predictably cannot be transcribed is not
            // started, and the reason is said rather than left silent.
            if microphoneBlocked {
                userError =
                    "The microphone is blocked. Allow minutes in System Settings > Privacy & Security > Microphone, then try again."
                state.startFailed()
                return
            }
            guard modelReady else {
                userError =
                    "The speech model is not downloaded yet. Open settings, download it, then record."
                state.startFailed()
                return
            }
            // The recording goes where a crash cannot take it: its own folder
            // under Application Support, with the title and the notes kept
            // beside it as they are typed. The next launch offers back any
            // recording that was never written up.
            let begun: RecordingSession
            do {
                begun = try RecordingSession.begin(in: sessionsRoot, startedAt: Date(), draft: draft)
            } catch {
                userError = "Recording did not start: there was nowhere to keep it. \(error.localizedDescription)"
                append(userError!)
                state.startFailed()
                return
            }
            do {
                try microphone.start(writingTo: begun.audioURL(for: .me))
                session = begun
                savedDraft = draft
                startedAt = (try? begun.manifest().startedAt) ?? Date()
                state.startSucceeded()
                append("Recording started.")
                startTicker()
            } catch {
                try? begun.discard()
                userError = "Recording did not start: \(error.localizedDescription)"
                append(userError!)
                state.startFailed()
                return
            }
            let systemURL = begun.audioURL(for: .others)

            // The other side is a separate track and a separate risk. If the
            // tap will not start, the meeting still gets recorded, and the log
            // says which half it has.
            do {
                try systemAudio.start(writingTo: systemURL)
                systemAudioRunning = true
                append(
                    "Recording what this Mac plays as well, so the other side of the meeting is on its own track."
                )
            } catch {
                systemAudioRunning = false
                append("System audio did not start: \(error.localizedDescription)")
                append("Only your side of this meeting is being recorded.")
            }
        }
    }

    func stopAndWriteUp() {
        // The stop is claimed the same way the start is, so a second Stop press
        // cannot run the pipeline twice over one pair of recordings.
        guard state.claimStop() else { return }
        stopTicker()

        // Both sources are stopped before anything here can return. A tap left
        // running by a failed stop records what this Mac plays with the record
        // dot already off, which is the one thing the menu bar promises cannot
        // happen.
        let stopped = MeetingStop.everything(
            microphone: microphone,
            systemAudio: systemAudioRunning ? systemAudio : nil)
        systemAudioRunning = false
        microphoneStarved = false
        systemAudioStarved = false
        level = 0
        systemLevel = 0
        for line in stopped.failures { append(line) }

        let session = self.session
        self.session = nil
        if let session { try? session.save(draft: draft) }

        // Without the owner's own track there is no meeting to write up now.
        // Whatever was recorded stays in its session and is offered back.
        guard stopped.ownCapture != nil else {
            userError =
                "No microphone capture was recorded, so there is no meeting to write up. Your draft is kept."
            state.abandon()
            refreshRecoverable()
            return
        }

        let meetingTitle = draft.meetingTitle(or: defaultTitle())
        let started = startedAt ?? Date()
        let ownerNotes = draft.bullets
        let pipelineSettings = sessionSettings ?? settings
        let pipelineTranscriber = sessionTranscriber ?? transcriber
        let pipelineNotes = sessionNotes ?? notesClient()
        // The pipeline now holds the session's settings, transcriber, and
        // client in its own captured locals, so the controller's snapshots
        // can go. They are cleared here and not earlier, because they are
        // read up to this point.
        sessionSettings = nil
        sessionTranscriber = nil
        sessionNotes = nil

        // The title and the notes are on disk with the recording, and the
        // write-up takes them from here, so they do not carry into the next
        // meeting. The slot is free at once: the next meeting does not wait
        // for this one's notes. A write-up that fails keeps both, with the
        // recording, and offers them back.
        draft.clearAfterWriteUp()
        savedDraft = MeetingDraft()
        refreshDraftTitle()
        state.finish()

        runWriteUp(
            id: session?.id ?? UUID().uuidString,
            title: meetingTitle,
            startedAt: started,
            ownerNotes: ownerNotes,
            captures: stopped.captures,
            missingTracks: stopped.missingTracks,
            session: session,
            settings: pipelineSettings,
            transcriber: pipelineTranscriber,
            notes: pipelineNotes)
    }

    // MARK: - Interrupted recordings

    /// Looks for recordings an earlier run left behind. The one recording now
    /// and the ones being written up are never offered.
    func refreshRecoverable() {
        let root = sessionsRoot
        var live = Set(writingUp.map(\.id))
        if let session { live.insert(session.id) }
        Task { @MainActor in
            let found = await Task.detached {
                RecordingSession.leftovers(in: root, excluding: live).compactMap(RecoverableRecording.read)
            }.value
            let stillLive = Set(writingUp.map(\.id))
            recoverable = found.filter { !stillLive.contains($0.id) && $0.id != session?.id }
        }
    }

    /// Writes an interrupted recording up, with the title and the notes that
    /// were typed for it, under the time it started.
    func recover(_ item: RecoverableRecording) {
        recoverable.removeAll { $0.id == item.id }
        let captures = item.session.captures()
        guard !captures.isEmpty else {
            try? item.session.discard()
            append("Nothing was left of that recording to write up, so it was cleared away.")
            return
        }
        runWriteUp(
            id: item.id,
            title: item.title(defaultFormatter: { self.defaultTitle(for: $0) }),
            startedAt: item.manifest.startedAt,
            ownerNotes: item.manifest.bullets,
            captures: captures,
            missingTracks: item.missingTracks,
            session: item.session,
            settings: settings,
            transcriber: transcriber,
            notes: notesClient())
    }

    /// Deletes an interrupted recording the owner chose to throw away.
    func discard(_ item: RecoverableRecording) {
        do {
            try item.session.discard()
            append("The interrupted recording was deleted.")
        } catch {
            userError = "The interrupted recording could not be deleted: \(error.localizedDescription)"
        }
        refreshRecoverable()
    }

    private func runWriteUp(
        id: String,
        title: String,
        startedAt: Date,
        ownerNotes: String,
        captures: [CaptureResult],
        missingTracks: [AudioTrack],
        session: RecordingSession?,
        settings pipelineSettings: AppSettings,
        transcriber pipelineTranscriber: FluidAudioTranscriber,
        notes pipelineNotes: OpenAICompatibleNotesClient
    ) {
        writingUp.removeAll { $0.id == id }
        writingUp.append(RunningWriteUp(id: id, title: title))
        completionNotice = nil

        let pipeline = MeetingPipeline(
            settings: pipelineSettings,
            store: MeetingStore(settings: pipelineSettings),
            transcriber: pipelineTranscriber,
            notes: pipelineNotes
        )

        Task { @MainActor in
            defer { writingUp.removeAll { $0.id == id } }
            do {
                try FileManager.default.createDirectory(
                    at: pipelineSettings.notesFolderURL, withIntermediateDirectories: true)

                let outcome = try await pipeline.run(
                    title: title,
                    startedAt: startedAt,
                    ownerNotes: ownerNotes,
                    captures: captures,
                    missingTracks: missingTracks
                ) { message in
                    Task { @MainActor in self.append(message) }
                }
                lastMeetingURL = outcome.directory.url
                // Written up, so the session has done its job.
                try? session?.discard()
                NotificationCenter.default.post(name: .minutesMeetingWritten, object: outcome.directory.url)
                if outcome.notesArePending {
                    append(outcome.notesPendingReason ?? "The endpoint did not answer.")
                    completionNotice = "Transcript saved · Notes pending"
                } else {
                    completionNotice = "Saved"
                }
                userError = nil
            } catch {
                userError = "\u{201C}\(title)\u{201D} could not be written up: \(error.localizedDescription) The recording was kept."
                append(userError!)
                refreshRecoverable()
            }
        }
    }

    // MARK: - Internals

    private func notesClient() -> OpenAICompatibleNotesClient {
        OpenAICompatibleNotesClient(
            baseURL: settings.notesBaseURL,
            model: settings.notesModel,
            apiKey: keyStore.effectiveKey()
        )
    }

    /// Gives the draft a readable datetime title, but only while it is still
    /// empty or still holds the value the controller generated before. A title
    /// the owner typed is never overwritten.
    private func refreshDraftTitle() {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy · HH:mm:ss"
        let generated = formatter.string(from: Date())
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || draft.title == generatedDraftTitle {
            draft.title = generated
        }
        generatedDraftTitle = generated
    }

    private func defaultTitle() -> String {
        defaultTitle(for: startedAt ?? Date())
    }

    private func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM HH:mm"
        return "Meeting \(formatter.string(from: date))"
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        let signal = microphone.signal
        level = meter(signal, previous: level, lastFrames: &lastMicrophoneFrames)
        microphoneStarved = microphone.isStarved
        // A tap or a device that has stopped feeding looks exactly like a
        // quiet room to a level check, so the app measures both instead of
        // assuming.
        capturedSilence =
            signal.isAllZero || signal.hasStalled(sampleRate: AudioFormat.sampleRate, forSeconds: 10)
            || microphoneStarved
        say(microphone.notes, shown: &microphoneNotesShown)

        if systemAudioRunning {
            let systemSignal = systemAudio.signal
            systemLevel = meter(systemSignal, previous: systemLevel, lastFrames: &lastSystemFrames)
            systemAudioSilence = systemSignal.isAllZero
            systemAudioStarved = systemAudio.isStarved
            // Anything the tap had to do, such as rebuilding itself, is said
            // once and in the same activity log as everything else.
            say(systemAudio.notes, shown: &systemNotesShown)
        }

        // The words typed so far go to disk with the recording.
        if let session, draft != savedDraft {
            if (try? session.save(draft: draft)) != nil { savedDraft = draft }
        }
    }

    /// The meter follows what arrived since the last look, and falls when
    /// nothing did, so a microphone that stopped never shows as live.
    private func meter(_ signal: SignalCheck, previous: Float, lastFrames: inout Int) -> Float {
        defer { lastFrames = signal.frameCount }
        guard signal.frameCount > lastFrames else { return previous * 0.5 }
        return signal.meterLevel
    }

    private func say(_ notes: [String], shown: inout Int) {
        guard notes.count > shown else { return }
        for note in notes[shown...] { append(note) }
        shown = notes.count
    }

    private func append(_ message: String) {
        log.append(message)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }
}

#if DEBUG
extension RecordingController {
    /// Puts the controller into a fixed state for the screenshots. Debug
    /// builds only: it opens no device and writes nothing.
    func showForSnapshot(
        recording: Bool,
        elapsed: TimeInterval = 0,
        level: Float = 0,
        systemLevel: Float = 0,
        draft: MeetingDraft,
        writingUp: [RunningWriteUp] = [],
        recoverable: [RecoverableRecording] = [],
        completionNotice: String? = nil,
        log: [String] = []
    ) {
        state = RecordingState(phase: recording ? .recording : .idle)
        startedAt = recording ? Date().addingTimeInterval(-elapsed) : nil
        self.elapsed = elapsed
        self.level = level
        self.systemLevel = systemLevel
        systemAudioRunning = recording
        self.draft = draft
        self.writingUp = writingUp
        self.recoverable = recoverable
        self.completionNotice = completionNotice
        self.log = log
        userError = nil
        modelReady = true
        microphonePermission = .granted
        firstRunOverride = false
    }
}
#endif
