import Foundation

/// Running level statistics over a capture. Core Audio taps have been reported
/// delivering all-zero PCM after several minutes, and all-zero is not
/// distinguishable from real silence after the fact, so the app measures the
/// signal while it records and says so on screen.
public struct SignalCheck: Sendable, Equatable {
    public private(set) var frameCount: Int = 0
    public private(set) var peak: Float = 0
    public private(set) var sumOfSquares: Double = 0
    /// Frames seen since the last non-zero sample.
    public private(set) var trailingZeroFrames: Int = 0

    public init() {}

    public mutating func observe(_ samples: [Float]) {
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumOfSquares += Double(sample) * Double(sample)
            if sample == 0 {
                trailingZeroFrames += 1
            } else {
                trailingZeroFrames = 0
            }
        }
        frameCount += samples.count
    }

    public var rms: Float {
        guard frameCount > 0 else { return 0 }
        return Float((sumOfSquares / Double(frameCount)).squareRoot())
    }

    /// Every sample seen so far was exactly zero, which includes having seen no
    /// sample at all. This is the tap failure the spec calls out, and it is also
    /// what an unrecorded device looks like.
    ///
    /// A source that delivered no buffers heard exactly as much as a source
    /// that delivered digital silence, so the two are written up the same way.
    /// The empty one used to pass as a recorded track, which put a 44 byte file
    /// in the meeting folder, named the track under `tracksRecorded`, and let
    /// the detail header say both sides were recorded.
    public var isAllZero: Bool {
        peak == 0
    }

    /// Nothing but digital zero for this long. A real room floor is never
    /// exactly zero, so a run of exact zeros means the device stopped feeding.
    public func hasStalled(sampleRate: Double, forSeconds seconds: Double) -> Bool {
        guard sampleRate > 0 else { return false }
        return Double(trailingZeroFrames) / sampleRate >= seconds
    }

    /// Level in 0...1 for a meter, from the peak of the whole capture.
    public var meterLevel: Float { min(1, peak) }
}
