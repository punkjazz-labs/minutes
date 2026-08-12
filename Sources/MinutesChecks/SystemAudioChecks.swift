import AVFoundation
import Foundation
import MinutesCore

/// A system audio source that feeds exactly what the check asks it to feed.
///
/// No tap, no aggregate device, no permission and no sound card, which is the
/// point: the tap capture object, the rebuild counting, the conversion to
/// 16 kHz mono and the two-track write-up are all exercised on a machine that
/// has been granted nothing.
final class FakeSystemAudioSource: SystemAudioSource, @unchecked Sendable {

    let outputDeviceName = "a fake output device"

    private let value: Float
    private let seconds: Double
    private let failure: Error?
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    init(value: Float, seconds: Double = 1, failure: Error? = nil) {
        self.value = value
        self.seconds = seconds
        self.failure = failure
    }

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

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if let failure { throw failure }
        lock.lock()
        starts += 1
        lock.unlock()

        // A tap delivers 48 kHz stereo float, not the 16 kHz mono the speech
        // engine wants, so the fake delivers the awkward format on purpose.
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(48_000 * seconds))
        else { return }

        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = value == 0 ? 0 : value * Float(sin(Double(frame) * 0.01))
            }
        }
        onBuffer(buffer)
    }

    func stop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }
}

private struct FakeTapFailure: Error, LocalizedError {
    var errorDescription: String? { "the fake tap was told to fail" }
}

func systemAudioChecks(_ run: CheckRun) throws {
    run.section("System audio tap")

    let scratch = try Scratch.directory("system-audio")

    // The rebuild decision, driven to the frame with no clock and no device.
    do {
        var policy = TapRebuildPolicy(silenceThreshold: 30, maximumRebuilds: 3)
        var signal = SignalCheck()
        signal.observe([Float](repeating: 0, count: 16_000 * 29))
        run.expect(!policy.shouldRebuild(signal: signal), "twenty nine seconds of digital zero is not yet a rebuild")

        signal.observe([Float](repeating: 0, count: 16_000 * 2))
        run.expect(policy.shouldRebuild(signal: signal), "thirty one seconds of digital zero asks for a rebuild")

        policy.recordRebuild(signal: signal)
        run.equal(policy.rebuildCount, 1, "a rebuild is counted")
        run.expect(
            !policy.shouldRebuild(signal: signal),
            "the same run of zeros does not ask for a second rebuild straight away")

        signal.observe([Float](repeating: 0, count: 16_000 * 31))
        run.expect(policy.shouldRebuild(signal: signal), "another thirty seconds of zeros asks again")
        policy.recordRebuild(signal: signal)
        signal.observe([Float](repeating: 0, count: 16_000 * 31))
        policy.recordRebuild(signal: signal)
        signal.observe([Float](repeating: 0, count: 16_000 * 31))
        run.expect(policy.isExhausted, "the rebuilds are bounded")
        run.expect(!policy.shouldRebuild(signal: signal), "an exhausted policy stops churning the audio graph")

        var afterSound = TapRebuildPolicy(silenceThreshold: 1, maximumRebuilds: 3)
        var live = SignalCheck()
        live.observe([Float](repeating: 0, count: 16_000 * 2))
        run.expect(afterSound.shouldRebuild(signal: live), "silence before any sound still asks for a rebuild")
        afterSound.recordRebuild(signal: live)
        live.observe([0.3])
        run.expect(!afterSound.shouldRebuild(signal: live), "one real sample resets the run of zeros")
    }

    // A tap that is granted nothing: it rebuilds, it says so, and the track is
    // reported as silent rather than saved as a recording.
    do {
        let url = scratch.appendingPathComponent("silent-system.wav")
        let source = FakeSystemAudioSource(value: 0, seconds: 1)
        let capture = SystemAudioCapture(
            policy: TapRebuildPolicy(silenceThreshold: 0.2, maximumRebuilds: 2),
            watchdogInterval: 0,
            watchesOutputDevice: false,
            source: { source })

        try capture.start(writingTo: url)
        capture.checkForStalledTap()
        capture.checkForStalledTap()
        capture.checkForStalledTap()

        let result = try capture.stop()

        run.equal(capture.rebuildCount, 2, "an all-zero track rebuilds the tap up to the limit and no further")
        run.equal(source.startCount, 3, "each rebuild really did start a new tap")
        run.expect(source.stopCount >= 2, "each rebuild tore the old tap down first")
        run.expect(result.signal.isAllZero, "a tap that fed nothing is reported as all zero")
        run.expect(result.summary.contains("Nothing was heard"), "the silent track says nothing was heard")
        run.expect(
            result.notes.contains { $0.contains("Rebuilding the tap, attempt 1 of 2") },
            "the first rebuild is named in the notes")
        run.expect(
            result.notes.contains { $0.contains("attempt 2 of 2") },
            "the second rebuild is counted in the notes")
        run.expect(
            result.notes.contains { $0.contains("rebuilt as often as minutes will try") },
            "giving up is said out loud rather than hidden")
        run.expect(
            result.notes.contains { $0.contains("no way for an app to ask") },
            "the report says the permission cannot be queried instead of blaming the meeting")
        run.expect(result.track == .others, "the tap writes the other side's track")
    }

    // A tap that is fed real audio: no rebuilds, and the samples arrive as
    // 16 kHz mono however the device delivered them.
    do {
        let url = scratch.appendingPathComponent("live-system.wav")
        let source = FakeSystemAudioSource(value: 0.5, seconds: 1)
        let capture = SystemAudioCapture(
            policy: TapRebuildPolicy(silenceThreshold: 0.2, maximumRebuilds: 2),
            watchdogInterval: 0,
            watchesOutputDevice: false,
            source: { source })

        try capture.start(writingTo: url)
        capture.checkForStalledTap()
        let result = try capture.stop()

        run.equal(capture.rebuildCount, 0, "a tap that is carrying audio is left alone")
        run.expect(!result.signal.isAllZero, "a tap carrying audio is not reported as silent")
        run.expect(result.notes.isEmpty, "a tap with nothing to report says nothing")
        // A resampler holds a few tens of milliseconds back at the end of the
        // stream, so a second in is a second on disk minus that latency.
        run.close(result.duration, 1.0, 0.08, "one second in is one second on disk")

        let written = try WAVReader.read(url: url)
        run.equal(written.sampleRate, 16_000, "48 kHz stereo from the device lands as 16 kHz on disk")
        run.equal(written.channels, 1, "stereo from the device lands as mono on disk")
        run.expect(written.samples.contains { abs($0) > 0.1 }, "the audio itself survived the conversion")
    }

    // AirPods connecting mid-meeting.
    do {
        let url = scratch.appendingPathComponent("device-change.wav")
        let source = FakeSystemAudioSource(value: 0.4, seconds: 0.5)
        let capture = SystemAudioCapture(
            watchdogInterval: 0,
            watchesOutputDevice: false,
            source: { source })

        try capture.start(writingTo: url)
        capture.rebuildForOutputDeviceChange()
        let result = try capture.stop()

        run.equal(capture.outputDeviceChangeCount, 1, "an output device change is counted")
        run.equal(source.startCount, 2, "the tap is rebuilt around the new output device")
        run.expect(
            result.notes.contains { $0.contains("changed the device it plays through") },
            "the device change is named in the activity log")
        run.equal(capture.rebuildCount, 0, "a device change is not counted as a stalled tap")
    }

    // A tap that will not start at all refuses instead of leaving an empty file
    // that looks like a recording.
    do {
        let url = scratch.appendingPathComponent("never-started.wav")
        let capture = SystemAudioCapture(
            watchdogInterval: 0,
            watchesOutputDevice: false,
            source: { FakeSystemAudioSource(value: 0, failure: FakeTapFailure()) })
        do {
            try capture.start(writingTo: url)
            run.failed("a tap that cannot start must refuse")
        } catch {
            run.expect(true, "a tap that cannot start refuses")
            run.expect(
                error.localizedDescription.contains("did not start"),
                "the refusal says what happened")
        }
        run.expect(
            !FileManager.default.fileExists(atPath: url.path),
            "a tap that never started leaves no file behind")
        do {
            _ = try capture.stop()
            run.failed("stopping a tap that never ran must throw")
        } catch {
            run.expect(true, "stopping a tap that never ran throws")
        }
    }

    // The shared conversion, since both tracks now depend on it.
    do {
        let url = scratch.appendingPathComponent("converted.wav")
        let writer = try TrackWriter(url: url)
        guard
            let deviceFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
            let buffer = AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: 44_100)
        else {
            run.failed("the check could not build a device format")
            return
        }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = 0.6 * Float(sin(Double(frame) * 0.02))
            }
        }
        writer.append(buffer)
        try writer.close()

        run.close(writer.duration, 1.0, 0.08, "a second of 44.1 kHz audio is a second of 16 kHz audio")
        run.expect(writer.signal.peak > 0.1, "the level check sees the converted samples")
        run.expect(writer.writeFailure == nil, "the conversion wrote without an error")
        let read = try WAVReader.read(url: url)
        run.equal(read.sampleRate, 16_000, "the file on disk is 16 kHz whatever the device gave")
    }
}
