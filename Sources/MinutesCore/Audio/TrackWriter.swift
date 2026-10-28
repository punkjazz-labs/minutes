import AVFoundation
import Foundation

/// One track being written: whatever format the device hands over goes in,
/// 16 kHz mono PCM comes out on disk, and the level statistics are kept while
/// it happens.
///
/// The microphone and the system audio tap both write through this, so the
/// conversion, the clamping, the zero-run measurement and the file layout are
/// the same on both tracks. It also survives the source being torn down and
/// rebuilt mid-recording: the file stays open, and a new source format simply
/// builds a new converter, so a rebuilt tap appends to the same track instead
/// of starting a second file.
///
/// It also keeps the track on the meeting's clock. A source that was torn down
/// and rebuilt, or that stopped feeding for a while, leaves a hole in time that
/// a plain append would close up, and every line after it would then carry a
/// timestamp earlier than the moment it was said. The two tracks of a meeting
/// are merged by those timestamps, so a closed-up hole puts the other side's
/// words in front of yours. The hole is written as digital silence instead,
/// which is what the track actually carried during it.
public final class TrackWriter: @unchecked Sendable {

    /// A monotonic clock in seconds. The real one is the system uptime; the
    /// checks pass one they can move by hand.
    public typealias Clock = @Sendable () -> TimeInterval
    public static let systemClock: Clock = { ProcessInfo.processInfo.systemUptime }

    /// A pause in feeding at least this long is treated as a hole in time.
    public static let gapThreshold: TimeInterval = 1
    /// A hole shorter than this is left alone, because device clocks and the
    /// system clock disagree by that much over a long meeting anyway.
    public static let realignTolerance: TimeInterval = 0.2

    private let lock = NSLock()
    private let writer: WAVWriter
    private let clock: Clock
    private let startedAt: TimeInterval
    private var lastFedAt: TimeInterval?
    private var realignPending = false
    private var paddedFrames = 0
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var signalState = SignalCheck()
    private var failure: Error?
    private var closed = false

    /// The one format the speech engine accepts.
    public static var targetFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: AVAudioChannelCount(AudioFormat.channels),
            interleaved: false)
    }

    public let targetFormat: AVAudioFormat

    public init(url: URL, clock: @escaping Clock = TrackWriter.systemClock) throws {
        guard let target = TrackWriter.targetFormat else {
            throw CaptureError.deviceFailure("Could not describe the 16 kHz mono format the speech engine needs.")
        }
        self.targetFormat = target
        self.writer = try WAVWriter(url: url)
        self.clock = clock
        self.startedAt = clock()
    }

    public var url: URL { writer.url }

    public var signal: SignalCheck {
        lock.lock()
        defer { lock.unlock() }
        return signalState
    }

    public var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return writer.duration
    }

    public var writeFailure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// How long it has been since the source last handed over any audio, or
    /// since the track was opened when it never has. Digital silence counts as
    /// audio here: this measures whether the source is feeding at all, which a
    /// level check cannot see, because a source that stopped feeding adds no
    /// samples for any level check to look at.
    public var secondsSinceLastFeed: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return clock() - (lastFedAt ?? startedAt)
    }

    /// Seconds of digital silence written to keep the track on the meeting's
    /// clock across holes in feeding.
    public var paddedSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(paddedFrames) / AudioFormat.sampleRate
    }

    /// Builds the converter ahead of the first buffer, so a device that cannot
    /// be converted at all is refused at start instead of producing an empty
    /// file and a late error.
    public func prepare(sourceFormat format: AVAudioFormat) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try makeConverterLocked(for: format)
        } catch {
            throw CaptureError.deviceFailure(
                "Could not convert \(Int(format.sampleRate)) Hz, \(format.channelCount) channel audio to 16 kHz mono.")
        }
    }

    /// Converts and writes one buffer from a device. Safe to call from a Core
    /// Audio IO thread.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        do {
            try makeConverterLocked(for: buffer.format)
        } catch {
            failure = error
            lock.unlock()
            return
        }
        let converter = self.converter
        lock.unlock()

        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let input = OneBufferInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
            input.next(statusPointer)
        }

        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        append(samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }

    /// Writes samples that are already 16 kHz mono.
    public func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        do {
            try fillHoleLocked(before: samples.count)
            signalState.observe(samples)
            try writer.append(samples)
        } catch {
            failure = error
        }
    }

    /// Called when the source is rebuilt, so the next buffer builds a fresh
    /// converter even if the format looks the same, and lands where the
    /// meeting's clock says it belongs rather than straight after the last one.
    public func sourceWasRebuilt() {
        lock.lock()
        defer { lock.unlock() }
        converter = nil
        sourceFormat = nil
        realignPending = true
    }

    public func close() throws {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        try writer.close()
    }

    // MARK: - Internals

    /// The one buffer a conversion is fed, and the record of whether it has
    /// been fed yet.
    ///
    /// `AVAudioConverter` types its input block as `@Sendable`, and it calls
    /// that block from `convert` on the calling thread, before `convert`
    /// returns. So the buffer never crosses a thread and the flag never races.
    /// Swift 6 cannot read that guarantee out of the type, and the answer is to
    /// state the fact in one small box that is safe to hand over, rather than
    /// to silence every Sendable diagnostic from AVFAudio with a
    /// `@preconcurrency` import.
    private final class OneBufferInput: @unchecked Sendable {

        private let buffer: AVAudioPCMBuffer
        private var consumed = false

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
    }

    /// Writes the hole in time before a block that arrives after a rebuild or
    /// after a pause in feeding, as digital silence. Caller holds the lock.
    ///
    /// Only a rebuild or a real pause can trigger it, so ordinary jitter in
    /// when buffers arrive never inserts anything.
    private func fillHoleLocked(before incoming: Int) throws {
        let now = clock()
        let pause = now - (lastFedAt ?? startedAt)
        lastFedAt = now
        guard realignPending || pause >= TrackWriter.gapThreshold else { return }
        realignPending = false

        // The block that just arrived ends about now, so it starts this many
        // frames into the meeting.
        let expected = Int(((now - startedAt) * AudioFormat.sampleRate).rounded()) - incoming
        let behind = expected - writer.frameCount
        guard Double(behind) >= TrackWriter.realignTolerance * AudioFormat.sampleRate else { return }

        let silence = [Float](repeating: 0, count: behind)
        signalState.observe(silence)
        try writer.append(silence)
        paddedFrames += behind
    }

    /// Caller holds the lock.
    private func makeConverterLocked(for format: AVAudioFormat) throws {
        if let sourceFormat, sourceFormat == format, converter != nil { return }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.deviceFailure("The device reported no channels.")
        }
        guard let built = AVAudioConverter(from: format, to: targetFormat) else {
            throw CaptureError.deviceFailure(
                "Could not convert \(Int(format.sampleRate)) Hz, \(format.channelCount) channel audio to 16 kHz mono.")
        }
        // Without this the converter keeps the first channel and drops the
        // rest. The tap delivers stereo, and an interface can carry the
        // microphone on its second input, so dropping channels drops speech.
        if format.channelCount > 1 { built.downmix = true }
        converter = built
        sourceFormat = format
    }
}
