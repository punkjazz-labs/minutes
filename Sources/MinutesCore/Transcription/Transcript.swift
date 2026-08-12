import Foundation

/// One stretch of speech on one track.
public struct TranscriptSegment: Sendable, Equatable, Codable {
    public let track: AudioTrack
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(track: AudioTrack, start: TimeInterval, end: TimeInterval, text: String) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
    }

    public var timecode: String { Timecode.string(from: start) }
}

public enum Timecode {
    public static func string(from seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    /// Reads a `HH:MM:SS` timecode back. Nil for anything that is not one, so a
    /// square bracket in ordinary prose is never mistaken for an anchor.
    public static func seconds(from text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var total = 0
        for part in parts {
            guard part.count == 2, let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return TimeInterval(total)
    }

    /// The form shown on an anchor chip. The hour is dropped when it is zero,
    /// because most meetings never reach one.
    public static func short(_ timecode: String) -> String {
        timecode.hasPrefix("00:") ? String(timecode.dropFirst(3)) : timecode
    }
}

/// A whole meeting's speech, plus the honest provenance of it.
public struct Transcript: Sendable, Equatable {
    public var segments: [TranscriptSegment]
    public var engine: String
    public var model: String
    public var recordedAt: Date
    public var duration: TimeInterval
    /// Tracks that never ran, named on the page rather than left out.
    public var missingTracks: [AudioTrack]
    /// Tracks that ran and carried nothing but digital zero. Said separately
    /// from a track that never ran, because they are different facts and the
    /// owner can act on them differently.
    public var silentTracks: [AudioTrack]

    public init(
        segments: [TranscriptSegment],
        engine: String,
        model: String,
        recordedAt: Date,
        duration: TimeInterval,
        missingTracks: [AudioTrack] = [],
        silentTracks: [AudioTrack] = []
    ) {
        self.segments = segments.sorted { $0.start < $1.start }
        self.engine = engine
        self.model = model
        self.recordedAt = recordedAt
        self.duration = duration
        self.missingTracks = missingTracks
        self.silentTracks = silentTracks
    }

    /// True when both sides of the meeting were actually heard. The warning
    /// about one side only is driven by this, so it disappears when the second
    /// track carried signal and never merely because a second track existed.
    public var bothSidesWereHeard: Bool {
        AudioTrack.allCases.allSatisfy { track in
            !missingTracks.contains(track) && !silentTracks.contains(track)
        }
    }

    public var plainText: String {
        segments.map { "[\($0.timecode)] \($0.track.label): \($0.text)" }.joined(separator: "\n")
    }

    /// The file written to the meeting directory.
    public func markdown(title: String) -> String {
        var lines: [String] = []
        lines.append("# Transcript: \(title)")
        lines.append("")
        lines.append("Recorded \(Transcript.dateFormatter.string(from: recordedAt)), \(Timecode.string(from: duration)) long.")
        lines.append("Transcribed on this Mac by \(engine) using \(model).")
        lines.append("Speaker labels come from which device the audio arrived on, not from voice recognition.")
        for track in missingTracks {
            lines.append("No audio was recorded on the \(track.label) track.")
        }
        for track in silentTracks where !missingTracks.contains(track) {
            lines.append(
                "The \(track.label) track was recorded but every sample was digital zero, so nothing was heard on it.")
        }
        lines.append("")
        if segments.isEmpty {
            lines.append("No speech was recognised in this recording.")
        } else {
            for segment in segments {
                lines.append("[\(segment.timecode)] \(segment.track.label): \(segment.text)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
