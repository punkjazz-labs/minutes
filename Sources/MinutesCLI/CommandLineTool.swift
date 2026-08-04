import Foundation
import MinutesCore

/// A command line face for the same core the app uses.
///
/// It exists because the parts worth verifying, model download, transcription
/// and notes generation, can be exercised without a window, a permission
/// prompt or a signed bundle.
@main
struct CommandLineTool {

    static let usage = """
        minutes-cli \(MinutesBuild.version)

        Usage:
          minutes-cli settings
              Print the settings in force, including where notes are written.

          minutes-cli probe
              Ask the notes endpoint for its model list. Proves the endpoint and the key work.

          minutes-cli fetch-models [--model v3|v2]
              Download the Parakeet speech model to the local cache. Needs the network once.

          minutes-cli transcribe <audio.wav> [--track me|others] [--model v3|v2]
              Transcribe a WAV on this Mac and print the transcript with measured timings.

          minutes-cli notes <transcript.txt> [--title "Title"] [--bullets notes.md]
              Send an existing transcript to the notes endpoint and print the notes.

          minutes-cli meeting <audio.wav> [--title "Title"] [--bullets notes.md] [--track me|others]
              Full path: transcribe, write the meeting folder, ask for notes.

        Environment overrides: MINUTES_BASE_URL, MINUTES_MODEL, MINUTES_FOLDER, MINUTES_KEEP_AUDIO, MINUTES_API_KEY
        """

    struct Arguments {
        let command: String
        let positional: [String]
        let options: [String: String]

        init(_ raw: [String]) {
            var positional: [String] = []
            var options: [String: String] = [:]
            var index = 0
            while index < raw.count {
                let item = raw[index]
                if item.hasPrefix("--") {
                    let key = String(item.dropFirst(2))
                    if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                        options[key] = raw[index + 1]
                        index += 2
                    } else {
                        options[key] = "true"
                        index += 1
                    }
                } else {
                    positional.append(item)
                    index += 1
                }
            }
            self.command = positional.first ?? "help"
            self.positional = Array(positional.dropFirst())
            self.options = options
        }
    }

    static func complain(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func main() async {
        let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
        let settings = UserDefaultsSettingsStore().load().applyingEnvironmentOverrides()
        let keyStore = EnvironmentAPIKeyStore()

        func notesClient() -> OpenAICompatibleNotesClient {
            OpenAICompatibleNotesClient(
                baseURL: settings.notesBaseURL,
                model: settings.notesModel,
                apiKey: keyStore.effectiveKey())
        }

        func modelChoice() -> ASRModelChoice {
            guard let raw = arguments.options["model"], let choice = ASRModelChoice(rawValue: raw) else {
                return settings.asrModel
            }
            return choice
        }

        func track() -> AudioTrack {
            guard let raw = arguments.options["track"], let value = AudioTrack(rawValue: raw) else { return .me }
            return value
        }

        func readFile(_ option: String) -> String {
            guard let path = arguments.options[option] else { return "" }
            return (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) ?? ""
        }

        switch arguments.command {

        case "settings":
            let store = MeetingStore(settings: settings)
            let transcriber = FluidAudioTranscriber(model: modelChoice())
            print("notes endpoint: \(settings.notesBaseURL)")
            print("notes model:    \(settings.notesModel)")
            print("api key:        \(keyStore.readKey() == nil ? "not set, sending the documented placeholder" : "set from \(EnvironmentAPIKeyStore.variableName)")")
            print("notes folder:   \(settings.notesFolderURL.path)")
            print("speech model:   \(modelChoice().displayName)")
            print("keep audio:     \(settings.keepAudioAfterTranscription)")
            print("model on disk:  \(transcriber.modelsAreReady() ? "yes" : "no, run minutes-cli fetch-models")")
            print("model cache:    \(transcriber.modelCacheDirectory.path)")
            if let warning = store.syncWarning { print("folder:         \(warning)") }
            print("")
            print(PrivacyClaim.text(endpoint: settings.notesBaseURL, syncService: store.syncService))

        case "probe":
            do {
                let models = try await notesClient().probeModels()
                print("The endpoint at \(settings.notesBaseURL) answered with \(models.count) models.")
                if models.contains(settings.notesModel) {
                    print("The configured model \(settings.notesModel) is available.")
                } else {
                    print("The configured model \(settings.notesModel) is not in the list.")
                }
                for model in models.sorted().prefix(40) { print("  \(model)") }
            } catch {
                complain(error.localizedDescription)
            }

        case "fetch-models":
            let choice = modelChoice()
            print("Fetching \(choice.displayName). This is a few hundred megabytes and happens once.")
            let reported = ProgressGate()
            do {
                let url = try await FluidAudioTranscriber.downloadModels(choice) { fraction in
                    if let step = reported.step(for: fraction) {
                        print("  \(step) percent")
                        fflush(stdout)
                    }
                }
                print("Model files are at \(url.path)")
            } catch {
                complain(error.localizedDescription)
            }

        case "transcribe":
            guard let path = arguments.positional.first else { complain(usage) }
            let url = URL(fileURLWithPath: path)
            let transcriber = FluidAudioTranscriber(model: modelChoice())
            if !transcriber.modelsAreReady() {
                print("The speech model is not on disk yet. Downloading it first.")
            }
            do {
                let output = try await transcriber.transcribe(fileAt: url, track: track())
                let transcript = Transcript(
                    segments: output.segments,
                    engine: transcriber.engineName,
                    model: transcriber.modelName,
                    recordedAt: Date(),
                    duration: output.audioDuration)
                print(transcript.markdown(title: url.deletingPathExtension().lastPathComponent))
                print(
                    String(
                        format: "Measured on this Mac: %.2f s of audio in %.2f s, %.1f times faster than real time.",
                        output.audioDuration, output.processingTime, output.realtimeFactor))
            } catch {
                complain(error.localizedDescription)
            }

        case "notes":
            guard let path = arguments.positional.first else { complain(usage) }
            let transcriptText = (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) ?? ""
            if transcriptText.isEmpty { complain("That transcript file is empty or unreadable.") }
            let title = arguments.options["title"] ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            do {
                let result = try await notesClient().enhance(
                    NotesRequest(title: title, ownerNotes: readFile("bullets"), transcript: transcriptText))
                print("Notes from \(result.model) at \(result.endpoint):")
                print("")
                print(result.markdown)
            } catch {
                complain(error.localizedDescription)
            }

        case "meeting":
            guard let path = arguments.positional.first else { complain(usage) }
            let source = URL(fileURLWithPath: path)
            let title = arguments.options["title"] ?? source.deletingPathExtension().lastPathComponent
            do {
                let audio = try WAVReader.read(url: source)
                var signal = SignalCheck()
                signal.observe(audio.samples)

                // Work on a copy so the source file stays where it is.
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("minutes-\(UUID().uuidString).wav")
                try FileManager.default.copyItem(at: source, to: staged)

                let store = MeetingStore(settings: settings)
                try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)

                let outcome = try await MeetingPipeline(
                    settings: settings,
                    store: store,
                    transcriber: FluidAudioTranscriber(model: modelChoice()),
                    notes: notesClient()
                ).run(
                    title: title,
                    startedAt: Date(),
                    ownerNotes: readFile("bullets"),
                    captures: [
                        CaptureResult(track: track(), fileURL: staged, duration: audio.duration, signal: signal)
                    ],
                    missingTracks: [.others]
                ) { message in
                    print(message)
                }

                print("")
                print("Meeting written to \(outcome.directory.url.path)")
                if outcome.notesArePending {
                    print("Notes are waiting: \(outcome.notesPendingReason ?? "no reason recorded")")
                }
            } catch {
                complain(error.localizedDescription)
            }

        default:
            print(usage)
        }
    }
}

/// Prints download progress once per five percent, from whatever queue the
/// downloader calls back on.
final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStep = -1

    func step(for fraction: Double) -> Int? {
        let step = Int(fraction * 100) / 5 * 5
        lock.lock()
        defer { lock.unlock() }
        guard step > lastStep else { return nil }
        lastStep = step
        return step
    }
}
