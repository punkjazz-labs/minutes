import Foundation

/// When to tear the system audio tap down and build it again.
///
/// Taps have been reported delivering nothing but digital zero after a while,
/// recoverable only by rebuilding them. The catch is that a tap on the output
/// of a Mac where nothing is playing delivers exactly the same thing: a run of
/// zeros is not evidence of a fault, it is what a quiet meeting sounds like.
///
/// So this policy is deliberately slow and bounded. It waits for a long
/// unbroken run of digital zero, rebuilds, and gives up after a few attempts
/// rather than churning the audio graph for the rest of the meeting. Every
/// rebuild is counted and said out loud, and if the track still carried nothing
/// at the end it is reported as silent rather than written up as fine.
///
/// The decision is a plain value with no clock and no devices in it, so the
/// checks can drive it to the exact frame.
public struct TapRebuildPolicy: Sendable, Equatable {

    /// Unbroken digital zero for this long is what triggers a rebuild.
    public let silenceThreshold: TimeInterval
    /// Rebuilds allowed in one meeting.
    public let maximumRebuilds: Int

    public private(set) var rebuildCount = 0
    /// Zero frames already accounted for by the last rebuild.
    private var zeroBaseline = 0

    public init(silenceThreshold: TimeInterval = 30, maximumRebuilds: Int = 3) {
        self.silenceThreshold = silenceThreshold
        self.maximumRebuilds = maximumRebuilds
    }

    public var isExhausted: Bool { rebuildCount >= maximumRebuilds }

    /// True when the track has been digital zero long enough to be worth a
    /// rebuild, and there are rebuilds left.
    public mutating func shouldRebuild(
        signal: SignalCheck,
        sampleRate: Double = AudioFormat.sampleRate
    ) -> Bool {
        guard sampleRate > 0, !isExhausted else { return false }
        // A non-zero sample resets the run, which resets what the last rebuild
        // had already accounted for.
        if signal.trailingZeroFrames < zeroBaseline { zeroBaseline = 0 }
        let sinceLastRebuild = signal.trailingZeroFrames - zeroBaseline
        return Double(sinceLastRebuild) / sampleRate >= silenceThreshold
    }

    /// Records that a rebuild happened and returns how many there have been.
    @discardableResult
    public mutating func recordRebuild(signal: SignalCheck) -> Int {
        rebuildCount += 1
        zeroBaseline = signal.trailingZeroFrames
        return rebuildCount
    }

    /// The sentence for the activity log. Says what it did and does not claim
    /// a fault it cannot prove.
    public func rebuildNotice(seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return
            "The system audio track has been digital zero for \(whole) seconds. Rebuilding the tap, attempt \(rebuildCount) of \(maximumRebuilds). Nothing playing sounds exactly the same, so this is a retry and not a diagnosis."
    }

    public static let exhaustedNotice =
        "The system audio tap was rebuilt as often as minutes will try and the track was still digital zero. It is reported as silent rather than written up as a recording."
}
