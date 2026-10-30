import Foundation

struct Company: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Index into `Palette`.
    var colorIndex: Int
}

/// One stretch of tracked time. A session with no `end` is the running timer.
struct Session: Identifiable, Codable, Hashable {
    var id = UUID()
    var companyID: UUID
    var start: Date
    var end: Date?

    var isRunning: Bool { end == nil }

    /// Whole seconds, so date arithmetic never turns 2h into 1h 59m 59.999s.
    func duration(now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start).rounded())
    }
}

/// A day's total for one company, as shown in the log.
struct LoggedDay: Identifiable, Hashable {
    var day: Date
    var seconds: TimeInterval
    var isRunning: Bool
    var id: Date { day }
}
