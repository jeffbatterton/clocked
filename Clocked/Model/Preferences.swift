import AppKit
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

@Observable
final class Preferences {
    static let shared = Preferences()

    static let unitChoices = [5, 6, 10, 15, 30, 60]
    static let reminderChoices = [1, 2, 5, 10, 15, 30, 60]

    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance); applyAppearance() }
    }
    var roundingEnabled: Bool {
        didSet { defaults.set(roundingEnabled, forKey: Key.roundingEnabled) }
    }
    var roundingUnitMinutes: Int {
        didSet {
            defaults.set(roundingUnitMinutes, forKey: Key.roundingUnit)
            if roundUpAfterMinutes >= roundingUnitMinutes { roundUpAfterMinutes = roundingUnitMinutes / 2 }
        }
    }
    var roundUpAfterMinutes: Int {
        didSet { defaults.set(roundUpAfterMinutes, forKey: Key.roundUpAfter) }
    }
    var timelineStartHour: Int {
        didSet {
            defaults.set(timelineStartHour, forKey: Key.timelineStart)
            if timelineEndHour <= timelineStartHour { timelineEndHour = timelineStartHour + 1 }
        }
    }
    var timelineEndHour: Int {
        didSet { defaults.set(timelineEndHour, forKey: Key.timelineEnd) }
    }
    /// 1 = Sunday, 2 = Monday.
    var firstWeekday: Int {
        didSet { defaults.set(firstWeekday, forKey: Key.firstWeekday) }
    }
    var reminderEnabled: Bool {
        didSet { defaults.set(reminderEnabled, forKey: Key.reminderEnabled) }
    }
    var reminderMinutes: Int {
        didSet { defaults.set(reminderMinutes, forKey: Key.reminderMinutes) }
    }
    var showMenuBarItem: Bool {
        didSet { defaults.set(showMenuBarItem, forKey: Key.showMenuBarItem) }
    }
    /// Shows sample data in place of your own. The store does the swapping.
    var testDrive: Bool {
        didSet { defaults.set(testDrive, forKey: Key.testDrive) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        roundingEnabled = defaults.bool(forKey: Key.roundingEnabled)
        roundingUnitMinutes = defaults.object(forKey: Key.roundingUnit) as? Int ?? 60
        roundUpAfterMinutes = defaults.object(forKey: Key.roundUpAfter) as? Int ?? 30
        timelineStartHour = defaults.object(forKey: Key.timelineStart) as? Int ?? 8
        timelineEndHour = defaults.object(forKey: Key.timelineEnd) as? Int ?? 20
        firstWeekday = defaults.object(forKey: Key.firstWeekday) as? Int ?? 2
        testDrive = defaults.bool(forKey: Key.testDrive)
        showMenuBarItem = defaults.object(forKey: Key.showMenuBarItem) as? Bool ?? true
        reminderEnabled = defaults.object(forKey: Key.reminderEnabled) as? Bool ?? true
        reminderMinutes = defaults.object(forKey: Key.reminderMinutes) as? Int ?? 5
    }

    var rule: RoundingRule {
        RoundingRule(enabled: roundingEnabled, unitMinutes: roundingUnitMinutes, roundUpAfterMinutes: roundUpAfterMinutes)
    }

    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// Choices for "Round up after", always below the unit. 0 means any leftover rounds up.
    var roundUpChoices: [Int] {
        var choices = [0, 1, 5, 10, 15, 20, 30, 45].filter { $0 < roundingUnitMinutes }
        if !choices.contains(roundingUnitMinutes / 2) { choices.append(roundingUnitMinutes / 2) }
        if !choices.contains(roundUpAfterMinutes), roundUpAfterMinutes < roundingUnitMinutes {
            choices.append(roundUpAfterMinutes)
        }
        return choices.sorted()
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private enum Key {
        static let appearance = "appearance"
        static let roundingEnabled = "roundingEnabled"
        static let roundingUnit = "roundingUnitMinutes"
        static let roundUpAfter = "roundUpAfterMinutes"
        static let timelineStart = "timelineStartHour"
        static let timelineEnd = "timelineEndHour"
        static let firstWeekday = "firstWeekday"
        static let testDrive = "testDrive"
        static let showMenuBarItem = "showMenuBarItem"
        static let reminderEnabled = "reminderEnabled"
        static let reminderMinutes = "reminderMinutes"
    }
}
