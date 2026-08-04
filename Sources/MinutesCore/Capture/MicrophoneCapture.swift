import AVFoundation
import Foundation

/// Records the default input device to a 16 kHz mono WAV.
///
/// This is real: it opens the device, converts whatever format the device
/// gives to the one the speech engine wants, and writes samples to disk while
/// the meeting runs. It needs the microphone permission, which macOS only
/// grants to a signed app bundle, so running the bare binary from
/// `.build/debug` will be refused by the system.
public final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {

    public let track: AudioTrack = .me

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var writer: WAVWriter?
    private var converter: AVAudioConverter?
    private var signalState = SignalCheck()
    private var outputURL: URL?
    private var recording = false
    private var writeFailure: Error?

    public init() {}

    public var isAvailable: Bool { unavailableReason == nil }

    public var unavailableReason: String? {
        switch MicrophoneCapture.permissionState {
        case .denied:
            return "macOS has denied microphone access to minutes. Turn it on in System Settings, Privacy and Security, Microphone."
        case .restricted:
            return "Microphone access is restricted on this Mac."
        case .granted, .undetermined:
            return nil
        }
    }

    public var signal: SignalCheck {
        lock.lock()
        defer { lock.unlock() }
        return signalState
    }

    // MARK: - Permission

    public enum PermissionState: Sendable {
        case undetermined
        case granted
        case denied
        case restricted
    }

    public static var permissionState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Asks macOS for the microphone. The prompt only appears for a signed
    /// bundle whose Info.plist carries NSMicrophoneUsageDescription.
    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Recording

    public func start(writingTo url: URL) throws {
        lock.lock()
        let alreadyRecording = recording
        lock.unlock()
        if alreadyRecording { return }

        if case .denied = MicrophoneCapture.permissionState {
            throw CaptureError.permissionDenied(unavailableReason ?? "Microphone access was denied.")
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.deviceFailure("The default input device reported no channels. Pick an input in System Settings, Sound.")
        }

        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioFormat.sampleRate,
                channels: AVAudioChannelCount(AudioFormat.channels),
                interleaved: false
            )
        else {
            throw CaptureError.deviceFailure("Could not describe the 16 kHz mono format the speech engine needs.")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.deviceFailure("Could not convert \(Int(inputFormat.sampleRate)) Hz input to 16 kHz mono.")
        }

        let writer = try WAVWriter(url: url)

        lock.lock()
        self.writer = writer
        self.converter = converter
        self.outputURL = url
        self.signalState = SignalCheck()
        self.writeFailure = nil
        self.recording = true
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, targetFormat: targetFormat)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock()
            self.recording = false
            self.writer = nil
            lock.unlock()
            try? writer.close()
            throw CaptureError.deviceFailure("The audio engine did not start: \(error.localizedDescription)")
        }
    }

    public func stop() throws -> CaptureResult {
        lock.lock()
        let wasRecording = recording
        lock.unlock()
        guard wasRecording else { throw CaptureError.notRecording }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let writer = self.writer
        let url = self.outputURL
        let signal = self.signalState
        let failure = self.writeFailure
        self.recording = false
        self.writer = nil
        self.converter = nil
        lock.unlock()

        try writer?.close()

        if let failure {
            throw CaptureError.deviceFailure("Recording stopped after a write error: \(failure.localizedDescription)")
        }
        guard let url, let writer else { throw CaptureError.notRecording }

        return CaptureResult(track: track, fileURL: url, duration: writer.duration, signal: signal)
    }

    // MARK: - Tap

    private func consume(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        lock.lock()
        guard recording, let converter, let writer else {
            lock.unlock()
            return
        }
        lock.unlock()

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))

        lock.lock()
        signalState.observe(samples)
        do {
            try writer.append(samples)
        } catch {
            writeFailure = error
        }
        lock.unlock()
    }
}
