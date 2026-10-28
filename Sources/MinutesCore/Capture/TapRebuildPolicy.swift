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
/// in a row that brought nothing back, rather than churning the audio graph for
/// the rest of the meeting. Every rebuild is counted and said out loud, and if
/// the track still carried nothing at the end it is reported as silent rather
/// than written up as fine.
///
/// The attempts are counted since sound was last heard, not per meeting. A
/// meeting spends its first minutes waiting for people to join and has long
/// quiet stretches on the far side, and a budget for the whole meeting is used
/// up by those before the tap ever fails, which leaves nothing for the failure
/// it exists for. Sound arriving after a rebuild proves the tap works, so the
/// count starts again from there. A Mac that is simply quiet never makes a
/// sound, so it still stops after the same few attempts.
///
/// The decision is a plain value with no clock and no devices in it, so the
/// checks can drive it to the exact frame.
public struct TapRebuildPolicy: Sendable, Equatable {

    /// Unbroken digital zero for this long is what triggers a rebuild.
    public let silenceThreshold: TimeInterval
    /// Rebuilds allowed in a row while nothing is heard.
    public let maximumRebuilds: Int

    /// Rebuilds since sound was last heard. This is what the limit applies to.
    public private(set) var rebuildCount = 0
    /// Every rebuild this meeting, for the record.
    public private(set) var totalRebuilds = 0
    /// Zero frames already accounted for by the last rebuild.
    private var zeroBaseline = 0
    /// Where the last non-zero sample sat when the last rebuild happened.
    private var soundMark = 0

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
        guard sampleRate > 0 else { return false }
        noteWhatWasHeard(signal)
        guard !isExhausted else { return false }
        let sinceLastRebuild = signal.trailingZeroFrames - zeroBaseline
        return Double(sinceLastRebuild) / sampleRate >= silenceThreshold
    }

    /// True when the tap has handed over no buffers at all for long enough,
    /// and there are rebuilds left. A running tap delivers digital zero when
    /// nothing plays, so a tap that delivers nothing has stopped.
    public mutating func shouldRebuild(
        signal: SignalCheck,
        secondsWithoutAudio: TimeInterval,
        threshold: TimeInterval
    ) -> Bool {
        noteWhatWasHeard(signal)
        return !isExhausted && secondsWithoutAudio >= threshold
    }

    /// A non-zero sample resets the run of zeros. One that arrived after the
    /// last rebuild also proves the tap works, so the rebuilds in a row start
    /// again.
    private mutating func noteWhatWasHeard(_ signal: SignalCheck) {
        if signal.trailingZeroFrames < zeroBaseline { zeroBaseline = 0 }
        if Self.lastSound(in: signal) > soundMark { rebuildCount = 0 }
    }

    private static func lastSound(in signal: SignalCheck) -> Int {
        signal.frameCount - signal.trailingZeroFrames
    }

    /// Records that a rebuild happened and returns how many there have been in
    /// a row.
    @discardableResult
    public mutating func recordRebuild(signal: SignalCheck) -> Int {
        rebuildCount += 1
        totalRebuilds += 1
        zeroBaseline = signal.trailingZeroFrames
        soundMark = Self.lastSound(in: signal)
        return rebuildCount
    }

    /// The sentence for the activity log. Says what it did and does not claim
    /// a fault it cannot prove.
    public func rebuildNotice(seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return
            "The system audio track has been digital zero for \(whole) seconds. Rebuilding the tap, attempt \(rebuildCount) of \(maximumRebuilds). Nothing playing sounds exactly the same, so this is a retry and not a diagnosis."
    }

    /// Said when the retries are used up and the track is still carrying
    /// nothing. It speaks about the track from here on, not about the whole
    /// track, because a tap that died halfway through a meeting leaves real
    /// audio behind it and digital zero in front of it.
    public static let exhaustedNotice =
        "The system audio tap was rebuilt as often as minutes will try and the track is still digital zero. What was heard before this is in the transcript. Nothing has been heard since."
}
