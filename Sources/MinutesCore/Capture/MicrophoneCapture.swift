import AVFoundation
import Foundation

/// Whatever is feeding the owner's own track. The real one is `AVAudioEngine`
/// on the default input device; the checks use a scripted fake, which is why
/// this protocol exists. No check needs a microphone or a permission grant.
public protocol MicrophoneSource: AnyObject {

    /// The device being listened to, named for the activity log.
    var deviceName: String { get }

    /// Starts feeding buffers and returns the format they will arrive in.
    ///
    /// `onBuffer` is called on an audio thread. `onInterrupted` is called when
    /// the device or its format changed under the source and it stopped
    /// feeding, which is what plugging in a headset or a call switching a
    /// Bluetooth headset into its call mode does.
    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onInterrupted: @escaping @Sendable () -> Void
    ) throws -> AVAudioFormat

    /// Tears everything down. Safe to call when nothing was started.
    func stop()
}

/// Records the default input device to a 16 kHz mono WAV.
///
/// This is real: it opens the device, converts whatever format the device
/// gives to the one the speech engine wants, and writes samples to disk while
/// the meeting runs. It needs the microphone permission, which macOS only
/// grants to a signed app bundle, so running the bare binary from
/// `.build/debug` will be refused by the system.
///
/// An input that changes under a running meeting stops `AVAudioEngine` without
/// an error anywhere, and a level check cannot see it, because a source that
/// stopped feeding adds no samples to look at. So this type watches two
/// things the level check cannot: the engine saying its configuration changed,
/// which reopens the input straight away, and the track going without any
/// audio at all for a few seconds, which reopens it a bounded number of times
/// and then says so. Both are written into the activity log.
///
/// The conversion and the level measurement live in `TrackWriter`, shared with
/// the system audio tap, so both tracks of a meeting are written by the same
/// code and cannot drift apart.
public final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {

    public let track: AudioTrack = .me

    private let makeSource: @Sendable () -> any MicrophoneSource
    private let watchdogInterval: TimeInterval
    private let starvationThreshold: TimeInterval
    private let maximumRestarts: Int
    private let clock: TrackWriter.Clock
    private let work = DispatchQueue(label: "minutes.microphone.control")
    private let lock = NSLock()

    private var source: (any MicrophoneSource)?
    private var writer: TrackWriter?
    private var outputURL: URL?
    private var recording = false
    private var noteLines: [String] = []
    private var restartsSinceAudio = 0
    private var totalRestarts = 0
    private var framesAtLastRestart = 0
    private var deviceChanges = 0
    private var gaveUpReported = false
    private var watchdog: DispatchSourceTimer?

    /// - Parameters:
    ///   - watchdogInterval: how often to look for a source that stopped
    ///     feeding. Zero means no timer, which is how the checks drive the same
    ///     code without waiting for real time.
    ///   - starvationThreshold: seconds without any audio before the input is
    ///     reopened.
    ///   - maximumRestarts: reopens allowed in a row while nothing arrives. The
    ///     count starts again once audio does.
    ///   - clock: the clock the track is kept on.
    ///   - source: what feeds the track. The default is the real input device.
    public init(
        watchdogInterval: TimeInterval = 2,
        starvationThreshold: TimeInterval = 4,
        maximumRestarts: Int = 3,
        clock: @escaping TrackWriter.Clock = TrackWriter.systemClock,
        source: @escaping @Sendable () -> any MicrophoneSource = { EngineMicrophone() }
    ) {
        self.watchdogInterval = watchdogInterval
        self.starvationThreshold = starvationThreshold
        self.maximumRestarts = maximumRestarts
        self.clock = clock
        self.makeSource = source
    }

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

    public var notes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return noteLines
    }

    /// True while the input has handed over no audio at all for longer than
    /// the starvation threshold. The menu bar says so while it is true.
    public var isStarved: Bool {
        lock.lock()
        let writer = recording ? self.writer : nil
        lock.unlock()
        guard let writer else { return false }
        return writer.secondsSinceLastFeed >= starvationThreshold
    }

    /// How many times the input was reopened this meeting, for any reason.
    public var restartCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalRestarts
    }

    // MARK: - Permission

    public enum PermissionState: Equatable, Sendable {
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

        let writer = try TrackWriter(url: url, clock: clock)

        lock.lock()
        self.writer = writer
        self.outputURL = url
        self.noteLines = []
        self.restartsSinceAudio = 0
        self.framesAtLastRestart = 0
        self.totalRestarts = 0
        self.deviceChanges = 0
        self.gaveUpReported = false
        self.recording = true
        lock.unlock()

        do {
            try startSource()
        } catch {
            lock.lock()
            self.recording = false
            self.writer = nil
            lock.unlock()
            try? writer.close()
            try? FileManager.default.removeItem(at: url)
            if let refusal = error as? CaptureError { throw refusal }
            throw CaptureError.deviceFailure("The audio engine did not start: \(error.localizedDescription)")
        }

        startWatchdog()
    }

    public func stop() throws -> CaptureResult {
        lock.lock()
        let wasRecording = recording
        lock.unlock()
        guard wasRecording else { throw CaptureError.notRecording }

        watchdog?.cancel()
        watchdog = nil

        lock.lock()
        let source = self.source
        let writer = self.writer
        let url = self.outputURL
        self.source = nil
        // Cleared here as well, for the same reason the tap clears it: a
        // restart still opening the input on the work queue reads this to
        // decide whether it may feed anything.
        self.writer = nil
        self.recording = false
        lock.unlock()

        source?.stop()
        try writer?.close()

        guard let url, let writer else { throw CaptureError.notRecording }

        if let failure = writer.writeFailure {
            throw CaptureError.deviceFailure("Recording stopped after a write error: \(failure.localizedDescription)")
        }

        if writer.secondsSinceLastFeed >= starvationThreshold {
            let seconds = Int(writer.secondsSinceLastFeed.rounded())
            append(
                "No audio arrived from the microphone for the last \(seconds) seconds of the meeting. The recording holds what arrived before that."
            )
        }

        return CaptureResult(
            track: track, fileURL: url, duration: writer.duration, signal: writer.signal, notes: notes)
    }

    // MARK: - Reopening the input

    /// Looks at whether the input is still feeding and reopens it if it has
    /// stopped. Public so the checks can drive the same decision without
    /// waiting for real seconds to pass.
    public func checkForStalledInput() {
        lock.lock()
        guard recording, let writer else {
            lock.unlock()
            return
        }
        let silentFor = writer.secondsSinceLastFeed
        let fed = writer.signal.frameCount
        // Audio arrived since the last reopen, so the input works and the
        // budget starts again.
        if fed > framesAtLastRestart {
            restartsSinceAudio = 0
            gaveUpReported = false
        }
        let starved = silentFor >= starvationThreshold
        let allowed = restartsSinceAudio < maximumRestarts
        let alreadySaid = gaveUpReported
        if starved && !allowed && !alreadySaid { gaveUpReported = true }
        lock.unlock()

        guard starved else { return }
        if allowed {
            restart(because: .theInputStoppedFeeding(seconds: silentFor))
        } else if !alreadySaid {
            append(
                "The microphone was reopened \(maximumRestarts) times and still delivers nothing. minutes has stopped trying. Your side of the meeting is not being recorded until the input comes back."
            )
        }
    }

    /// Reopens the input after the engine said its configuration changed.
    /// Public for the same reason: the checks cannot plug in a headset.
    public func inputWasInterrupted() {
        lock.lock()
        guard recording else {
            lock.unlock()
            return
        }
        deviceChanges += 1
        let count = deviceChanges
        lock.unlock()
        restart(because: .theInputChanged(count: count))
    }

    private enum RestartReason {
        case theInputChanged(count: Int)
        case theInputStoppedFeeding(seconds: TimeInterval)
    }

    private func restart(because reason: RestartReason) {
        lock.lock()
        guard recording, let writer else {
            lock.unlock()
            return
        }
        totalRestarts += 1
        if case .theInputStoppedFeeding = reason {
            restartsSinceAudio += 1
            framesAtLastRestart = writer.signal.frameCount
        }
        let attempt = restartsSinceAudio
        let old = source
        source = nil
        lock.unlock()

        old?.stop()
        writer.sourceWasRebuilt()

        do {
            try startSource()
            lock.lock()
            let device = source?.deviceName ?? "the input device"
            lock.unlock()
            switch reason {
            case .theInputChanged(let count):
                append(
                    "The input device changed, change \(count) this meeting. The microphone was reopened on \(device), and the time it was away is kept as silence so the transcript stays in order."
                )
            case .theInputStoppedFeeding(let seconds):
                append(
                    "No audio arrived from the microphone for \(Int(seconds.rounded())) seconds. It was reopened on \(device), attempt \(attempt) of \(maximumRestarts)."
                )
            }
        } catch {
            lock.lock()
            let live = recording
            lock.unlock()
            if live {
                append(
                    "The microphone could not be reopened: \(error.localizedDescription). minutes will try again while the meeting runs."
                )
            }
        }
    }

    private func startSource() throws {
        let source = makeSource()
        lock.lock()
        let writer = self.writer
        let live = recording
        lock.unlock()
        guard live, let writer else { throw CaptureError.notRecording }

        let format = try source.start(
            onBuffer: { buffer in writer.append(buffer) },
            onInterrupted: { [weak self] in
                guard let self else { return }
                self.work.async { self.inputWasInterrupted() }
            })

        do {
            try writer.prepare(sourceFormat: format)
        } catch {
            source.stop()
            throw error
        }

        // A stop can land while the input is opening. The stop saw no source
        // to tear down, so this is the only place that can, and it does.
        lock.lock()
        let stillRecording = recording
        if stillRecording { self.source = source }
        lock.unlock()

        guard stillRecording else {
            source.stop()
            throw CaptureError.notRecording
        }
    }

    private func startWatchdog() {
        guard watchdogInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in self?.checkForStalledInput() }
        watchdog = timer
        timer.resume()
    }

    private func append(_ note: String) {
        lock.lock()
        noteLines.append(note)
        lock.unlock()
    }
}

/// The default input device through `AVAudioEngine`.
///
/// A fresh engine is made for every start, so a reopen after the device
/// changed never inherits the state of the engine that stopped.
public final class EngineMicrophone: MicrophoneSource, @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var running = false

    public init() {}

    public var deviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "the default input"
    }

    public func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onInterrupted: @escaping @Sendable () -> Void
    ) throws -> AVAudioFormat {
        let permission = MicrophoneCapture.permissionState
        if permission == .denied || permission == .restricted {
            throw CaptureError.permissionDenied(
                permission == .restricted
                    ? "Microphone access is restricted on this Mac."
                    : "macOS has denied microphone access to minutes. Turn it on in System Settings, Privacy and Security, Microphone."
            )
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.deviceFailure(
                "The default input device reported no channels. Pick an input in System Settings, Sound.")
        }

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            onBuffer(buffer)
        }

        // AVAudioEngine stops itself when the input changes under it, and this
        // notification is the only thing that says so.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onInterrupted() }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw CaptureError.deviceFailure("The audio engine did not start: \(error.localizedDescription)")
        }
        running = true
        return format
    }

    public func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        if running || engine.isRunning { engine.stop() }
        running = false
    }

    deinit { stop() }
}
