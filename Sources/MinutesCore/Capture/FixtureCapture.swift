import Foundation

/// A capture source that replays a WAV fixture. The tests use it so nothing in
/// the default suite touches a microphone or a permission prompt.
public final class FixtureCapture: AudioCapturing, @unchecked Sendable {

    public let track: AudioTrack
    private let samples: [Float]
    private let sampleRate: Int
    private let lock = NSLock()
    private var signalState = SignalCheck()
    private var destination: URL?
    private var recording = false

    public init(track: AudioTrack, samples: [Float], sampleRate: Int = Int(AudioFormat.sampleRate)) {
        self.track = track
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public convenience init(track: AudioTrack, fixtureAt url: URL) throws {
        let audio = try WAVReader.read(url: url)
        self.init(track: track, samples: audio.samples, sampleRate: audio.sampleRate)
    }

    public var isAvailable: Bool { true }
    public var unavailableReason: String? { nil }

    public var signal: SignalCheck {
        lock.lock()
        defer { lock.unlock() }
        return signalState
    }

    public func start(writingTo url: URL) throws {
        let writer = try WAVWriter(url: url, sampleRate: sampleRate)
        var signal = SignalCheck()
        // Written in blocks so the level statistics see the same shape they
        // would see from a live device.
        var index = 0
        let block = 1_600
        while index < samples.count {
            let end = min(index + block, samples.count)
            let chunk = Array(samples[index..<end])
            signal.observe(chunk)
            try writer.append(chunk)
            index = end
        }
        try writer.close()

        lock.lock()
        self.signalState = signal
        self.destination = url
        self.recording = true
        lock.unlock()
    }

    public func stop() throws -> CaptureResult {
        lock.lock()
        defer { lock.unlock() }
        guard recording, let destination else { throw CaptureError.notRecording }
        recording = false
        return CaptureResult(
            track: track,
            fileURL: destination,
            duration: Double(samples.count) / Double(sampleRate),
            signal: signalState
        )
    }
}
