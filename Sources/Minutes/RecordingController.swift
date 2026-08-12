import AppKit
import Foundation
import MinutesCore
import SwiftUI

/// Drives one meeting: start both tracks, keep the meter honest while they
/// run, then hand the recordings to the pipeline.
@MainActor
final class RecordingController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case working(String)
        case finished

        var isBusy: Bool {
            if case .working = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var capturedSilence = false
    @Published private(set) var systemAudioSilence = false
    @Published private(set) var log: [String] = []
    @Published private(set) var lastMeetingURL: URL?
    @Published private(set) var modelReady: Bool
    @Published private(set) var modelDownloadProgress: Double?

    @Published var title: String = ""
    @Published var bullets: String = ""
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
    }

    // MARK: - Facts shown on screen

    var isRecording: Bool { phase == .recording }

    /// What to say about the other side of the meeting. Before recording this
    /// is how the permission works, because macOS never reports it. While
    /// recording it is what the track has actually carried so far, which is the
    /// only honest thing an app can say about a tap.
    var systemAudioNotice: String? {
        if let reason = systemAudio.unavailableReason { return reason }
        guard isRecording else { return SystemAudioCapture.permissionNotice }
        guard systemAudioRunning else {
            return "The system audio tap is not running, so only your side of this meeting is being recorded."
        }
        if systemAudioSilence {
            return "Nothing has been heard from the other side yet. That is either a quiet meeting or a permission macOS never granted, and minutes cannot tell which until something is heard."
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
            return modelReady ? "Ready." : "Ready, but the speech model is not downloaded yet."
        case .recording:
            return capturedSilence
                ? "Recording, but every sample so far is digital zero. Nothing is being heard."
                : "Recording."
        case .working(let what):
            return what
        case .finished:
            return "Done."
        }
    }

    // MARK: - Settings

    func saveSettings() {
        settingsStore.save(settings)
        transcriber = FluidAudioTranscriber(model: settings.asrModel)
        modelReady = transcriber.modelsAreReady()
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
        try? FileManager.default.createDirectory(at: settings.notesFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func testEndpoint() {
        endpointStatus = "Asking \(settings.notesBaseURL) for its models."
        let client = notesClient()
        let wanted = settings.notesModel
        Task { @MainActor in
            do {
                let models = try await client.probeModels()
                if models.contains(wanted) {
                    endpointStatus = "The endpoint answered and offers \(wanted)."
                } else {
                    endpointStatus = "The endpoint answered with \(models.count) models, but not \(wanted)."
                }
            } catch {
                endpointStatus = error.localizedDescription
            }
        }
    }

    func downloadModel() {
        modelDownloadProgress = 0
        let choice = settings.asrModel
        Task { @MainActor in
            do {
                _ = try await FluidAudioTranscriber.downloadModels(choice) { fraction in
                    Task { @MainActor in self.modelDownloadProgress = fraction }
                }
                modelDownloadProgress = nil
                transcriber = FluidAudioTranscriber(model: choice)
                modelReady = transcriber.modelsAreReady()
                append("Speech model downloaded.")
            } catch {
                modelDownloadProgress = nil
                append("The speech model did not download: \(error.localizedDescription)")
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
        guard phase == .idle || phase == .finished else { return }
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
            do {
                try microphone.start(writingTo: url)
                recordingURL = url
                startedAt = Date()
                phase = .recording
                append("Recording started.")
                startTicker()
            } catch {
                append("Recording did not start: \(error.localizedDescription)")
                phase = .idle
                return
            }

            // The other side is a separate track and a separate risk. If the
            // tap will not start, the meeting still gets recorded, and the log
            // says which half it has.
            do {
                try systemAudio.start(writingTo: systemURL)
                systemAudioRunning = true
                append("Recording what this Mac plays as well, so the other side of the meeting is on its own track.")
            } catch {
                systemAudioRunning = false
                append("System audio did not start: \(error.localizedDescription)")
                append("Only your side of this meeting is being recorded.")
            }
        }
    }

    func stopAndWriteUp() {
        guard isRecording else { return }
        stopTicker()

        let captured: CaptureResult
        do {
            captured = try microphone.stop()
        } catch {
            append("Stopping the recording failed: \(error.localizedDescription)")
            phase = .idle
            return
        }

        var captures = [captured]
        var missingTracks: [AudioTrack] = []
        if systemAudioRunning {
            do {
                captures.append(try systemAudio.stop())
            } catch {
                missingTracks.append(.others)
                append("The system audio track could not be closed: \(error.localizedDescription)")
            }
        } else {
            missingTracks.append(.others)
        }
        systemAudioRunning = false

        // Every track is summarised by the pipeline, in the order it processes
        // them, so nothing is reported twice or reported for one track only.
        let meetingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultTitle()
            : title
        let started = startedAt ?? Date()
        let ownerNotes = bullets
        let currentSettings = settings

        phase = .working("Transcribing on this Mac.")

        let pipeline = MeetingPipeline(
            settings: currentSettings,
            store: MeetingStore(settings: currentSettings),
            transcriber: transcriber,
            notes: notesClient()
        )

        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(
                    at: currentSettings.notesFolderURL, withIntermediateDirectories: true)

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
                phase = .finished
            } catch {
                append("The meeting could not be written up: \(error.localizedDescription)")
                phase = .finished
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
        capturedSilence = signal.isAllZero || signal.hasStalled(sampleRate: AudioFormat.sampleRate, forSeconds: 10)

        if systemAudioRunning {
            let systemSignal = systemAudio.signal
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
