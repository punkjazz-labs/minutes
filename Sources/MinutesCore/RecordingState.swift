import Foundation

/// Where one meeting is in its life.
public enum RecordingPhase: Equatable, Sendable {
    case idle
    /// The decision to record has been taken and the devices are being opened.
    /// No source is running yet, and no second recording can begin.
    case starting
    case recording
    case working(String)
    case finished

    public var isBusy: Bool {
        if case .working = self { return true }
        return false
    }
}

/// The recording state, and the only changes to it that are allowed.
///
/// This type exists for one rule, and the rule is the difference between an app
/// that records honestly and one that records in secret.
///
/// Opening an audio device is asynchronous. If the phase is written after the
/// devices are open, then between the decision to record and the record of that
/// decision there is a gap, and in that gap a second Record press reads the
/// same idle phase and is allowed through. Two starts then run against one pair
/// of sources. The second one fails, because the sources are already recording,
/// and it reports its own failure by putting the app back to idle. The menu bar
/// drops the record dot, `isRecording` goes false, Stop refuses at its own
/// first guard, and the tap keeps writing everything the Mac plays with nothing
/// on the screen that says so.
///
/// So the test and the change are one operation here, `claimStart`. There is
/// nothing inside it to separate: no device is opened, nothing is awaited, and
/// a caller cannot put a suspension between the read and the write because it
/// never sees them apart. A second press meets `starting` and is refused, and a
/// refusal changes no state at all, so it has no failure of its own to report.
public struct RecordingState: Equatable, Sendable {

    public private(set) var phase: RecordingPhase

    public init(phase: RecordingPhase = .idle) {
        self.phase = phase
    }

    public var isRecording: Bool { phase == .recording }

    /// Takes the recording slot, or refuses because something already holds it.
    ///
    /// True means the caller now owns the slot and must open the devices and
    /// then report `startSucceeded()` or `startFailed()`. False means another
    /// activation owns it, and the caller must do nothing at all: it has opened
    /// no device, so it has nothing to close and nothing to report.
    public mutating func claimStart() -> Bool {
        guard phase == .idle || phase == .finished else { return false }
        phase = .starting
        return true
    }

    /// The devices are open and the meeting is running.
    public mutating func startSucceeded() {
        phase = .recording
    }

    /// The devices did not open, so nothing is running.
    public mutating func startFailed() {
        phase = .idle
    }

    /// Takes the stop, or refuses because no meeting is running.
    public mutating func claimStop() -> Bool {
        guard phase == .recording else { return false }
        phase = .working(RecordingState.stopping)
        return true
    }

    /// What the app is doing now, for the line on the screen.
    public mutating func working(_ what: String) {
        phase = .working(what)
    }

    /// The meeting is written up.
    public mutating func finish() {
        phase = .finished
    }

    /// The meeting cannot be written up, and every source is already stopped.
    public mutating func abandon() {
        phase = .idle
    }

    public static let stopping = "Stopping the recording."
}
