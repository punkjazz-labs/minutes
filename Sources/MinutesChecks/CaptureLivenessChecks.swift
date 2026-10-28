import AVFoundation
import Foundation
import MinutesCore

/// A clock the checks move by hand, so a source that stops feeding for ten
/// seconds takes no time at all to check.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }

    var clock: TrackWriter.Clock { { [self] in self.now } }
}

/// A microphone that feeds exactly what the check asks for, and can be told
/// that its device changed under it.
final class ScriptedMicrophone: MicrophoneSource, @unchecked Sendable {

    let deviceName = "a scripted microphone"

    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var interrupt: (@Sendable () -> Void)?
    private var starts = 0
    private var stops = 0
    /// Run by `start`, before the source is handed back.
    var whileStarting: (() -> Void)?

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onInterrupted: @escaping @Sendable () -> Void
    ) throws -> AVAudioFormat {
        lock.lock()
        starts += 1
        sink = onBuffer
        interrupt = onInterrupted
        lock.unlock()
        whileStarting?()
        return ScriptedMicrophone.format
    }

    func stop() {
        lock.lock()
        stops += 1
        sink = nil
        lock.unlock()
    }

    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// Pushes one buffer the way a USB microphone delivers it.
    func feed(value: Float, seconds: Double) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        guard let sink,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: ScriptedMicrophone.format, frameCapacity: AVAudioFrameCount(48_000 * seconds))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        if let samples = buffer.floatChannelData?[0] {
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = value * Float(sin(Double(frame) * 0.05))
            }
        }
        sink(buffer)
    }
}

/// One stereo buffer with different audio on each side.
private func stereoBuffer(left: Float, right: Float, seconds: Double = 1) -> AVAudioPCMBuffer? {
    guard
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(48_000 * seconds))
    else { return nil }
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
        let wave = Float(sin(Double(frame) * 0.05))
        buffer.floatChannelData?[0][frame] = left * wave
        buffer.floatChannelData?[1][frame] = right * wave
    }
    return buffer
}

private func tone(seconds: Double, level: Float = 0.4) -> [Float] {
    (0..<Int(16_000 * seconds)).map { Float(sin(Double($0) * 0.05)) * level }
}

func captureLivenessChecks(_ run: CheckRun) throws {
    run.section("Every channel reaches the track")

    let scratch = try Scratch.directory("liveness")

    // The converter used to keep the first channel and drop the rest.
    do {
        let rightOnly = try TrackWriter(url: scratch.appendingPathComponent("right-only.wav"))
        if let buffer = stereoBuffer(left: 0, right: 0.5) { rightOnly.append(buffer) }
        try rightOnly.close()
        run.expect(
            rightOnly.signal.peak > 0.1,
            "audio that is only on the second channel is kept, as a microphone on an interface's second input is")

        let leftOnly = try TrackWriter(url: scratch.appendingPathComponent("left-only.wav"))
        if let buffer = stereoBuffer(left: 0.5, right: 0) { leftOnly.append(buffer) }
        try leftOnly.close()
        run.expect(leftOnly.signal.peak > 0.1, "audio that is only on the first channel is still kept")

        let centred = try TrackWriter(url: scratch.appendingPathComponent("centred.wav"))
        if let buffer = stereoBuffer(left: 0.5, right: 0.5) { centred.append(buffer) }
        try centred.close()
        run.close(
            Double(centred.signal.peak), 0.5, 0.05,
            "speech in the middle of a stereo mix keeps its level when it becomes mono")
    }

    run.section("A track stays on the meeting's clock")

    do {
        let clock = ManualClock()
        let writer = try TrackWriter(url: scratch.appendingPathComponent("gap.wav"), clock: clock.clock)

        clock.advance(1)
        writer.append(samples: tone(seconds: 1))
        run.close(writer.secondsSinceLastFeed, 0, 0.001, "a source that just fed has fed just now")

        clock.advance(5)
        run.close(writer.secondsSinceLastFeed, 5, 0.001, "five seconds without audio is measured as five seconds")

        clock.advance(1)
        writer.append(samples: tone(seconds: 1))
        try writer.close()

        run.close(writer.duration, 7, 0.01, "a five second hole is kept as five seconds, so the track lasts as long as the meeting")
        run.close(writer.paddedSeconds, 5, 0.01, "the hole is written as digital silence")
        let read = try WAVReader.read(url: scratch.appendingPathComponent("gap.wav"))
        let samples = read.samples
        func window(_ from: Int, _ to: Int) -> ArraySlice<Float> {
            samples[min(from, samples.count)..<min(to, samples.count)]
        }
        let hole = window(16_000 * 3, 16_000 * 4)
        run.expect(
            hole.count == 16_000 && hole.allSatisfy { $0 == 0 },
            "the middle of the hole holds nothing but digital zero")
        run.expect(
            window(16_000 * 6, 16_000 * 7).contains { abs($0) > 0.1 },
            "the audio after the hole lands at the time it was said")
    }

    // Ordinary arrival jitter never inserts anything.
    do {
        let clock = ManualClock()
        let writer = try TrackWriter(url: scratch.appendingPathComponent("steady.wav"), clock: clock.clock)
        for _ in 0..<10 {
            clock.advance(0.5)
            writer.append(samples: tone(seconds: 0.5))
        }
        try writer.close()
        run.equal(writer.paddedSeconds, 0, "a source that feeds steadily is written as it came, with nothing added")
        run.close(writer.duration, 5, 0.001, "five seconds fed steadily is five seconds on disk")
    }

    // A rebuild closes a hole shorter than the pause threshold too.
    do {
        let clock = ManualClock()
        let writer = try TrackWriter(url: scratch.appendingPathComponent("rebuilt.wav"), clock: clock.clock)
        clock.advance(1)
        writer.append(samples: tone(seconds: 1))
        writer.sourceWasRebuilt()
        clock.advance(0.8)
        writer.append(samples: tone(seconds: 0.3))
        try writer.close()
        run.close(writer.duration, 1.8, 0.01, "the time a rebuild took is kept, so the lines after it are not moved earlier")
    }

    run.section("A microphone that changes or stops under a meeting")

    // The input changes under the meeting: plugging in a headset, or a call
    // switching a Bluetooth headset into its call mode.
    do {
        let clock = ManualClock()
        let microphone = ScriptedMicrophone()
        let capture = MicrophoneCapture(
            watchdogInterval: 0, starvationThreshold: 4, clock: clock.clock, source: { microphone })
        let url = scratch.appendingPathComponent("mic-changed.wav")

        try capture.start(writingTo: url)
        clock.advance(2)
        microphone.feed(value: 0.4, seconds: 2)

        capture.inputWasInterrupted()
        run.equal(microphone.startCount, 2, "a changed input is opened again straight away")
        run.expect(microphone.stopCount >= 1, "the input that stopped is torn down first")

        clock.advance(3)
        microphone.feed(value: 0.4, seconds: 1)
        let result = try capture.stop()

        run.expect(
            result.notes.contains { $0.contains("The input device changed") },
            "the change is named in the activity log")
        run.close(result.duration, 5, 0.1, "the time the input was away is kept, so the track still lasts the whole meeting")
        run.equal(capture.restartCount, 1, "one change is one reopen")
    }

    // The input stops feeding and nothing says so: no notification, no error,
    // and no samples for a level check to look at.
    do {
        let clock = ManualClock()
        let microphone = ScriptedMicrophone()
        let capture = MicrophoneCapture(
            watchdogInterval: 0, starvationThreshold: 4, maximumRestarts: 2, clock: clock.clock,
            source: { microphone })

        try capture.start(writingTo: scratch.appendingPathComponent("mic-starved.wav"))
        clock.advance(1)
        microphone.feed(value: 0.4, seconds: 1)

        clock.advance(3)
        capture.checkForStalledInput()
        run.equal(microphone.startCount, 1, "three seconds without audio is not yet a stopped input")
        run.expect(!capture.isStarved, "and is not yet reported as one")

        clock.advance(2)
        run.expect(capture.isStarved, "five seconds without any audio is reported while the meeting runs")
        capture.checkForStalledInput()
        run.equal(microphone.startCount, 2, "an input that stopped feeding is reopened")
        run.expect(
            capture.notes.contains { $0.contains("No audio arrived from the microphone for 5 seconds") },
            "the reopen says how long nothing arrived")

        clock.advance(5)
        capture.checkForStalledInput()
        run.equal(microphone.startCount, 3, "a second reopen is allowed")
        clock.advance(5)
        capture.checkForStalledInput()
        clock.advance(5)
        capture.checkForStalledInput()
        run.equal(microphone.startCount, 3, "the reopens in a row are bounded")
        run.equal(
            capture.notes.filter { $0.contains("has stopped trying") }.count, 1,
            "giving up is said once, not on every look")

        // Audio coming back proves the input works, so the count starts again.
        microphone.feed(value: 0.4, seconds: 1)
        clock.advance(5)
        capture.checkForStalledInput()
        run.equal(microphone.startCount, 4, "once audio arrives again, a later stop is reopened again")

        clock.advance(6)
        let result = try capture.stop()
        run.expect(
            result.notes.contains { $0.contains("for the last") },
            "a meeting whose microphone ended silent says so in the write-up")
        run.equal(microphone.stopCount, microphone.startCount, "every input that was opened was also closed")
    }

    // Stop landing while a reopen is opening the input.
    do {
        let microphone = ScriptedMicrophone()
        let capture = MicrophoneCapture(watchdogInterval: 0, source: { microphone })
        try capture.start(writingTo: scratch.appendingPathComponent("mic-stop-race.wav"))
        microphone.feed(value: 0.4, seconds: 0.5)
        microphone.whileStarting = { _ = try? capture.stop() }
        capture.inputWasInterrupted()
        microphone.whileStarting = nil
        run.equal(
            microphone.stopCount, microphone.startCount,
            "an input reopened as the meeting stopped is closed, so no microphone outlives the meeting")
    }

    run.section("A system audio tap that stops or changes")

    // A tap that stops delivering anything at all, not even digital zero.
    do {
        let clock = ManualClock()
        let source = ScriptedSystemAudioSource()
        let capture = SystemAudioCapture(
            policy: TapRebuildPolicy(silenceThreshold: 30, maximumRebuilds: 3),
            watchdogInterval: 0, starvationThreshold: 3, clock: clock.clock,
            watchesOutputDevice: false, source: { source })

        try capture.start(writingTo: scratch.appendingPathComponent("tap-starved.wav"))
        clock.advance(1)
        source.feed(value: 0.5, seconds: 1)
        clock.advance(4)
        run.expect(capture.isStarved, "a tap that delivers nothing is reported while the meeting runs")
        capture.checkForStalledTap()
        run.equal(source.startCount, 2, "a tap that stopped delivering is rebuilt")
        run.equal(capture.rebuildCount, 1, "the rebuild is counted")
        run.expect(
            capture.notes.contains { $0.contains("not even silence") },
            "the rebuild says nothing at all arrived, which is not the same as a quiet meeting")
        _ = try capture.stop()
    }

    // The output device changing its sample rate.
    do {
        let source = FakeSystemAudioSource(value: 0.4, seconds: 0.5)
        let capture = SystemAudioCapture(watchdogInterval: 0, watchesOutputDevice: false, source: { source })
        try capture.start(writingTo: scratch.appendingPathComponent("rate-change.wav"))
        capture.rebuildForOutputFormatChange()
        let result = try capture.stop()
        run.equal(source.startCount, 2, "a sample rate change rebuilds the tap, so the audio is read at the new rate")
        run.expect(
            result.notes.contains { $0.contains("changed its sample rate") },
            "the change is named in the activity log")
        run.equal(capture.rebuildCount, 0, "a rate change is a normal event and is not counted as a stalled tap")
    }

    // The budget is for rebuilds in a row that brought nothing back.
    do {
        var policy = TapRebuildPolicy(silenceThreshold: 30, maximumRebuilds: 3)
        var signal = SignalCheck()
        for _ in 0..<3 {
            signal.observe([Float](repeating: 0, count: 16_000 * 31))
            if policy.shouldRebuild(signal: signal) { policy.recordRebuild(signal: signal) }
        }
        run.expect(policy.isExhausted, "three quiet stretches with nothing in between use up the attempts")

        signal.observe(tone(seconds: 2))
        run.expect(!policy.shouldRebuild(signal: signal), "sound is not a reason to rebuild")
        run.expect(!policy.isExhausted, "sound after the rebuilds proves the tap works, so the attempts start again")

        signal.observe([Float](repeating: 0, count: 16_000 * 31))
        run.expect(
            policy.shouldRebuild(signal: signal),
            "a tap that fails later in the meeting is still rebuilt, after quiet stretches earlier on")
        policy.recordRebuild(signal: signal)
        run.equal(policy.rebuildCount, 1, "that rebuild is the first in a new row")
        run.equal(policy.totalRebuilds, 4, "every rebuild is still counted for the record")
    }

    run.section("The level meter")

    do {
        var signal = SignalCheck()
        signal.observe([Float](repeating: 0.8, count: 1_600))
        run.expect(signal.meterLevel > 0.7, "the meter shows a loud moment")
        for _ in 0..<10 { signal.observe([Float](repeating: 0.01, count: 1_600)) }
        run.expect(signal.meterLevel < 0.3, "the meter falls when the room goes quiet")
        run.close(Double(signal.peak), 0.8, 0.001, "the peak of the whole capture is still kept for the report")
    }
}
