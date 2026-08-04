import FluidAudio
import Foundation

/// Local speech recognition with Parakeet TDT through FluidAudio.
///
/// FluidAudio is the engine the product spec picks for macOS: Swift, Apache-2.0,
/// Core ML on the Neural Engine, permissively licensed Parakeet weights and no
/// Hugging Face token. Nothing here goes to a network service at transcription
/// time. The model files are fetched once, from Hugging Face, by `prepare`.
public actor FluidAudioTranscriber: Transcribing {

    private let version: AsrModelVersion
    private let choice: ASRModelChoice
    private var manager: AsrManager?
    private var models: AsrModels?

    public init(model: ASRModelChoice = .v3) {
        self.choice = model
        self.version = (model == .v3) ? .v3 : .v2
    }

    nonisolated public var engineName: String { "FluidAudio Parakeet TDT (Core ML, Apple Neural Engine)" }

    nonisolated public var modelName: String {
        switch choice {
        case .v3: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .v2: return "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        }
    }

    nonisolated public var modelCacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    nonisolated public func modelsAreReady() -> Bool {
        AsrModels.modelsExist(at: modelCacheDirectory, version: version)
    }

    /// Downloads the model if it is missing, then loads it. The download is
    /// hundreds of megabytes and happens once.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if manager != nil { return }

        var handler: ProgressHandler?
        if let progress {
            handler = { update in progress(update.fractionCompleted) }
        }

        do {
            let loaded = try await AsrModels.downloadAndLoad(version: version, progressHandler: handler)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(loaded)
            self.models = loaded
            self.manager = manager
        } catch {
            throw TranscriptionError.modelsMissing(
                "The speech model could not be prepared: \(error.localizedDescription). Run 'make fetch-models' while online.")
        }
    }

    public func transcribe(fileAt url: URL, track: AudioTrack) async throws -> TranscriptionOutput {
        try await prepare(progress: nil)

        guard let manager, let models else {
            throw TranscriptionError.modelsMissing("The speech model is not loaded.")
        }

        let started = Date()
        do {
            var state = try TdtDecoderState(decoderLayers: models.version.decoderLayers)
            let result = try await manager.transcribe(url, decoderState: &state)
            let elapsed = Date().timeIntervalSince(started)

            let tokens = (result.tokenTimings ?? []).map {
                TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime)
            }
            let segments =
                tokens.isEmpty
                ? SegmentBuilder.singleSegment(text: result.text, track: track, duration: result.duration)
                : SegmentBuilder.segments(from: tokens, track: track)

            return TranscriptionOutput(
                segments: segments,
                audioDuration: result.duration,
                processingTime: elapsed
            )
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.engineFailure("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Fetches the model without transcribing anything, for the setup step.
    public static func downloadModels(
        _ model: ASRModelChoice,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let version: AsrModelVersion = (model == .v3) ? .v3 : .v2
        var handler: ProgressHandler?
        if let progress {
            handler = { update in progress(update.fractionCompleted) }
        }
        return try await AsrModels.download(version: version, progressHandler: handler)
    }
}
