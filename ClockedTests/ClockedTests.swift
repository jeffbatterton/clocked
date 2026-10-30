import Foundation
import Testing
@testable import Clocked

struct RoundingTests {
    private let hourAfter15 = RoundingRule(enabled: true, unitMinutes: 60, roundUpAfterMinutes: 15)

    private func minutes(_ m: Int) -> TimeInterval { TimeInterval(m * 60) }

    @Test func anythingOver15MinutesBecomesAnHour() {
        #expect(hourAfter15.apply(minutes(136)) == minutes(180)) // 2h 16m → 3h
        #expect(hourAfter15.apply(minutes(135)) == minutes(120)) // 2h 15m → 2h
        #expect(hourAfter15.apply(minutes(20)) == minutes(60))   // 20m → 1h
        #expect(hourAfter15.apply(minutes(10)) == 0)
    }

    @Test func strayRunningSecondsDoNotTipOver() {
        #expect(hourAfter15.apply(minutes(135) + 59) == minutes(120))
    }

    @Test func halfwayIsNearestRounding() {
        let rule = RoundingRule(enabled: true, unitMinutes: 15, roundUpAfterMinutes: 7)
        #expect(rule.apply(minutes(458)) == minutes(465)) // 7h 38m → 7h 45m
        #expect(rule.apply(minutes(372)) == minutes(375)) // 6h 12m → 6h 15m
        #expect(rule.apply(minutes(367)) == minutes(360))
    }

    @Test func offLeavesTimeAlone() {
        #expect(RoundingRule.off.apply(minutes(136) + 30) == minutes(136) + 30)
    }
}

@MainActor
struct StoreTests {
    private func makeStore() -> TimeStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("data.json")
        return TimeStore(fileURL: url, ticking: false)
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func weekTotalAddsRoundedDays() {
        let store = makeStore()
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        // Mon 27 Oct 7h 38m, Tue 28 Oct 0h 20m.
        store.editDay(companyID: acme.id, day: date(27, 0), newDay: date(27, 0), seconds: 458 * 60)
        store.editDay(companyID: acme.id, day: date(28, 0), newDay: date(28, 0), seconds: 20 * 60)

        let week = DateInterval(start: date(27, 0), duration: 7 * 86400)
        let rule = RoundingRule(enabled: true, unitMinutes: 60, roundUpAfterMinutes: 15)
        #expect(store.total(for: acme.id, in: week, rule: rule) == 9 * 3600) // 8h + 1h
        #expect(store.total(for: acme.id, in: week, rule: .off) == 478 * 60)
    }

    @Test func editingADayMovesAndReplacesItsSessions() {
        let store = makeStore()
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        store.editDay(companyID: acme.id, day: date(28, 0), newDay: date(28, 0), seconds: 3600)
        store.editDay(companyID: acme.id, day: date(28, 0), newDay: date(27, 0), seconds: 2 * 3600)

        let days = store.loggedDays(for: acme.id)
        #expect(days.count == 1)
        #expect(days.first?.day == date(27, 0))
        #expect(days.first?.seconds == TimeInterval(2 * 3600))

        store.deleteDay(companyID: acme.id, day: date(27, 0))
        #expect(store.loggedDays(for: acme.id).isEmpty)
    }

    @Test func switchingCompaniesMovesTheRunningTimer() {
        let store = makeStore()
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        let northwind = store.addCompany(name: "Northwind", colorIndex: 1)
        store.start(acme.id)
        store.switchTo(northwind.id)

        #expect(store.running?.companyID == northwind.id)
        #expect(store.sessions.filter(\.isRunning).count == 1)
        #expect(store.sessions.first { $0.companyID == acme.id }?.end != nil)
    }

    @Test func removingACompanyRemovesItsTime() {
        let store = makeStore()
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        let northwind = store.addCompany(name: "Northwind", colorIndex: 1)
        store.editDay(companyID: acme.id, day: date(28, 0), newDay: date(28, 0), seconds: 3600)
        store.removeCompany(acme.id)

        #expect(store.companies.map(\.id) == [northwind.id])
        #expect(store.sessions.isEmpty)
    }

    @Test func savesAndReloads() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("data.json")
        let store = TimeStore(fileURL: url, ticking: false)
        let acme = store.addCompany(name: "Acme", colorIndex: 3)
        store.start(acme.id)

        let reloaded = TimeStore(fileURL: url, ticking: false)
        #expect(reloaded.companies == [acme])
        #expect(reloaded.running?.companyID == acme.id)
        #expect(reloaded.selectedCompanyID == acme.id)
    }
}

@MainActor
struct TestDriveTests {
    private func makeStore(testDrive: Bool = false) -> (TimeStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("data.json")
        return (TimeStore(fileURL: url, testDrive: testDrive, ticking: false), url)
    }

    @Test func sampleDataIsBelievable() {
        let now = Date()
        let sample = SampleData.make(now: now, calendar: .current)
        #expect(sample.companies.count == 4)
        #expect(sample.sessions.filter(\.isRunning).count == 1)
        #expect(sample.sessions.allSatisfy { $0.start <= now && ($0.end ?? now) <= now })
        #expect(sample.sessions.count > 60)
    }

    @Test func testDriveSetsYourDataAsideAndBringsItBack() {
        let (store, url) = makeStore()
        let mine = store.addCompany(name: "Mine", colorIndex: 5)
        store.start(mine.id)

        store.setTestDrive(true)
        #expect(store.isTestDrive)
        #expect(store.companies.map(\.name) == ["Acme Studio", "Northwind", "Bluebird Labs", "Freelance"])

        store.setTestDrive(false)
        #expect(store.companies == [mine])
        #expect(store.running?.companyID == mine.id)
        #expect(store.selectedCompanyID == mine.id)

        // The real file never held sample data.
        let reloaded = TimeStore(fileURL: url, ticking: false)
        #expect(reloaded.companies == [mine])
    }

    @Test func cardGraphDaysRunThroughToday() {
        let (store, _) = makeStore(testDrive: true)
        let calendar = Calendar.current
        let week = calendar.dateInterval(of: .weekOfYear, for: store.now)!
        let days = store.dayTotals(for: store.selectedCompanyID!, in: week, rule: .off)
        let elapsed = calendar.dateComponents([.day], from: week.start, to: calendar.startOfDay(for: store.now)).day! + 1
        #expect(days.count == elapsed)
        #expect(days.reduce(0, +) == store.total(for: store.selectedCompanyID!, in: week, rule: .off))
    }
}

@MainActor
struct AddEntryTests {
    @Test func addingTimeGoesAfterTheDaysLastSession() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("data.json")
        let store = TimeStore(fileURL: url, ticking: false)
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27))!

        store.addEntry(companyID: acme.id, day: day, seconds: 3600)
        store.addEntry(companyID: acme.id, day: day, seconds: 1800)

        #expect(store.actualTotal(for: acme.id, on: day) == 5400)
        let starts = store.sessions.map(\.start)
        #expect(starts == [day.addingTimeInterval(9 * 3600), day.addingTimeInterval(10 * 3600)])

        store.addEntry(companyID: acme.id, day: day, seconds: 0)
        #expect(store.sessions.count == 2)
    }
}

@MainActor
struct RollAheadTests {
    @Test func timeCanBeAddedToAFutureMonth() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("data.json")
        let store = TimeStore(fileURL: url, ticking: false)
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        let calendar = Calendar.current
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: calendar.dateInterval(of: .month, for: Date())!.start)!

        store.addEntry(companyID: acme.id, day: nextMonth, seconds: 3 * 3600)

        let next = calendar.dateInterval(of: .month, for: nextMonth)!
        let this = calendar.dateInterval(of: .month, for: Date())!
        #expect(store.total(for: acme.id, in: next, rule: .off) == 3 * 3600)
        #expect(store.total(for: acme.id, in: this, rule: .off) == 0)
    }
}

@MainActor
struct ReminderTests {
    private func make(running: Bool = false) -> (Reminder, Preferences, () -> Int) {
        let defaults = UserDefaults(suiteName: "ClockedTests-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        var posted = 0
        let reminder = Reminder(prefs: prefs, defaults: defaults, isRunning: { running }, post: { posted += 1 })
        return (reminder, prefs, { posted })
    }

    @Test func defaultsToOnAfterFiveMinutes() {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "ClockedTests-\(UUID().uuidString)")!)
        #expect(prefs.reminderEnabled)
        #expect(prefs.reminderMinutes == 5)
    }

    @Test func armsOnlyOnTheFirstWakeOfEachDay() {
        let (reminder, _, _) = make()
        let morning = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 8))!
        #expect(reminder.armIfFirstToday(now: morning))
        #expect(!reminder.armIfFirstToday(now: morning.addingTimeInterval(3600)))
        #expect(reminder.armIfFirstToday(now: morning.addingTimeInterval(24 * 3600)))
    }

    @Test func remindsOnlyWhenNothingIsRunning() {
        let (idle, _, idlePosted) = make(running: false)
        idle.fire()
        #expect(idlePosted() == 1)

        let (busy, _, busyPosted) = make(running: true)
        busy.fire()
        #expect(busyPosted() == 0)
    }

    @Test func turnedOffMeansNoReminder() {
        let (reminder, prefs, posted) = make()
        prefs.reminderEnabled = false
        #expect(!reminder.armIfFirstToday(now: Date()))
        reminder.fire()
        #expect(posted() == 0)
    }
}
