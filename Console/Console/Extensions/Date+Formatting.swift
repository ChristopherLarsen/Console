import Foundation

extension Date {
    /// Relative description for conversation list (e.g., "2m ago", "Yesterday", "Jan 15").
    var relativeString: String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(self) {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: self)
        }

        if calendar.isDateInYesterday(self) {
            return "Yesterday"
        }

        if calendar.component(.year, from: self) == calendar.component(.year, from: now) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: self)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: self)
    }

    /// Short time for message timestamps (e.g., "2:30 PM").
    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    /// Full date and time for detailed display.
    var fullString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}
