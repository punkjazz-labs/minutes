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
public final class TrackWriter: @unchecked Sendable {

    private let lock = NSLock()
    private let writer: WAVWriter
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

    public init(url: URL) throws {
        guard let target = TrackWriter.targetFormat else {
            throw CaptureError.deviceFailure("Could not describe the 16 kHz mono format the speech engine needs.")
        }
        self.targetFormat = target
        self.writer = try WAVWriter(url: url)
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
        signalState.observe(samples)
        do {
            try writer.append(samples)
        } catch {
            failure = error
        }
    }

    /// Called when the source is rebuilt, so the next buffer builds a fresh
    /// converter even if the format looks the same.
    public func sourceWasRebuilt() {
        lock.lock()
        defer { lock.unlock() }
        converter = nil
        sourceFormat = nil
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
        converter = built
        sourceFormat = format
    }
}
