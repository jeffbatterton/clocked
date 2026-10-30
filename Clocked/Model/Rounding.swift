import Foundation

/// Rounds a day's total to a whole number of `unitMinutes`. Whatever is left over past
/// the last whole unit rounds up only when it is more than `roundUpAfterMinutes`.
/// For example 1 hour, round up after 15 minutes: 2h 16m → 3h, 2h 15m → 2h, 20m → 1h.
struct RoundingRule: Equatable {
    var enabled: Bool
    var unitMinutes: Int
    var roundUpAfterMinutes: Int

    static let off = RoundingRule(enabled: false, unitMinutes: 60, roundUpAfterMinutes: 30)

    func apply(_ seconds: TimeInterval) -> TimeInterval {
        guard enabled, unitMinutes > 0 else { return seconds }
        // Work in whole minutes so a running timer's stray seconds never tip it over.
        let minutes = Int(max(0, seconds) / 60)
        let whole = minutes / unitMinutes
        let remainder = minutes % unitMinutes
        let units = whole + (remainder > roundUpAfterMinutes ? 1 : 0)
        return TimeInterval(units * unitMinutes * 60)
    }
}
