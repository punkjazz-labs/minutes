import Foundation
import MinutesCore

/// The arithmetic behind how the library and a meeting are laid out: day
/// headings, speaker turns, and finding words in a transcript.
func libraryLayoutChecks(_ run: CheckRun) {
    run.section("The library reads by day")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
    // Wednesday 28 October 2026, 15:00 in Rome.
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15))!
    func day(_ offset: Int, hour: Int = 10) -> Date {
        let start = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start)!
    }

    run.equal(MeetingDays.title(for: day(0), now: now, calendar: calendar), "Today", "a meeting from this morning is under Today")
    run.equal(MeetingDays.title(for: day(1), now: now, calendar: calendar), "Yesterday", "one from yesterday is under Yesterday")
    run.equal(MeetingDays.title(for: day(3), now: now, calendar: calendar), "Sunday", "one from this week is under its weekday")
    run.equal(
        MeetingDays.title(for: day(12), now: now, calendar: calendar), "Friday 16 October",
        "an older one is under its date")
    run.equal(
        MeetingDays.title(for: day(400), now: now, calendar: calendar), "23 September 2025",
        "one from another year says the year")

    let meetings = [day(0, hour: 14), day(1), day(0, hour: 9), day(12)]
    let groups = MeetingDays.group(meetings, date: { $0 }, now: now, calendar: calendar)
    run.equal(groups.map(\.title), ["Today", "Yesterday", "Friday 16 October"], "the days run newest first")
    run.equal(groups.first?.items.count ?? 0, 2, "two meetings on one day share one heading")
    run.equal(
        groups.first?.items ?? [], [day(0, hour: 14), day(0, hour: 9)],
        "inside a day the meetings keep the order they were given")
    run.equal(MeetingDays.time(day(0, hour: 9), calendar: calendar), "09:00", "a row shows the time on a 24 hour clock")

    run.section("A transcript reads in turns")

    let lines = TranscriptFile.lines(
        markdown: """
            [00:00:01] You: Shall we start?
            [00:00:04] You: I have two things.
            [00:00:09] Others: Go ahead, the renewal first.
            [00:00:15] You: The renewal, then.
            """)
    let turns = TranscriptTurn.group(lines)
    run.equal(turns.map(\.speaker), ["You", "Others", "You"], "a speaker's name is said once each time it changes")
    run.equal(turns.first?.lines.count ?? 0, 2, "two lines in a row from one speaker are one turn")
    run.equal(turns.first?.timecode ?? "", "00:00:01", "a turn starts at its first line")
    run.equal(turns.flatMap(\.lines), lines, "grouping into turns loses no line and reorders none")

    run.equal(TranscriptFile.matches("RENEWAL", in: lines), [2, 3], "finding words ignores case and returns lines in order")
    run.equal(TranscriptFile.matches("  ", in: lines), [], "blank words find nothing")
    run.equal(TranscriptFile.matches("Others", in: lines), [], "finding looks at what was said, not at the speaker's name")
}
