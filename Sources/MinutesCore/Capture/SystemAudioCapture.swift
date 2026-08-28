import AVFoundation
import Foundation

/// System audio, meaning what the other people in the meeting say.
///
/// This is a Core Audio process tap on everything this Mac plays, minus this
/// app, mixed into the same 16 kHz mono WAV the microphone writes. It is not
/// ScreenCaptureKit and it is not a virtual output device: a tap observes the
/// output instead of rerouting it, so the owner keeps hearing the meeting, and
/// it uses its own permission category with no screen recording indicator.
/// Decision 0002, which the tap superseded, says why it is a tap. Decision 0004
/// says what it does when it goes quiet. Both are in docs/decisions.
///
/// Two things about this permission are unusual and shape the whole type.
/// macOS grants system audio recording silently: there is no API to ask
/// whether it was granted, no prompt this app can raise on demand, and a
/// refusal looks exactly like a meeting where nobody is talking. And taps have
/// been reported delivering nothing but digital zero after several minutes,
/// recoverable only by tearing the tap down and building it again.
///
/// So this type measures instead of assuming: every sample goes through
/// `SignalCheck`, a long unbroken run of digital zero rebuilds the tap a
/// bounded number of times, every rebuild is counted and said out loud, and a
/// track that carried nothing is reported as silent in exactly the way v0.1
/// reports a dead microphone. It is never written up as a recording that was
/// fine.
public final class SystemAudioCapture: AudioCapturing, @unchecked Sendable {

    public let track: AudioTrack = .others

    /// What the owner needs to know before recording, since the app cannot
    /// read this permission and must not pretend it can.
    public static let permissionNotice =
        "macOS asks for permission to record what your Mac plays the first time, and never tells an app whether it was granted. minutes measures the track instead: if nothing is heard, it says so rather than saving a silent file that looks like a recording."

    private let makeSource: @Sendable () -> any SystemAudioSource
    private let watchdogInterval: TimeInterval
    private let watchesOutputDevice: Bool
    private let work = DispatchQueue(label: "minutes.system-audio.control")
    private let lock = NSLock()

    private var policy: TapRebuildPolicy
    private var source: (any SystemAudioSource)?
    private var writer: TrackWriter?
    private var outputURL: URL?
    private var recording = false
    private var noteLines: [String] = []
    private var deviceChanges = 0
    private var exhaustedReported = false
    private var watchdog: DispatchSourceTimer?
    private var deviceWatcher: DefaultOutputDeviceWatcher?

    /// - Parameters:
    ///   - policy: when to rebuild a tap that has gone quiet.
    ///   - watchdogInterval: how often to look. Zero means no timer, which is
    ///     how the checks drive the same code without waiting for real time.
    ///   - watchesOutputDevice: whether to ask Core Audio to report output
    ///     device changes. False in the checks, so nothing in the default suite
    ///     touches the audio hardware at all.
    ///   - source: what feeds the track. The default is the real tap.
    public init(
        policy: TapRebuildPolicy = TapRebuildPolicy(),
        watchdogInterval: TimeInterval = 5,
        watchesOutputDevice: Bool = true,
        source: @escaping @Sendable () -> any SystemAudioSource = { CoreAudioProcessTap() }
    ) {
        self.policy = policy
        self.watchdogInterval = watchdogInterval
        self.watchesOutputDevice = watchesOutputDevice
        self.makeSource = source
    }

    // MARK: - What the owner is told

    /// A tap can always be attempted. Whether macOS actually feeds it is not
    /// knowable in advance, which is what the signal check is for.
    public var isAvailable: Bool { true }

    public var unavailableReason: String? { nil }

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

    /// How many times the tap was torn down and built again this meeting.
    public var rebuildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return policy.rebuildCount
    }

    /// How many times the Mac changed output device mid-meeting.
    public var outputDeviceChangeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deviceChanges
    }

    // MARK: - Recording

    public func start(writingTo url: URL) throws {
        lock.lock()
        let alreadyRecording = recording
        lock.unlock()
        // Refused, not ignored. A silent return here says the second meeting
        // is being recorded while the tap still holds the first meeting's
        // writer and the first meeting's file, and the next stop hands that
        // file to the second meeting.
        if alreadyRecording { throw CaptureError.alreadyRecording }

        let writer = try TrackWriter(url: url)

        lock.lock()
        self.writer = writer
        self.outputURL = url
        self.noteLines = []
        self.deviceChanges = 0
        self.exhaustedReported = false
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
            throw CaptureError.deviceFailure(
                "The system audio tap did not start: \(error.localizedDescription)")
        }

        startWatchdog()
        startDeviceWatcher()
    }

    public func stop() throws -> CaptureResult {
        lock.lock()
        let wasRecording = recording
        lock.unlock()
        guard wasRecording else { throw CaptureError.notRecording }

        watchdog?.cancel()
        watchdog = nil
        deviceWatcher?.stop()
        deviceWatcher = nil

        lock.lock()
        let source = self.source
        let writer = self.writer
        let url = self.outputURL
        self.source = nil
        // The writer is cleared here as well. A rebuild that is still starting
        // a tap on the work queue reads this field to decide whether it is
        // allowed to feed anything, and a writer left in place tells it yes
        // after the meeting has ended.
        self.writer = nil
        self.recording = false
        lock.unlock()

        source?.stop()
        try? writer?.close()

        guard let writer, let url else { throw CaptureError.notRecording }

        let signal = writer.signal
        if signal.isAllZero {
            append(
                "Nothing was heard on the system audio track. Either nobody was playing sound on this Mac, or macOS never granted minutes permission to record what it plays. There is no way for an app to ask which, so this is reported and not guessed."
            )
        } else if tapIsSpent(signal: signal) {
            // The track carried audio and then stopped, and the rebuilds did
            // not bring it back. Saying nothing here writes that meeting up as
            // a normal one.
            append(
                "The system audio track carried audio and then went quiet for the rest of the meeting, after the tap was rebuilt as often as minutes will try. What was heard before that is in the transcript."
            )
        }
        if let failure = writer.writeFailure {
            append("The system audio track stopped being written: \(failure.localizedDescription)")
        }

        return CaptureResult(
            track: track,
            fileURL: url,
            duration: writer.duration,
            signal: signal,
            notes: notes)
    }

    // MARK: - Rebuilding

    /// Looks at what the track has carried and rebuilds the tap if it has been
    /// digital zero for long enough. Public so the checks can drive the same
    /// decision without waiting for a real thirty seconds to pass.
    public func checkForStalledTap() {
        lock.lock()
        guard recording, let writer else {
            lock.unlock()
            return
        }
        let signal = writer.signal
        let wanted = policy.shouldRebuild(signal: signal)
        let alreadySaid = exhaustedReported
        lock.unlock()

        if wanted {
            rebuild(because: .theTrackWentQuiet)
            return
        }

        // Say once, and only once, that the retries are used up and the track
        // is still carrying nothing.
        if !alreadySaid, tapIsSpent(signal: signal) {
            lock.lock()
            exhaustedReported = true
            lock.unlock()
            append(TapRebuildPolicy.exhaustedNotice)
        }
    }

    /// True when the tap was rebuilt as often as it will be and the track has
    /// been digital zero ever since.
    ///
    /// This is the state the rebuild policy exists for, and it is invisible to
    /// any measure of the whole track: a tap that carried two minutes of a
    /// meeting and then died has a peak above zero for the rest of that
    /// meeting, however dead it is now. What is left of the track is what says
    /// so.
    private func tapIsSpent(signal: SignalCheck) -> Bool {
        lock.lock()
        let exhausted = policy.isExhausted
        let threshold = policy.silenceThreshold
        lock.unlock()
        return exhausted
            && signal.hasStalled(sampleRate: AudioFormat.sampleRate, forSeconds: threshold)
    }

    /// Rebuilds around whatever the Mac is now playing through. Public for the
    /// same reason: the checks cannot connect a pair of AirPods.
    public func rebuildForOutputDeviceChange() {
        lock.lock()
        guard recording else {
            lock.unlock()
            return
        }
        deviceChanges += 1
        let count = deviceChanges
        lock.unlock()

        rebuild(because: .theOutputDeviceChanged(count))
    }

    private enum RebuildReason {
        case theTrackWentQuiet
        case theOutputDeviceChanged(Int)
    }

    private func rebuild(because reason: RebuildReason) {
        lock.lock()
        guard recording, let writer else {
            lock.unlock()
            return
        }
        let signal = writer.signal
        switch reason {
        case .theTrackWentQuiet:
            let seconds = Double(signal.trailingZeroFrames) / AudioFormat.sampleRate
            policy.recordRebuild(signal: signal)
            let notice = policy.rebuildNotice(seconds: seconds)
            lock.unlock()
            append(notice)
        case .theOutputDeviceChanged:
            lock.unlock()
        }

        lock.lock()
        let old = source
        source = nil
        lock.unlock()
        old?.stop()

        writer.sourceWasRebuilt()

        do {
            try startSource()
            if case .theOutputDeviceChanged(let count) = reason {
                lock.lock()
                let device = source?.outputDeviceName ?? "the new output device"
                lock.unlock()
                append(
                    "The Mac changed the device it plays through, change \(count) this meeting. The tap was rebuilt around \(device)."
                )
            }
        } catch {
            lock.lock()
            let live = recording
            lock.unlock()
            // A rebuild that was refused because the meeting ended under it is
            // not a fault to report. The meeting is over.
            if live {
                append(
                    "The system audio tap could not be rebuilt: \(error.localizedDescription). The rest of this meeting is microphone only."
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

        try source.start { buffer in
            writer.append(buffer)
        }

        // A stop can land while the tap above is starting. The stop saw no
        // source to tear down, so this is the only place that can tear the new
        // one down, and it does. A tap owned by an object that believes it is
        // not recording keeps a private aggregate device alive for the rest of
        // the process, so it is made impossible here rather than unlikely.
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
        timer.setEventHandler { [weak self] in self?.checkForStalledTap() }
        watchdog = timer
        timer.resume()
    }

    private func startDeviceWatcher() {
        guard watchesOutputDevice else { return }
        let watcher = DefaultOutputDeviceWatcher(queue: work)
        let started = watcher.start { [weak self] in
            self?.rebuildForOutputDeviceChange()
        }
        if started {
            deviceWatcher = watcher
        } else {
            append(
                "macOS refused to tell minutes when the output device changes, so connecting headphones mid-meeting may end the system audio track. The level meter and the report at the end still say what was actually recorded."
            )
        }
    }

    private func append(_ note: String) {
        lock.lock()
        noteLines.append(note)
        lock.unlock()
    }
}
