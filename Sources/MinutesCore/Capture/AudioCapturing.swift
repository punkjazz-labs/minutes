import Foundation

/// Which device the audio arrived on. This is the whole of speaker labelling
/// in v0.1: it is not voice recognition and the transcript says so.
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
}

public struct CaptureResult: Sendable {
    public let track: AudioTrack
    public let fileURL: URL
    public let duration: TimeInterval
    public let signal: SignalCheck

    public init(track: AudioTrack, fileURL: URL, duration: TimeInterval, signal: SignalCheck) {
        self.track = track
        self.fileURL = fileURL
        self.duration = duration
        self.signal = signal
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

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .permissionDenied(let reason): return reason
        case .deviceFailure(let reason): return reason
        case .notRecording: return "Stop was asked for while nothing was recording."
        }
    }
}

/// One audio source writing one file. Both the real microphone and the system
/// audio stub sit behind this, and so does the fixture used by the tests, so
/// no test needs a microphone or a permission grant.
public protocol AudioCapturing: AnyObject {
    var track: AudioTrack { get }

    /// False when this source cannot run on this machine or in this build.
    var isAvailable: Bool { get }

    /// Why it cannot run, in a sentence fit to show the owner. Nil when available.
    var unavailableReason: String? { get }

    /// Levels observed so far. Read while recording to drive a meter.
    var signal: SignalCheck { get }

    func start(writingTo url: URL) throws
    func stop() throws -> CaptureResult
}
