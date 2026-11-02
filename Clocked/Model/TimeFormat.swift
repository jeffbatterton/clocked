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

    /// Vertical timeline label: "8 AM", "Noon", "Midnight". Hours past 24 wrap into the next day.
    static func hourName(_ hour: Int) -> String {
        let h = hour % 24
        if h == 0 { return "Midnight" }
        if h == 12 { return "Noon" }
        return "\(h % 12) \(h < 12 ? amSymbol : pmSymbol)"
    }

    /// "9:05 AM".
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// "9:05 – 10:59 AM", "11:50 AM – 12:47 PM", or "1:15 PM – now" while running.
    static func range(_ start: Date, _ end: Date?) -> String {
        guard let end else { return "\(time(start)) – now" }
        let isMorning = { (date: Date) in Calendar.current.component(.hour, from: date) < 12 }
        let sameHalf = isMorning(start) == isMorning(end)
        return sameHalf ? "\(shortTime(start)) – \(time(end))" : "\(time(start)) – \(time(end))"
    }

    /// "+0:20", "−1:05": an adjustment to a day.
    static func signedClock(_ seconds: TimeInterval) -> String {
        (seconds < 0 ? "−" : "+") + clock(abs(seconds))
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
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private static var amSymbol: String { timeFormatter.amSymbol }
    private static var pmSymbol: String { timeFormatter.pmSymbol }
    private static let rowDayFormatter = formatter("EEE MMM d")
    private static let longDayFormatter = formatter("EEEE MMMM d")
    private static let monthFormatter = formatter("MMMM yyyy")
    private static let weekFormatter = formatter("MMM d")
}
