import Foundation
import MinutesCore

/// Capture is behind an interface with a fixture behind it, so no check needs
/// a microphone or a permission grant.
func audioChecks(_ run: CheckRun) throws {
    run.section("Audio files and level checks")

    let scratch = try Scratch.directory("audio")

    // WAV round trip
    let toneURL = scratch.appendingPathComponent("tone.wav")
    let samples = (0..<1_600).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    let writer = try WAVWriter(url: toneURL)
    try writer.append(samples)
    try writer.close()

    let read = try WAVReader.read(url: toneURL)
    run.equal(read.sampleRate, 16_000, "a written WAV reads back at 16 kHz")
    run.equal(read.channels, 1, "a written WAV reads back as mono")
    run.equal(read.samples.count, samples.count, "no samples are lost in a round trip")
    run.close(read.duration, 0.1, 0.001, "duration comes from the frame count")
    let worstError = zip(samples, read.samples).map { abs($0 - $1) }.max() ?? 1
    run.expect(worstError < 0.001, "sample values survive the round trip")

    // The all-zero detector, the failure the spec calls out.
    var silent = SignalCheck()
    silent.observe([Float](repeating: 0, count: 16_000))
    run.expect(silent.isAllZero, "the all-zero detector fires on a silent capture")

    var quiet = SignalCheck()
    quiet.observe((0..<16_000).map { index in Float(index % 7 == 0 ? 0.001 : -0.0005) })
    run.expect(!quiet.isAllZero, "a quiet room with a noise floor does not read as no signal")

    var stalled = SignalCheck()
    stalled.observe([0.4, 0.3])
    stalled.observe([Float](repeating: 0, count: 16_000 * 9))
    run.expect(
        !stalled.hasStalled(sampleRate: AudioFormat.sampleRate, forSeconds: 10),
        "nine seconds of zeros is not yet a stall")
    stalled.observe([Float](repeating: 0, count: 16_000 * 2))
    run.expect(
        stalled.hasStalled(sampleRate: AudioFormat.sampleRate, forSeconds: 10),
        "eleven seconds of zeros after real audio is a stall")
    run.expect(!stalled.isAllZero, "a stall is reported separately from an empty capture")

    // Fixture capture
    let micURL = scratch.appendingPathComponent("mic.wav")
    let capture = FixtureCapture(track: .me, samples: [Float](repeating: 0.25, count: 8_000))
    try capture.start(writingTo: micURL)
    let result = try capture.stop()
    run.equal(result.track, .me, "the fixture reports its own track")
    run.close(result.duration, 0.5, 0.001, "the fixture reports its duration")
    run.expect(FileManager.default.fileExists(atPath: micURL.path), "the fixture writes a real file")
    run.expect(result.summary.contains("peak level"), "a good capture reports its peak level")

    let silentURL = scratch.appendingPathComponent("silent.wav")
    let silentCapture = FixtureCapture(track: .me, samples: [Float](repeating: 0, count: 8_000))
    try silentCapture.start(writingTo: silentURL)
    let silentResult = try silentCapture.stop()
    run.expect(silentResult.signal.isAllZero, "a silent capture is detected")
    run.expect(silentResult.summary.contains("Nothing was heard"), "a silent capture says nothing was heard")

    // System audio is a real Core Audio tap now. It cannot claim to know
    // whether macOS granted the permission, because there is no API to ask.
    let systemAudio = SystemAudioCapture()
    run.expect(systemAudio.isAvailable, "system audio is attempted rather than refused")
    run.equal(systemAudio.unavailableReason, nil, "there is no reason to give when the tap can be attempted")
    run.expect(
        SystemAudioCapture.permissionNotice.contains("never tells an app whether it was granted"),
        "the app says plainly that it cannot read this permission")
    run.equal(systemAudio.rebuildCount, 0, "a tap that has not run has rebuilt nothing")
}
