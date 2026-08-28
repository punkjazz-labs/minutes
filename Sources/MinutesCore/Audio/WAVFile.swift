import Foundation

public enum WAVError: Error, LocalizedError {
    case notRIFF
    case unsupportedFormat(String)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .notRIFF: return "That file is not a RIFF WAVE file."
        case .unsupportedFormat(let detail): return "Unsupported WAV format: \(detail)."
        case .truncated: return "The WAV file ends in the middle of a chunk."
        }
    }
}

/// The one audio format this app records and transcribes: 16 kHz, mono,
/// 16-bit signed little endian. Parakeet and whisper.cpp both want 16 kHz.
public enum AudioFormat {
    public static let sampleRate: Double = 16_000
    public static let channels: Int = 1
    public static let bitsPerSample: Int = 16
}

/// Appends 16-bit PCM to a WAV file and rewrites the header sizes after every
/// append, so a recording that is still running is already a readable file up
/// to its last flush and a crash costs only the samples that were never
/// written.
///
/// The header is 44 bytes and every append already knows the running frame
/// count, so keeping it true costs two seeks and a short write per buffer. The
/// alternative was a header that says zero frames until `close()` runs, which
/// makes a force quit, a crash or a power cut during a meeting cost the whole
/// recording.
public final class WAVWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private let channels: Int
    private var framesWritten: Int = 0
    private var closed = false

    public private(set) var url: URL

    public init(url: URL, sampleRate: Int = Int(AudioFormat.sampleRate), channels: Int = AudioFormat.channels) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WAVWriter.header(sampleRate: sampleRate, channels: channels, frames: 0))
    }

    public var frameCount: Int { framesWritten }
    public var duration: TimeInterval { Double(framesWritten) / Double(sampleRate) }

    /// Writes float samples in -1...1. Values outside that range are clamped
    /// rather than wrapped, because wrapping turns a loud passage into noise.
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * 32_767.0)
            let unsigned = UInt16(bitPattern: value)
            bytes.append(UInt8(unsigned & 0xFF))
            bytes.append(UInt8((unsigned >> 8) & 0xFF))
        }
        try handle.write(contentsOf: Data(bytes))
        framesWritten += samples.count / channels
        try patchHeader()
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        try patchHeader()
        try handle.close()
    }

    /// Rewrites the two size fields, which is the whole header, and puts the
    /// write position back where the next append needs it.
    private func patchHeader() throws {
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVWriter.header(sampleRate: sampleRate, channels: channels, frames: framesWritten))
        try handle.seek(toOffset: end)
    }

    deinit {
        if !closed { try? handle.close() }
    }

    static func header(sampleRate: Int, channels: Int, frames: Int) -> Data {
        let bitsPerSample = AudioFormat.bitsPerSample
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = frames * blockAlign

        var data = Data()
        func appendString(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func appendUInt32(_ value: Int) {
            let v = UInt32(truncatingIfNeeded: value)
            data.append(contentsOf: [
                UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF),
            ])
        }
        func appendUInt16(_ value: Int) {
            let v = UInt16(truncatingIfNeeded: value)
            data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
        }

        appendString("RIFF")
        appendUInt32(36 + dataBytes)
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)  // PCM
        appendUInt16(channels)
        appendUInt32(sampleRate)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendString("data")
        appendUInt32(dataBytes)
        return data
    }
}

/// Minimal WAV reader for 16-bit PCM. Enough for fixtures and for handing
/// samples to the speech engine without pulling in AVFoundation.
public enum WAVReader {

    public struct Audio: Sendable {
        public let samples: [Float]
        public let sampleRate: Int
        public let channels: Int

        public var duration: TimeInterval {
            guard sampleRate > 0, channels > 0 else { return 0 }
            return Double(samples.count / channels) / Double(sampleRate)
        }
    }

    public static func read(url: URL) throws -> Audio {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    public static func read(data: Data) throws -> Audio {
        guard data.count >= 12 else { throw WAVError.truncated }
        guard string(data, 0, 4) == "RIFF", string(data, 8, 4) == "WAVE" else { throw WAVError.notRIFF }

        var offset = 12
        var sampleRate = 0
        var channels = 0
        var bitsPerSample = 0
        var formatTag = 0
        var pcm: Data?

        while offset + 8 <= data.count {
            let chunkID = string(data, offset, 4)
            let declaredSize = Int(uint32(data, offset + 4))
            let body = offset + 8

            // A recording that was interrupted before its header was patched
            // says zero here. The samples are on the disk, so the rest of the
            // file is the recording. Reading it back is better than refusing a
            // whole meeting whose audio is sitting there.
            let chunkSize =
                (chunkID == "data" && declaredSize == 0) ? max(0, data.count - body) : declaredSize
            guard body + chunkSize <= data.count || chunkID == "data" else { throw WAVError.truncated }

            if chunkID == "fmt " {
                formatTag = Int(uint16(data, body))
                channels = Int(uint16(data, body + 2))
                sampleRate = Int(uint32(data, body + 4))
                bitsPerSample = Int(uint16(data, body + 14))
            } else if chunkID == "data" {
                let available = min(chunkSize, data.count - body)
                pcm = data.subdata(in: body..<(body + available))
            }

            offset = body + chunkSize + (chunkSize % 2)
        }

        guard let pcm else { throw WAVError.truncated }
        guard formatTag == 1 else { throw WAVError.unsupportedFormat("format tag \(formatTag), only PCM is read") }
        guard bitsPerSample == 16 else { throw WAVError.unsupportedFormat("\(bitsPerSample) bits per sample") }
        guard channels > 0, sampleRate > 0 else { throw WAVError.unsupportedFormat("channel or rate field is zero") }

        var samples = [Float]()
        samples.reserveCapacity(pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index + 1 < bytes.count {
                let value = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                samples.append(Float(value) / 32_768.0)
                index += 2
            }
        }
        return Audio(samples: samples, sampleRate: sampleRate, channels: channels)
    }

    private static func string(_ data: Data, _ offset: Int, _ length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        return String(decoding: data.subdata(in: offset..<(offset + length)), as: UTF8.self)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let b = [UInt8](data.subdata(in: offset..<(offset + 4)))
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let b = [UInt8](data.subdata(in: offset..<(offset + 2)))
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }
}
