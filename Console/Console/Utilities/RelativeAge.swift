import Foundation

/// One time language for the whole Home dashboard (DESIGN_PROMPT.md §5).
///
/// `JiraTicketSummary.updatedText` and `MergeRequestSummary.updatedText` are
/// strings scraped from whatever the host rendered — an absolute timestamp on
/// JIRA, "4 hours ago" on GitLab. Cards show relative age only (`38m`, `4h`,
/// `2d`), so this parses those strings to a `Date` locally and formats them.
/// When a string will not parse it is returned verbatim: never dropped and
/// never replaced with an invented date.
enum RelativeAge {
    /// Compact relative age for a scraped timestamp string, or the input
    /// verbatim when nothing parses.
    static func compact(from raw: String?, now: Date = Date()) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Hosts sometimes wrap the value in a word ("updated 4 hours ago").
        let candidate = stripLeadingLabel(trimmed)

        if let date = date(from: candidate, now: now) {
            return compact(date: date, now: now)
        }
        return trimmed
    }

    /// Compact relative age for a known date.
    static func compact(date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "now" }

        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 60 { return "\(days)d" }

        let months = days / 30
        if months < 18 { return "\(months)mo" }

        return "\(days / 365)y"
    }

    // MARK: - Parsing

    private static func stripLeadingLabel(_ value: String) -> String {
        let labels = ["updated", "created"]
        for label in labels where value.lowercased().hasPrefix("\(label) ") {
            return String(value.dropFirst(label.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func date(from value: String, now: Date) -> Date? {
        if let relative = relativeMatch(value), let date = Calendar.current.date(
            byAdding: relative.component,
            value: -relative.amount,
            to: now
        ) {
            return date
        }
        return absoluteDate(value)
    }

    private static func relativeMatch(_ value: String) -> (component: Calendar.Component, amount: Int)? {
        let lowered = value.lowercased()
        if lowered == "just now" || lowered == "now" {
            return (.second, 0)
        }

        // "about 3 hours ago", "2d ago", "1 hour ago", "less than a minute ago".
        let pattern =
            "^(?:about\\s+|almost\\s+|over\\s+|less\\s+than\\s+)?(a|an|\\d+)\\s+(second|minute|hour|day|week|month|year)s?\\s+ago$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              match.numberOfRanges >= 3
        else { return nil }

        func text(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: lowered) else { return "" }
            return String(lowered[range])
        }

        let amountText = text(1)
        let amount = amountText == "a" || amountText == "an" ? 1 : Int(amountText) ?? 0

        switch text(2) {
        case "second": return (.second, amount)
        case "minute": return (.minute, amount)
        case "hour": return (.hour, amount)
        case "day": return (.day, amount)
        case "week": return (.day, amount * 7)
        case "month": return (.day, amount * 30)
        case "year": return (.day, amount * 365)
        default: return nil
        }
    }

    private static func absoluteDate(_ value: String) -> Date? {
        let formats = [
            "MMM d, yyyy, h:mm a",
            "MMM d, yyyy, HH:mm",
            "MMM d, yyyy h:mm a",
            "MMM d, yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "MMM d, h:mm a",
        ]
        for format in formats {
            let formatter = cachedFormatter(for: format)
            if let date = formatter.date(from: value) {
                // Formats without a year default to the current year; a host
                // rendering a bare "Aug 21" means the most recent Aug 21.
                return date
            }
        }

        if let date = cachedISOFormatter().date(from: value) {
            return date
        }
        return nil
    }

    private static var formatterCache: [String: DateFormatter] = [:]

    private static func cachedFormatter(for format: String) -> DateFormatter {
        if let cached = formatterCache[format] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatterCache[format] = formatter
        return formatter
    }

    private static var isoFormatter: ISO8601DateFormatter?

    private static func cachedISOFormatter() -> ISO8601DateFormatter {
        if let cached = isoFormatter { return cached }
        let formatter = ISO8601DateFormatter()
        isoFormatter = formatter
        return formatter
    }

    /// Test hook: parse an absolute timestamp the way `compact(from:)` would.
    static func parseAbsoluteForTesting(_ value: String) -> Date? {
        absoluteDate(value)
    }
}
