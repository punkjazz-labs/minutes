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

/// A source that feeds nothing on its own and feeds exactly what the check asks
/// for, whenever the check asks for it.
///
/// The fake above delivers one buffer at start, which cannot express a tap that
/// carried real audio for a while and then died. This one can.
final class ScriptedSystemAudioSource: SystemAudioSource, @unchecked Sendable {

    let outputDeviceName = "a scripted output device"

    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var starts = 0
    private var stops = 0
    /// Run by `start`, before the tap is handed back. This is how a check puts
    /// a stop in the middle of a tap starting up.
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

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        lock.lock()
        starts += 1
        sink = onBuffer
        lock.unlock()
        whileStarting?()
    }

    func stop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }

    /// Pushes one buffer of the awkward format a real tap delivers.
    func feed(value: Float, seconds: Double) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        guard
            let sink,
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(48_000 * seconds))
        else { return }

        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = value == 0 ? 0 : value
            }
        }
        sink(buffer)
    }
}

/// A source that refuses to close, so the checks can put a failed stop on one
/// track and look at what happened to the other.
final class RefusingCapture: AudioCapturing, @unchecked Sendable {

    let track: AudioTrack
    private(set) var stopCount = 0

    init(track: AudioTrack) {
        self.track = track
    }

    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }
    var signal: SignalCheck { SignalCheck() }

    func start(writingTo url: URL) throws {}

    func stop() throws -> CaptureResult {
        stopCount += 1
        throw CaptureError.deviceFailure("the fake source was told not to close")
    }
}

/// A source that closes cleanly and counts how often it was asked to.
final class CountingCapture: AudioCapturing, @unchecked Sendable {

    let track: AudioTrack
    private let url: URL
    private(set) var stopCount = 0

    init(track: AudioTrack, url: URL) {
        self.track = track
        self.url = url
    }

    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }
    var signal: SignalCheck { SignalCheck() }

    func start(writingTo url: URL) throws {}

    func stop() throws -> CaptureResult {
        stopCount += 1
        var signal = SignalCheck()
        signal.observe([Float](repeating: 0.4, count: 16_000))
        return CaptureResult(track: track, fileURL: url, duration: 1, signal: signal)
    }
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

    // A tap that carried a real meeting and then died. This is the exact case
    // the rebuild policy exists for, and the whole track is not digital zero,
    // so nothing about the whole track can see it.
    do {
        let url = scratch.appendingPathComponent("died-halfway.wav")
        let source = ScriptedSystemAudioSource()
        let capture = SystemAudioCapture(
            policy: TapRebuildPolicy(silenceThreshold: 0.2, maximumRebuilds: 2),
            watchdogInterval: 0,
            watchesOutputDevice: false,
            source: { source })

        try capture.start(writingTo: url)
        source.feed(value: 0.5, seconds: 1)
        source.feed(value: 0, seconds: 1)
        capture.checkForStalledTap()
        source.feed(value: 0, seconds: 1)
        capture.checkForStalledTap()
        source.feed(value: 0, seconds: 1)
        capture.checkForStalledTap()

        let result = try capture.stop()

        run.equal(capture.rebuildCount, 2, "a tap that went quiet is rebuilt up to the limit")
        run.expect(!result.signal.isAllZero, "the track is not digital zero, because it carried a real meeting")
        run.expect(
            result.notes.contains { $0.contains("rebuilt as often as minutes will try") },
            "a tap that died mid-meeting still says the retries are used up")
        run.equal(
            result.notes.filter { $0.contains("Nothing has been heard since") }.count, 1,
            "the retries notice is said once and not on every look")
        run.expect(
            result.notes.contains { $0.contains("went quiet for the rest of the meeting") },
            "the summary at stop says the track died rather than writing the meeting up as normal")
        run.expect(
            !result.notes.contains { $0.contains("Nothing was heard on the system audio track") },
            "a track that carried audio is not reported as having heard nothing")
    }

    // A stop that fails on one track still stops the other. This is the worst
    // failure the app can have: a tap that outlives Stop keeps recording what
    // the Mac plays while the menu bar says nothing is being recorded.
    do {
        let refusing = RefusingCapture(track: .me)
        let tap = CountingCapture(track: .others, url: scratch.appendingPathComponent("kept-going.wav"))

        let outcome = MeetingStop.everything(microphone: refusing, systemAudio: tap)

        run.equal(tap.stopCount, 1, "a microphone that will not close still stops the system audio tap")
        run.expect(outcome.ownCapture == nil, "a track that would not close is not offered as a recording")
        run.expect(
            outcome.missingTracks.contains(.me), "the track that would not close is named as missing")
        run.expect(
            outcome.failures.contains { $0.contains("Stopping the recording failed") },
            "the failed stop is said out loud rather than swallowed")

        // And the other way round, so neither track can be the one that is
        // skipped.
        let microphone = CountingCapture(track: .me, url: scratch.appendingPathComponent("own-track.wav"))
        let stubborn = RefusingCapture(track: .others)
        let second = MeetingStop.everything(microphone: microphone, systemAudio: stubborn)

        run.equal(microphone.stopCount, 1, "a tap that will not close still stops the microphone")
        run.expect(second.ownCapture != nil, "the track that did close is still a recording")
        run.expect(
            second.missingTracks.contains(.others), "the tap that would not close is named as missing")
    }

    // Starting a source that is already recording is refused, not ignored. A
    // silent return leaves the first meeting's writer and the first meeting's
    // file in place, and the next stop hands that file to the second meeting.
    do {
        let first = scratch.appendingPathComponent("first-meeting.wav")
        let second = scratch.appendingPathComponent("second-meeting.wav")
        let capture = SystemAudioCapture(
            watchdogInterval: 0,
            watchesOutputDevice: false,
            source: { FakeSystemAudioSource(value: 0.4, seconds: 0.2) })

        try capture.start(writingTo: first)
        do {
            try capture.start(writingTo: second)
            run.failed("starting a tap that is already recording must be refused")
        } catch {
            run.expect(true, "starting a tap that is already recording is refused")
            run.expect(
                error.localizedDescription.contains("already recording"),
                "the refusal says the recording that is running was left alone")
        }

        let result = try capture.stop()
        run.equal(
            result.fileURL, first,
            "one meeting's audio is never handed to the meeting that started after it")
    }

    // Stop landing while a rebuild is starting a tap. The rebuild has already
    // let go of the old source, so nothing but the rebuild itself can tear the
    // new one down.
    do {
        let url = scratch.appendingPathComponent("stop-during-rebuild.wav")
        let source = ScriptedSystemAudioSource()
        let capture = SystemAudioCapture(
            watchdogInterval: 0,
            watchesOutputDevice: false,
            source: { source })

        try capture.start(writingTo: url)
        source.feed(value: 0.5, seconds: 0.5)

        // The next tap to start finds the meeting already stopped under it.
        source.whileStarting = { _ = try? capture.stop() }
        capture.rebuildForOutputDeviceChange()
        source.whileStarting = nil

        run.equal(
            source.stopCount, source.startCount,
            "every tap that was started was also stopped, so no tap outlives the meeting")
        run.equal(
            capture.signal, SignalCheck(),
            "stop clears the writer, so a rebuild that finishes late has nothing to feed")
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
        // The converter is fed one buffer and then told there is no more. A box
        // that forgot it had been read would feed the same buffer for ever.
        run.close(
            Double(writer.signal.frameCount), 16_000, 1_400,
            "the converter is fed the buffer once and not again")
        let read = try WAVReader.read(url: url)
        run.equal(read.sampleRate, 16_000, "the file on disk is 16 kHz whatever the device gave")
    }
}
