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
        // Tue 27 Oct 7h 38m, Wed 28 Oct 0h 20m.
        store.addEntry(companyID: acme.id, day: date(27, 0), seconds: 458 * 60)
        store.addEntry(companyID: acme.id, day: date(28, 0), seconds: 20 * 60)

        let week = DateInterval(start: date(27, 0), duration: 7 * 86400)
        let rule = RoundingRule(enabled: true, unitMinutes: 60, roundUpAfterMinutes: 15)
        #expect(store.total(for: acme.id, in: week, rule: rule) == 9 * 3600) // 8h + 1h
        #expect(store.total(for: acme.id, in: week, rule: .off) == 478 * 60)
    }

    @Test func adjustmentsCountTowardTheDayAndKeepItsSessions() {
        let store = makeStore()
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        store.addSession(companyID: acme.id, start: date(29, 9, 2), end: date(29, 10, 47), note: "Auth refactor")
        store.addAdjustment(companyID: acme.id, day: date(29, 15), seconds: 20 * 60, note: "Forgot the timer")

        #expect(store.actualTotal(for: acme.id, on: date(29, 0)) == 125 * 60)
        #expect(store.dailyTotals(for: acme.id)[date(29, 0)] == TimeInterval(125 * 60))
        #expect(store.sessions(for: acme.id, on: date(29, 0)).map(\.note) == ["Auth refactor"])

        // Taking off more than the day had leaves it at zero, not below.
        let adjustment = store.adjustments(for: acme.id, on: date(29, 0))[0]
        store.updateAdjustment(adjustment.id, seconds: -3 * 3600, note: "")
        #expect(store.actualTotal(for: acme.id, on: date(29, 0)) == 0)

        store.updateAdjustment(adjustment.id, seconds: 0, note: "")
        #expect(store.adjustments.isEmpty)

        store.deleteDay(companyID: acme.id, day: date(29, 0))
        #expect(store.loggedDays(for: acme.id).isEmpty)
    }

    @Test func sessionsCantOverlap() {
        let store = makeStore()
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        let northwind = store.addCompany(name: "Northwind", colorIndex: 1)
        let morning = store.addSession(companyID: acme.id, start: date(29, 9), end: date(29, 11))
        let noon = store.addSession(companyID: acme.id, start: date(29, 12), end: date(29, 13))

        #expect(store.problem(withTimes: date(29, 10), date(29, 12, 30), for: acme.id, excluding: noon.id) != nil)
        #expect(store.problem(withTimes: date(29, 11), date(29, 13), for: acme.id, excluding: noon.id) == nil)
        #expect(store.problem(withTimes: date(29, 13), date(29, 12), for: acme.id, excluding: noon.id) != nil)
        // Another company's time can run alongside.
        #expect(store.problem(withTimes: date(29, 9), date(29, 11), for: northwind.id, excluding: nil) == nil)

        store.setTimes(for: morning.id, start: date(29, 8, 30), end: date(29, 10))
        #expect(store.session(morning.id)?.start == date(29, 8, 30))
        #expect(store.actualTotal(for: acme.id, on: date(29, 0)) == 150 * 60)
    }

    @Test func notesAreTrimmedAndSaved() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("data.json")
        let store = TimeStore(fileURL: url, ticking: false)
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        store.start(acme.id)
        let running = store.running(for: acme.id)!
        store.setNote("  Billing webhooks \n", for: running.id)

        let reloaded = TimeStore(fileURL: url, ticking: false)
        #expect(reloaded.running(for: acme.id)?.note == "Billing webhooks")
        #expect(reloaded.running(for: acme.id)?.source == .timer)
    }

    @Test func filesFromBeforeNotesStillLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("data.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let company = UUID()
        let old = """
        {"companies":[{"id":"\(company)","name":"Acme","colorIndex":0}],
         "sessions":[{"id":"\(UUID())","companyID":"\(company)","start":"2026-10-29T13:00:00Z","end":"2026-10-29T14:00:00Z"}]}
        """
        try Data(old.utf8).write(to: url)

        let store = TimeStore(fileURL: url, ticking: false)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].note == "")
        #expect(store.sessions[0].source == .timer)
        #expect(store.adjustments.isEmpty)
    }

    @Test func eachCompanyHasItsOwnTimer() {
        let store = makeStore()
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        let northwind = store.addCompany(name: "Northwind", colorIndex: 1)
        store.start(acme.id)
        store.selectedCompanyID = northwind.id
        #expect(store.running(for: northwind.id) == nil)

        store.start(northwind.id)
        store.start(northwind.id)
        #expect(store.runningSessions.map(\.companyID) == [acme.id, northwind.id])

        store.stop(acme.id)
        #expect(store.running(for: acme.id) == nil)
        #expect(store.running(for: northwind.id) != nil)
    }

    @Test func removingACompanyRemovesItsTime() {
        let store = makeStore()
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        let northwind = store.addCompany(name: "Northwind", colorIndex: 1)
        store.addEntry(companyID: acme.id, day: date(28, 0), seconds: 3600)
        store.addAdjustment(companyID: acme.id, day: date(28, 0), seconds: 600)
        store.removeCompany(acme.id)

        #expect(store.companies.map(\.id) == [northwind.id])
        #expect(store.sessions.isEmpty)
        #expect(store.adjustments.isEmpty)
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
        #expect(reloaded.running(for: acme.id) != nil)
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
        #expect(sample.sessions.contains { !$0.note.isEmpty })
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
        #expect(store.running(for: mine.id) != nil)
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
        #expect(store.sessions.allSatisfy { $0.source == .manual })

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
struct TimelineTests {
    @Test func gapsAreTheUntrackedTimeBetweenSessions() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("data.json")
        let store = TimeStore(fileURL: url, ticking: false)
        let acme = store.addCompany(name: "Acme", colorIndex: 0)
        let today = store.startOfDay(Date())
        func at(_ minutes: Int) -> Date { today.addingTimeInterval(TimeInterval(minutes * 60)) }
        store.addSession(companyID: acme.id, start: at(9 * 60), end: at(10 * 60))
        // 3 minutes later: too short to count as a gap.
        store.addSession(companyID: acme.id, start: at(10 * 60 + 3), end: at(11 * 60))
        store.addSession(companyID: acme.id, start: at(11 * 60 + 51), end: at(12 * 60 + 47))

        let defaults = UserDefaults(suiteName: "ClockedTests-\(UUID().uuidString)")!
        let model = TimelineModel(store: store, prefs: Preferences(defaults: defaults), companyID: acme.id)
        #expect(model.gaps.map(\.start) == [at(11 * 60)])
        #expect(model.gaps.map(\.end) == [at(11 * 60 + 51)])
        #expect(model.climb.last?.y == CGFloat(2 * 3600 - 3 * 60 + 56 * 60))
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

@MainActor
struct ClaudeToolTests {
    private let store: TimeStore
    private let prefs: Preferences
    private let activity: ClaudeActivity
    private let server: MCPServer
    private let acme: Company

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("data.json")
        store = TimeStore(fileURL: url, ticking: false)
        let defaults = UserDefaults(suiteName: "ClockedTests-\(UUID().uuidString)")!
        prefs = Preferences(defaults: defaults)
        activity = ClaudeActivity(store: store, prefs: prefs, defaults: defaults)
        activity.notify = { _, _ in }
        server = MCPServer(tools: ClaudeTools(store: store, prefs: prefs, activity: activity))
        acme = store.addCompany(name: "Acme Co", colorIndex: 0)
        store.addCompany(name: "Northwind", colorIndex: 1)
    }

    private func send(_ message: [String: Any]) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: message)
        let reply = server.handle(String(decoding: data, as: UTF8.self)) ?? "{}"
        return try! JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
    }

    /// Calls a tool and returns its text and whether it failed.
    private func call(_ name: String, _ arguments: [String: Any] = [:]) -> (text: String, isError: Bool) {
        let reply = send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let result = reply["result"] as! [String: Any]
        let content = (result["content"] as! [[String: Any]])[0]
        return (content["text"] as! String, result["isError"] as! Bool)
    }

    private var yesterday: String {
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        return day.formatted(.iso8601.year().month().day())
    }

    @Test func initializeSpeaksTheClientsVersion() {
        let reply = send(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        let result = reply["result"] as! [String: Any]
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "clocked")
    }

    @Test func notificationsGetNoReply() {
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func readOnlyHidesAndRefusesWrites() {
        prefs.claudeCanWrite = false
        let reply = send(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let names = ((reply["result"] as! [String: Any])["tools"] as! [[String: Any]]).compactMap { $0["name"] as? String }
        #expect(names.contains("get_summary"))
        #expect(!names.contains("add_session"))
        #expect(call("add_time", ["company": "acme", "minutes": 30]).isError)
        #expect(store.sessions.isEmpty)
    }

    @Test func addSessionFindsTheCompanyByPartOfItsName() {
        let result = call("add_session", ["company": "acme", "day": yesterday, "start": "9:00 AM", "end": "11:30", "note": "Pricing call"])
        #expect(!result.isError)
        let session = store.sessions.first!
        #expect(session.companyID == acme.id)
        #expect(session.duration(now: Date()) == 150 * 60)
        #expect(session.source == .assistant)
        #expect(session.note == "Pricing call")
    }

    @Test func overlapsAreRefused() {
        _ = call("add_session", ["company": "Acme", "day": yesterday, "start": "09:00", "end": "11:00"])
        let result = call("add_session", ["company": "Acme", "day": yesterday, "start": "10:00", "end": "12:00"])
        #expect(result.isError)
        #expect(result.text.contains("overlaps"))
        #expect(store.sessions.count == 1)
    }

    @Test func unknownCompanySaysWhichThereAre() {
        let result = call("add_time", ["company": "Globex", "minutes": 30])
        #expect(result.isError)
        #expect(result.text.contains("Acme Co, Northwind"))
    }

    @Test func changesCloseTogetherUndoAsOne() {
        _ = call("add_session", ["company": "Acme", "day": yesterday, "start": "09:00", "end": "11:30"])
        _ = call("adjust_day", ["company": "Northwind", "day": yesterday, "minutes": 20])
        _ = call("add_time", ["company": "Northwind", "day": yesterday, "minutes": 120])
        let change = try! #require(activity.current)
        #expect(activity.title(for: change) == "Claude added 2 sessions and adjusted a day")
        #expect(activity.summary(for: change) == "Acme Co 2:30 · Northwind 2:20")

        activity.undo(change.id)
        #expect(store.sessions.isEmpty)
        #expect(store.adjustments.isEmpty)
    }

    @Test func undoPutsANoteBack() {
        let session = store.addSession(companyID: acme.id, start: Date().addingTimeInterval(-7200), end: Date().addingTimeInterval(-3600), note: "Mine")
        _ = call("update_session", ["session_id": session.id.uuidString, "note": "Claude's"])
        #expect(store.session(session.id)?.note == "Claude's")
        activity.undo(activity.current!.id)
        #expect(store.session(session.id)?.note == "Mine")
    }

    @Test func summaryRoundsEachDay() {
        prefs.roundingEnabled = true
        prefs.roundingUnitMinutes = 60
        prefs.roundUpAfterMinutes = 15
        _ = call("add_session", ["company": "Acme", "day": yesterday, "start": "09:00", "end": "11:16"])
        let result = call("get_summary", ["company": "Acme", "from": yesterday])
        #expect(result.text.contains(#""billed" : "3:00""#))
        #expect(result.text.contains(#""actual" : "2:16""#))
    }
}
