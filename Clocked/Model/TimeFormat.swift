import Foundation

enum TimeFormat {
    /// "2h 05m", "3h", "40m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h " + String(format: "%02dm", m)
    }

    /// "2:14", used in the sidebar and menu bar.
    static func clock(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// "1:22:47", the running timer.
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return "\(s / 3600):" + String(format: "%02d:%02d", s / 60 % 60, s % 60)
    }

    /// Timeline axis label: "8a", "12p". Hours past 24 wrap into the next day.
    static func hourLabel(_ hour: Int) -> String {
        let h = hour % 24
        let suffix = h < 12 ? "a" : "p"
        return "\(h % 12 == 0 ? 12 : h % 12)\(suffix)"
    }

    /// "8:00 AM", or "Midnight" for 24.
    static func hourOfDay(_ hour: Int) -> String {
        if hour == 24 { return "Midnight" }
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// "5 minutes", "1 hour".
    static func unitName(_ minutes: Int) -> String {
        if minutes == 60 { return "1 hour" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func shortTime(_ date: Date) -> String { shortTimeFormatter.string(from: date) }
    static func rowDay(_ date: Date) -> String { rowDayFormatter.string(from: date) }
    static func longDay(_ date: Date) -> String { longDayFormatter.string(from: date) }
    static func month(_ date: Date) -> String { monthFormatter.string(from: date) }
    static func weekOf(_ date: Date) -> String { "Week of " + weekFormatter.string(from: date) }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()
    private static let rowDayFormatter = formatter("EEE MMM d")
    private static let longDayFormatter = formatter("EEEE MMMM d")
    private static let monthFormatter = formatter("MMMM yyyy")
    private static let weekFormatter = formatter("MMM d")
}
