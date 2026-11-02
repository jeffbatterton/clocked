import Foundation

struct Company: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Index into `Palette`.
    var colorIndex: Int
}

/// One stretch of tracked time. A session with no `end` is the running timer.
struct Session: Identifiable, Codable, Hashable {
    /// Where a session came from, so time entered by hand or by an assistant can be told apart.
    enum Source: String, Codable {
        case timer, manual, assistant
    }

    var id = UUID()
    var companyID: UUID
    var start: Date
    var end: Date?
    /// What the time was spent on. Empty when there's no note.
    var note = ""
    var source = Source.timer

    var isRunning: Bool { end == nil }

    /// Whole seconds, so date arithmetic never turns 2h into 1h 59m 59.999s.
    func duration(now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start).rounded())
    }

    init(id: UUID = UUID(), companyID: UUID, start: Date, end: Date? = nil, note: String = "", source: Source = .timer) {
        self.id = id
        self.companyID = companyID
        self.start = start
        self.end = end
        self.note = note
        self.source = source
    }

    /// Sessions saved before notes and sources existed load with none and as timer time.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        companyID = try c.decode(UUID.self, forKey: .companyID)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .timer
    }
}

/// Time added to or taken off a day without a start or end, such as time you forgot to
/// track. It keeps the day's sessions as they are.
struct Adjustment: Identifiable, Codable, Hashable {
    var id = UUID()
    var companyID: UUID
    /// Start of the day it belongs to.
    var day: Date
    /// Positive adds time, negative takes it off.
    var seconds: TimeInterval
    var note = ""
}

/// A day's total for one company, as shown in the log.
struct LoggedDay: Identifiable, Hashable {
    var day: Date
    var seconds: TimeInterval
    var isRunning: Bool
    var id: Date { day }
}
