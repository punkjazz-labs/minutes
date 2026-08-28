import Foundation

/// Which device the audio arrived on. This is the whole of speaker labelling:
/// it is not voice recognition and the transcript says so.
public enum AudioTrack: String, Codable, Sendable, CaseIterable {
    case me
    case others

    /// Label written into the transcript.
    public var label: String {
        switch self {
        case .me: return "You"
        case .others: return "Others"
        }
    }

    public var fileName: String {
        switch self {
        case .me: return "mic.wav"
        case .others: return "system.wav"
        }
    }

    /// The tracks a meeting made from this one recording does not have. Naming
    /// a fixed track here makes a meeting that says one track is both recorded
    /// and missing.
    public static func missing(whenRecordingOnly track: AudioTrack) -> [AudioTrack] {
        allCases.filter { $0 != track }
    }
}

public struct CaptureResult: Sendable {
    public let track: AudioTrack
    public let fileURL: URL
    public let duration: TimeInterval
    public let signal: SignalCheck
    /// Anything the source had to do or could not do while it recorded, in
    /// sentences fit for the activity log. A tap that was torn down and rebuilt
    /// says so here, and so does an output device that changed mid-meeting.
    public let notes: [String]

    public init(
        track: AudioTrack,
        fileURL: URL,
        duration: TimeInterval,
        signal: SignalCheck,
        notes: [String] = []
    ) {
        self.track = track
        self.fileURL = fileURL
        self.duration = duration
        self.signal = signal
        self.notes = notes
    }

    /// Plain sentence for the activity log. Never claims a recording is good
    /// when the samples were all zero.
    public var summary: String {
        let seconds = String(format: "%.1f", duration)
        if signal.isAllZero {
            return "\(track.label): \(seconds) s recorded, every sample was digital zero. Nothing was heard."
        }
        let peak = String(format: "%.2f", signal.peak)
        return "\(track.label): \(seconds) s recorded, peak level \(peak)."
    }
}

public enum CaptureError: Error, LocalizedError {
    case unavailable(String)
    case permissionDenied(String)
    case deviceFailure(String)
    case notRecording
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .permissionDenied(let reason): return reason
        case .deviceFailure(let reason): return reason
        case .notRecording: return "Stop was asked for while nothing was recording."
        case .alreadyRecording:
            return
                "Recording was asked for while this source was already recording. The recording that is running was left alone."
        }
    }
}

/// One audio source writing one file. The real microphone, the Core Audio
/// process tap that records what the other side says, and the fixture used by
/// the checks all sit behind this, so no check needs a device or a permission
/// grant.
public protocol AudioCapturing: AnyObject {
    var track: AudioTrack { get }

    /// False when this source cannot run on this machine or in this build.
    var isAvailable: Bool { get }

    /// Why it cannot run, in a sentence fit to show the owner. Nil when available.
    var unavailableReason: String? { get }

    /// Levels observed so far. Read while recording to drive a meter.
    var signal: SignalCheck { get }

    /// What the source has had to do so far, in sentences fit for the activity
    /// log. Empty for a source with nothing to report.
    var notes: [String] { get }

    func start(writingTo url: URL) throws
    func stop() throws -> CaptureResult
}

extension AudioCapturing {
    public var notes: [String] { [] }
}
