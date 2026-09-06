import Foundation

/// How the Morning Brief chooses which local commits to include.
enum BriefDateRangePreset: String, Codable, Equatable, CaseIterable, Sendable {
    /// The calendar day before the brief's day, in the selected calendar.
    case yesterday
    /// Inclusive start and end calendar days chosen by the developer.
    case custom
}

/// Yesterday, or a manually chosen inclusive day range, evaluated in a
/// supplied calendar so Monday reports are not stuck on Sunday.
struct BriefDateRangeSelection: Codable, Equatable, Sendable {
    var preset: BriefDateRangePreset
    var customStart: Date?
    var customEnd: Date?

    static let yesterday = BriefDateRangeSelection(
        preset: .yesterday,
        customStart: nil,
        customEnd: nil
    )

    /// Half-open interval `[startOfFirstDay, startOfDayAfterLastDay)` in `calendar`.
    func interval(relativeTo briefDay: Date, calendar: Calendar) -> DateInterval {
        let briefStart = calendar.startOfDay(for: briefDay)
        switch preset {
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: briefStart) ?? briefStart
            return DateInterval(start: start, end: briefStart)
        case .custom:
            let fallbackStart = calendar.date(byAdding: .day, value: -1, to: briefStart) ?? briefStart
            let first = calendar.startOfDay(for: customStart ?? fallbackStart)
            let last = calendar.startOfDay(for: customEnd ?? first)
            let start = min(first, last)
            let endDay = max(first, last)
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: start, end: end)
        }
    }

    /// Inclusive last calendar day covered by `interval`.
    static func inclusiveEnd(of interval: DateInterval, calendar: Calendar) -> Date {
        let lastInstant = interval.end.addingTimeInterval(-1)
        return calendar.startOfDay(for: max(interval.start, lastInstant))
    }

    static func description(of interval: DateInterval,
                            calendar: Calendar,
                            locale: Locale = .current) -> String {
        let startDay = calendar.startOfDay(for: interval.start)
        let endDay = inclusiveEnd(of: interval, calendar: calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        if startDay == endDay {
            return formatter.string(from: startDay)
        }
        return "\(formatter.string(from: startDay)) – \(formatter.string(from: endDay))"
    }
}
