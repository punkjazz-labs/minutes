#if DEBUG
import Foundation
import MinutesCore

/// A made-up notes folder for the screenshots. Every name and word in it is
/// invented. It is written with the same store the app writes with, so the
/// library reads it the way it reads a real one.
enum SnapshotFixtures {

    /// Writes the folder and returns the meeting the detail screenshot opens.
    static func writeLibrary(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // The day first and then the time of day, so a meeting set at 15:30
        // stays at 15:30 across a change to or from daylight saving time.
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        let featured = try write(
            in: root, title: "Pricing call with Northwind", date: at(0, 14, 0), minutes: 42,
            bullets: "- renewal terms\n- do they commit to Q4 volume?\n- who owns the follow-up",
            lines: pricingCall,
            notes: """
                ## Renewal

                - They want the renewal to start in October, on the current terms. [00:04:12]
                - They commit to Q4 volume only if list price holds through March. [00:07:10]
                - Discussed and not agreed: a 15% discount for a two-year term. [00:09:02]

                ## Follow-up

                - You offered to send the revised quote by Friday. [00:11:30]
                - Their finance lead joins the next call, date not set. [00:12:05] [00:31:40]

                ## Not anchored to the transcript

                - The board has already approved the budget.
                """)

        try write(
            in: root, title: "Weekly product sync", date: at(0, 10, 30), minutes: 28,
            bullets: "", lines: shortLines("We moved the launch to the twelfth."), notes: "## Launch\n\n- Launch moved to the 12th. [00:00:00]")
        try write(
            in: root, title: "1:1 with Sam", date: at(1, 16, 0), minutes: 31, bullets: "- feedback on the review",
            lines: shortLines("Can we talk about the review process?"), notes: nil,
            pending: "The notes endpoint at http://127.0.0.1:4000/v1 did not answer, so the transcript is saved and the notes are waiting.",
            bothSides: false)
        try write(
            in: root, title: "Design review: onboarding", date: at(1, 11, 0), minutes: 55, bullets: "",
            lines: shortLines("The second screen asks for too much."), notes: "## Decisions\n\n- Cut the second screen. [00:00:00]")
        try write(
            in: root, title: "Customer interview, Acme renewal", date: at(3, 15, 30), minutes: 47, bullets: "",
            lines: shortLines("The renewal depends on the integration."), notes: "## Renewal\n\n- Depends on the integration shipping. [00:00:00]")
        try write(
            in: root, title: "Hiring debrief", date: at(4, 9, 0), minutes: 22, bullets: "",
            lines: [], notes: nil, failed: "the model could not be loaded")
        try write(
            in: root, title: "Quarterly planning", date: at(12, 13, 0), minutes: 74, bullets: "",
            lines: shortLines("Three bets for the quarter."), notes: nil, writeNotes: false)
        return featured
    }

    /// One recording a crash left behind, with what was typed for it.
    static func writeInterruptedSession(in root: URL) throws -> RecoverableRecording? {
        let started = Date().addingTimeInterval(-26 * 3_600)
        let session = try RecordingSession.begin(
            in: root, startedAt: started,
            draft: MeetingDraft(title: "Vendor call", bullets: "- ask about the SLA"))
        let writer = try WAVWriter(url: session.audioURL(for: .me))
        let second = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        for _ in 0..<(23 * 60 + 14) { try writer.append(second) }
        try writer.close()
        return RecoverableRecording.read(session)
    }

    private static func shortLines(_ text: String) -> [TranscriptSegment] {
        [
            TranscriptSegment(track: .me, start: 0, end: 3, text: text),
            TranscriptSegment(track: .others, start: 4, end: 8, text: "Agreed, let us write that down."),
        ]
    }

    private static let pricingCall: [TranscriptSegment] = [
        TranscriptSegment(track: .me, start: 238, end: 246, text: "Thanks for making the time. I wanted to start with the renewal."),
        TranscriptSegment(track: .others, start: 252, end: 262, text: "Sure. We would like it to start in October, on the terms we have now."),
        TranscriptSegment(track: .me, start: 412, end: 418, text: "So where does that leave us on the Q4 numbers?"),
        TranscriptSegment(track: .others, start: 430, end: 440, text: "We can commit to the Q4 volume, but only if the pricing holds at list through March."),
        TranscriptSegment(track: .others, start: 441, end: 447, text: "Finance will not sign anything that moves after that."),
        TranscriptSegment(track: .me, start: 451, end: 455, text: "Through March. Noted."),
        TranscriptSegment(track: .others, start: 542, end: 552, text: "Is there room for fifteen percent if we sign for two years?"),
        TranscriptSegment(track: .me, start: 553, end: 560, text: "I can take that back, but I cannot promise it today."),
        TranscriptSegment(track: .me, start: 690, end: 698, text: "I will send the revised quote by Friday."),
        TranscriptSegment(track: .others, start: 725, end: 733, text: "Good. Our finance lead should be on the next call."),
        TranscriptSegment(track: .me, start: 734, end: 737, text: "Let us find a date for that."),
    ]

    @discardableResult
    private static func write(
        in root: URL, title: String, date: Date, minutes: Double, bullets: String,
        lines: [TranscriptSegment], notes: String?, pending: String? = nil, failed: String? = nil,
        bothSides: Bool = true, writeNotes: Bool = true
    ) throws -> URL {
        let store = MeetingStore(root: root)
        let directory = try store.createMeeting(title: title, date: date)
        let duration = minutes * 60
        try store.writeBullets(bullets, to: directory)
        try Transcript(
            segments: lines, engine: "FluidAudio Parakeet TDT (Core ML, Apple Neural Engine)",
            model: "FluidInference/parakeet-tdt-0.6b-v3-coreml", recordedAt: date, duration: duration,
            missingTracks: bothSides ? [] : [.others],
            failedTracks: failed.map { [TrackFailure(track: .me, reason: $0)] } ?? []
        ).markdown(title: title).write(to: directory.transcriptURL, atomically: true, encoding: .utf8)
        if writeNotes {
            try store.writeNotes(
                title: title, date: date, duration: duration, ownerNotes: bullets, body: notes,
                pendingReason: pending ?? (failed == nil ? nil : "The speech engine could not read this meeting."),
                transcriptionEngine: "FluidAudio Parakeet TDT", transcriptionModel: "parakeet-tdt-0.6b-v3-coreml",
                notesEndpoint: "http://127.0.0.1:4000/v1", notesModel: "profile/general", to: directory)
        }
        try store.writeMeta(
            MeetingMeta(
                title: title, startedAt: date, durationSeconds: duration,
                transcriptionEngine: "FluidAudio Parakeet TDT", transcriptionModel: "parakeet-tdt-0.6b-v3-coreml",
                notesEndpoint: "http://127.0.0.1:4000/v1", notesModel: "profile/general",
                notesState: notes == nil ? "pending" : "written",
                tracksRecorded: bothSides ? ["me", "others"] : ["me"], tracksMissing: bothSides ? [] : ["others"],
                tracksNotTranscribed: failed == nil ? [] : ["me"], transcriptionFailureReason: failed,
                audioKept: failed != nil),
            to: directory)
        return directory.url
    }
}
#endif
