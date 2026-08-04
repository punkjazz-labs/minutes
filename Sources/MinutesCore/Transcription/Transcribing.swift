import Foundation

/// A token with a start and an end, as any of the candidate speech engines
/// report it. Defined here so the segment arithmetic is testable without
/// loading a model or linking the engine.
public struct TimedToken: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct TranscriptionOutput: Sendable {
    public let segments: [TranscriptSegment]
    public let audioDuration: TimeInterval
    public let processingTime: TimeInterval

    public init(segments: [TranscriptSegment], audioDuration: TimeInterval, processingTime: TimeInterval) {
        self.segments = segments
        self.audioDuration = audioDuration
        self.processingTime = processingTime
    }

    /// How many times faster than real time this run was. Reported, never assumed.
    public var realtimeFactor: Double {
        processingTime > 0 ? audioDuration / processingTime : 0
    }
}

public enum TranscriptionError: Error, LocalizedError {
    case modelsMissing(String)
    case engineFailure(String)

    public var errorDescription: String? {
        switch self {
        case .modelsMissing(let detail): return detail
        case .engineFailure(let detail): return detail
        }
    }
}

/// The speech engine seam. Everything above it is deterministic and tested
/// against a fake.
public protocol Transcribing: Sendable {
    var engineName: String { get }
    var modelName: String { get }

    /// True when the model files are already on disk, so the app can say
    /// "download the model" instead of stalling on a first run.
    func modelsAreReady() -> Bool

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws

    func transcribe(fileAt url: URL, track: AudioTrack) async throws -> TranscriptionOutput
}

/// Groups tokens into readable, timestamped lines.
public enum SegmentBuilder {

    public struct Options: Sendable {
        /// A silence longer than this starts a new line.
        public var maximumGap: TimeInterval
        /// No line runs longer than this, however continuous the speech.
        public var maximumDuration: TimeInterval

        public init(maximumGap: TimeInterval = 0.8, maximumDuration: TimeInterval = 18) {
            self.maximumGap = maximumGap
            self.maximumDuration = maximumDuration
        }

        public static let `default` = Options()
    }

    /// SentencePiece marks a word boundary with U+2581. Turn tokens back into text.
    public static func text(from tokens: [TimedToken]) -> String {
        var result = ""
        for token in tokens {
            var piece = token.text
            if piece.hasPrefix("\u{2581}") {
                piece.removeFirst()
                if !result.isEmpty { result.append(" ") }
            }
            result.append(piece)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    public static func segments(
        from tokens: [TimedToken],
        track: AudioTrack,
        options: Options = .default
    ) -> [TranscriptSegment] {
        guard !tokens.isEmpty else { return [] }

        var segments: [TranscriptSegment] = []
        var current: [TimedToken] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let body = text(from: current)
            guard !body.isEmpty else {
                current = []
                return
            }
            segments.append(
                TranscriptSegment(track: track, start: first.start, end: last.end, text: body))
            current = []
        }

        for token in tokens {
            if let last = current.last, let first = current.first {
                let gap = token.start - last.end
                let wouldRunLong = token.end - first.start > options.maximumDuration
                let sentenceEnded = last.text.hasSuffix(".") || last.text.hasSuffix("?") || last.text.hasSuffix("!")
                let startsWord = token.text.hasPrefix("\u{2581}") || token.text.hasPrefix(" ")
                if gap > options.maximumGap || (wouldRunLong && startsWord) || (sentenceEnded && startsWord) {
                    flush()
                }
            }
            current.append(token)
        }
        flush()
        return segments
    }

    /// Fallback when an engine returns text but no timings: one line for the
    /// whole recording, timestamped honestly at zero.
    public static func singleSegment(text: String, track: AudioTrack, duration: TimeInterval) -> [TranscriptSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [TranscriptSegment(track: track, start: 0, end: duration, text: trimmed)]
    }
}

/// Returns a fixed transcript. Used by the tests and by `minutes-cli` when the
/// model has not been downloaded yet.
public struct FixtureTranscriber: Transcribing {
    public let engineName: String
    public let modelName: String
    private let segments: [TranscriptSegment]
    private let audioDuration: TimeInterval

    public init(
        engineName: String = "fixture",
        modelName: String = "golden-transcript",
        segments: [TranscriptSegment],
        audioDuration: TimeInterval = 0
    ) {
        self.engineName = engineName
        self.modelName = modelName
        self.segments = segments
        self.audioDuration = audioDuration
    }

    public func modelsAreReady() -> Bool { true }

    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}

    public func transcribe(fileAt url: URL, track: AudioTrack) async throws -> TranscriptionOutput {
        let forTrack = segments.filter { $0.track == track }
        return TranscriptionOutput(segments: forTrack, audioDuration: audioDuration, processingTime: 0)
    }
}
