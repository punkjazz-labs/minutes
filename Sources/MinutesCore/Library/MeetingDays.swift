import Foundation

/// The meetings of one day, as the library groups its list.
public struct MeetingDay<Item>: Identifiable {
    /// The start of the day, which is also what keeps the groups apart.
    public let day: Date
    public let title: String
    public let items: [Item]

    public var id: Date { day }
}

/// Groups a list under day headings: Today, Yesterday, the weekday for the
/// rest of the last week, and the date before that.
///
/// A list of a hundred meetings reads by day the way a calendar does, and the
/// heading carries the date, so each row can say only the time.
public enum MeetingDays {

    public static func group<Item>(
        _ items: [Item],
        date: (Item) -> Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingDay<Item>] {
        var order: [Date] = []
        var byDay: [Date: [Item]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(item)
        }
        return order.sorted(by: >).map { day in
            MeetingDay(day: day, title: title(for: day, now: now, calendar: calendar), items: byDay[day] ?? [])
        }
    }

    public static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return formatter("EEEE", calendar: calendar).string(from: day)
        default:
            let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
            return formatter(sameYear ? "EEEE d MMMM" : "d MMMM yyyy", calendar: calendar).string(from: day)
        }
    }

    /// The time of day a row shows under its day heading.
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("HH:mm", calendar: calendar).string(from: date)
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
