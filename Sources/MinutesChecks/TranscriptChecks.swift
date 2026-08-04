import Foundation
import MinutesCore

/// Segment arithmetic, timestamps and two-track labelling are deterministic
/// against fixed token timings, so no model runs here.
func transcriptChecks(_ run: CheckRun) {
    run.section("Transcript arithmetic")

    func tokens(_ items: [(String, Double, Double)]) -> [TimedToken] {
        items.map { TimedToken(text: $0.0, start: $0.1, end: $0.2) }
    }

    let joined = SegmentBuilder.text(
        from: tokens([
            ("\u{2581}We", 0, 0.2), ("\u{2581}ship", 0.2, 0.4), ("ped", 0.4, 0.5), ("\u{2581}it", 0.5, 0.6),
        ]))
    run.equal(joined, "We shipped it", "word boundary markers become spaces and sub-words join")

    let split = SegmentBuilder.segments(
        from: tokens([
            ("\u{2581}Hello", 0, 0.4),
            ("\u{2581}there", 0.4, 0.8),
            ("\u{2581}Right", 3.0, 3.4),
            ("\u{2581}then", 3.4, 3.8),
        ]),
        track: .me)
    run.equal(split.count, 2, "a silence longer than the gap starts a new line")
    run.equal(split.first?.text ?? "", "Hello there", "the first line holds the first phrase")
    run.close(split.last?.start ?? -1, 3.0, 0.0001, "the second line starts when speech resumed")
    run.expect(split.allSatisfy { $0.track == .me }, "every line carries the track it came from")

    let sentences = SegmentBuilder.segments(
        from: tokens([("\u{2581}Done.", 0, 0.4), ("\u{2581}Next", 0.5, 0.9)]), track: .others)
    run.equal(sentences.count, 2, "a full stop starts a new line")

    var long: [(String, Double, Double)] = []
    var time = 0.0
    for index in 0..<200 {
        long.append(("\u{2581}word\(index)", time, time + 0.2))
        time += 0.2
    }
    let brokenUp = SegmentBuilder.segments(from: tokens(long), track: .me)
    run.expect(brokenUp.count > 1, "continuous speech is broken into readable lines")
    run.expect(brokenUp.allSatisfy { $0.end - $0.start <= 18.5 }, "no line runs longer than the limit")

    let fallback = SegmentBuilder.singleSegment(text: "  a whole meeting  ", track: .me, duration: 90)
    run.equal(fallback.count, 1, "an engine with no timings still produces a line")
    run.equal(fallback.first?.text ?? "", "a whole meeting", "the fallback line is trimmed")

    run.equal(Timecode.string(from: 0), "00:00:00", "timecode at zero")
    run.equal(Timecode.string(from: 83), "00:01:23", "timecode under an hour")
    run.equal(Timecode.string(from: 3_723), "01:02:03", "timecode over an hour")

    let transcript = Transcript(
        segments: [
            TranscriptSegment(track: .others, start: 2, end: 3, text: "And on pricing?"),
            TranscriptSegment(track: .me, start: 0, end: 1, text: "Let us start."),
        ],
        engine: "fixture",
        model: "golden",
        recordedAt: Date(timeIntervalSince1970: 0),
        duration: 10,
        missingTracks: [.others])
    let markdown = transcript.markdown(title: "Pricing call")
    run.expect(markdown.contains("[00:00:00] You: Let us start."), "your track is labelled You")
    run.expect(markdown.contains("[00:00:02] Others: And on pricing?"), "the other track is labelled Others")
    run.expect(markdown.contains("not from voice recognition"), "the transcript says where the labels come from")
    run.expect(markdown.contains("No audio was recorded on the Others track."), "a missing track is named")
    if let first = markdown.range(of: "You: Let us start."), let second = markdown.range(of: "Others: And on pricing?") {
        run.expect(first.lowerBound < second.lowerBound, "the two tracks are interleaved by time")
    } else {
        run.failed("both track lines are present")
    }

    let measured = TranscriptionOutput(segments: [], audioDuration: 60, processingTime: 2)
    run.close(measured.realtimeFactor, 30, 0.0001, "the realtime factor is computed from measured times")
    run.equal(
        TranscriptionOutput(segments: [], audioDuration: 60, processingTime: 0).realtimeFactor, 0,
        "no processing time means no claim about speed")
}
