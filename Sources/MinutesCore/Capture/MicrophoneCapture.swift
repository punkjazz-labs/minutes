import AVFoundation
import Foundation

/// Records the default input device to a 16 kHz mono WAV.
///
/// This is real: it opens the device, converts whatever format the device
/// gives to the one the speech engine wants, and writes samples to disk while
/// the meeting runs. It needs the microphone permission, which macOS only
/// grants to a signed app bundle, so running the bare binary from
/// `.build/debug` will be refused by the system.
///
/// The conversion and the level measurement live in `TrackWriter`, shared with
/// the system audio tap, so both tracks of a meeting are written by the same
/// code and cannot drift apart.
public final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {

    public let track: AudioTrack = .me

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var writer: TrackWriter?
    private var outputURL: URL?
    private var recording = false

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
        return writer?.signal ?? SignalCheck()
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
        // The same refusal the tap makes, for the same reason: a silent return
        // starts a second meeting that keeps writing the first meeting's file.
        if alreadyRecording { throw CaptureError.alreadyRecording }

        if case .denied = MicrophoneCapture.permissionState {
            throw CaptureError.permissionDenied(unavailableReason ?? "Microphone access was denied.")
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.deviceFailure("The default input device reported no channels. Pick an input in System Settings, Sound.")
        }

        let writer = try TrackWriter(url: url)
        try writer.prepare(sourceFormat: inputFormat)

        lock.lock()
        self.writer = writer
        self.outputURL = url
        self.recording = true
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
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
        self.recording = false
        self.writer = nil
        lock.unlock()

        try writer?.close()

        guard let url, let writer else { throw CaptureError.notRecording }

        if let failure = writer.writeFailure {
            throw CaptureError.deviceFailure("Recording stopped after a write error: \(failure.localizedDescription)")
        }

        return CaptureResult(track: track, fileURL: url, duration: writer.duration, signal: writer.signal)
    }

    // MARK: - Tap

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let writer = recording ? self.writer : nil
        lock.unlock()
        writer?.append(buffer)
    }
}
