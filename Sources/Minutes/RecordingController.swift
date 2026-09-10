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

    /// What the owner typed for the meeting being recorded now, or for the one
    /// about to be recorded. Cleared when a meeting is written up and never
    /// before that.
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
    private var recordingURL: URL?
    private var systemAudioRunning = false
    private var systemNotesShown = 0
    /// Settings, transcriber, and notes client captured before the first await
    /// of a start, so the pipeline runs against what the meeting began with.
    private var sessionSettings: AppSettings?
    private var sessionTranscriber: FluidAudioTranscriber?
    private var sessionNotes: OpenAICompatibleNotesClient?
    private var activeDownloadID: UUID?

    private let firstRunKey = "minutes.firstRunNoticeAcknowledged"

    init(
        settingsStore: any SettingsStoring = UserDefaultsSettingsStore(),
        keyStore: any APIKeyStoring = KeychainAPIKeyStore()
    ) {
        self.settingsStore = settingsStore
        self.keyStore = keyStore
        let loaded = settingsStore.load()
        self.settings = loaded
        self.transcriber = FluidAudioTranscriber(model: loaded.asrModel)
        self.modelReady = FluidAudioTranscriber(model: loaded.asrModel).modelsAreReady()
        self.apiKeyField = keyStore.readKey() ?? ""
        self.microphonePermission = MicrophoneCapture.permissionState
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
            || modelDownloadProgress != nil
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
        !UserDefaults.standard.bool(forKey: firstRunKey)
    }

    func acknowledgeFirstRunNotice() {
        UserDefaults.standard.set(true, forKey: firstRunKey)
        objectWillChange.send()
    }

    var statusLine: String {
        switch phase {
        case .idle:
            if microphoneBlocked {
                return
                    "The microphone is blocked. Allow minutes in System Settings > Privacy & Security > Microphone."
            }
            if let error = userError { return error }
            if !modelReady { return "Download the speech model in Settings." }
            if let notice = completionNotice { return notice }
            return "Ready."
        case .starting:
            return "Opening the microphone and the system audio tap."
        case .recording:
            return capturedSilence
                ? "Recording, but every sample so far is digital zero. Nothing is being heard."
                : "Recording."
        case .working(let what):
            return what
        case .finished:
            if let error = userError { return error }
            if let notice = completionNotice { return notice }
            return "Done."
        }
    }

    // MARK: - Settings

    func saveSettings() {
        guard !settingsLocked else {
            settingsMessage =
                "Settings cannot be saved while a meeting is starting or recording, while work is running, or while a model downloads."
            return
        }
        var candidate = settings
        candidate.notesBaseURL = candidate.notesBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.notesModel = candidate.notesModel.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.notesFolderPath = candidate.notesFolderPath.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let problems = candidate.problems
        guard problems.isEmpty else {
            settingsMessage = "Settings were not saved: " + problems.joined(separator: " ")
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
                endpointStatus = "The key was cleared. minutes will send the documented placeholder."
            } else {
                try keyStore.writeKey(trimmed)
                endpointStatus = "The key was saved to the login keychain."
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
        endpointStatus = "Asking \(baseURL) for its models."
        Task { @MainActor in
            defer { isTestingEndpoint = false }
            do {
                let models = try await client.probeModels()
                // The result only stands for the settings it was asked about.
                guard settings.notesBaseURL == baseURL, settings.notesModel == wanted else { return }
                if models.contains(wanted) {
                    endpointStatus = "The endpoint answered and offers \(wanted)."
                } else {
                    endpointStatus =
                        "The endpoint answered with \(models.count) models, but \(wanted) is not among them. The endpoint is reachable; this says nothing about whether generation works."
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
        systemAudioSilence = false
        systemNotesShown = 0
        elapsed = 0
        level = 0

        let session = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-mic-\(session).wav")
        let systemURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-system-\(session).wav")

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
            do {
                try microphone.start(writingTo: url)
                recordingURL = url
                startedAt = Date()
                state.startSucceeded()
                append("Recording started.")
                startTicker()
            } catch {
                userError = "Recording did not start: \(error.localizedDescription)"
                append(userError!)
                state.startFailed()
                return
            }

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
        for line in stopped.failures { append(line) }

        // Without the owner's own track there is no meeting to write up. The
        // tap is already stopped by the line above, whatever happened here.
        guard stopped.ownCapture != nil else {
            userError =
                "No microphone capture was recorded, so there is no meeting to write up. Your draft is kept."
            state.abandon()
            return
        }

        let captures = stopped.captures
        let missingTracks = stopped.missingTracks

        // Every track is summarised by the pipeline, in the order it processes
        // them, so nothing is reported twice or reported for one track only.
        let meetingTitle = draft.meetingTitle(or: defaultTitle())
        let started = startedAt ?? Date()
        let ownerNotes = draft.bullets
        let pipelineSettings = sessionSettings ?? settings
        let pipelineTranscriber = sessionTranscriber ?? transcriber
        let pipelineNotes = sessionNotes ?? notesClient()

        state.working("Transcribing on this Mac.")

        let pipeline = MeetingPipeline(
            settings: pipelineSettings,
            store: MeetingStore(settings: pipelineSettings),
            transcriber: pipelineTranscriber,
            notes: pipelineNotes
        )
        // The pipeline now holds the session's settings, transcriber, and
        // client in its own captured locals, so the controller's snapshots
        // can go. They are cleared here and not earlier, because they are
        // read up to this point.
        sessionSettings = nil
        sessionTranscriber = nil
        sessionNotes = nil

        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(
                    at: pipelineSettings.notesFolderURL, withIntermediateDirectories: true)

                let outcome = try await pipeline.run(
                    title: meetingTitle,
                    startedAt: started,
                    ownerNotes: ownerNotes,
                    captures: captures,
                    missingTracks: missingTracks
                ) { message in
                    Task { @MainActor in self.append(message) }
                }
                lastMeetingURL = outcome.directory.url
                if outcome.notesArePending {
                    completionNotice =
                        "Meeting saved. The notes are still pending: \(outcome.notesPendingReason ?? "the endpoint did not answer")."
                } else {
                    completionNotice = "Meeting saved. The notes are ready."
                }
                // The title and the bullets are in that meeting's folder now,
                // so they do not carry into the next meeting. A write-up that
                // failed keeps them, because then the folder does not have
                // them and the app is the only place they exist.
                draft.clearAfterWriteUp()
                state.finish()
            } catch {
                userError = "The meeting could not be written up: \(error.localizedDescription)"
                append(userError!)
                // The thrown failure means the folder may not hold the draft,
                // so it is preserved here for the next attempt.
                state.abandon()
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

    private func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM HH:mm"
        return "Meeting \(formatter.string(from: startedAt ?? Date()))"
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
        level = signal.meterLevel
        // A tap or a device that has stopped feeding looks exactly like a
        // quiet room, so the app measures instead of assuming.
        capturedSilence =
            signal.isAllZero || signal.hasStalled(sampleRate: AudioFormat.sampleRate, forSeconds: 10)

        if systemAudioRunning {
            let systemSignal = systemAudio.signal
            systemLevel = systemSignal.meterLevel
            systemAudioSilence = systemSignal.isAllZero
            // Anything the tap had to do, such as rebuilding itself, is said
            // once and in the same activity log as everything else.
            let notes = systemAudio.notes
            if notes.count > systemNotesShown {
                for note in notes[systemNotesShown...] { append(note) }
                systemNotesShown = notes.count
            }
        }
    }

    private func append(_ message: String) {
        log.append(message)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }
}
