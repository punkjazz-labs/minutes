import Foundation

/// System audio, meaning what the other people in the meeting say.
///
/// v0.1 does not capture it. This type exists so the rest of the app is
/// already written against the two-track shape, and so the missing half is
/// visible on screen instead of silently absent. `start` refuses; it never
/// writes a silent file that would look like a recording.
///
/// The approach chosen for v0.2 is Core Audio process taps, not
/// ScreenCaptureKit. A tap is audio only, works per process, can exclude the
/// app's own output, and uses its own TCC category, while ScreenCaptureKit is
/// a video API that needs Screen Recording permission and drops audio frames
/// without a dummy video output. See docs/decisions/0002 for the reasoning and
/// the constraints the implementation has to meet.
public final class SystemAudioCapture: AudioCapturing, @unchecked Sendable {

    public let track: AudioTrack = .others

    public init() {}

    public var isAvailable: Bool { false }

    public var unavailableReason: String? {
        "System audio is not captured in v0.1, so only your side of the meeting is recorded. The Core Audio process tap that captures the other side is the next piece of work."
    }

    public var signal: SignalCheck { SignalCheck() }

    public func start(writingTo url: URL) throws {
        throw CaptureError.unavailable(unavailableReason ?? "System audio capture is not available.")
    }

    public func stop() throws -> CaptureResult {
        throw CaptureError.notRecording
    }
}
