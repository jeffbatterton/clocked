import Foundation
import Observation

/// Companies and sessions, saved as JSON in Application Support. Actual start and stop
/// times are always kept; rounding is applied to each day's total whenever it is shown.
/// A session counts toward the day it started on.
@MainActor
@Observable
final class TimeStore {
    private(set) var companies: [Company] = []
    private(set) var sessions: [Session] = []
    var selectedCompanyID: UUID? {
        didSet { if oldValue != selectedCompanyID { save() } }
    }
    /// Ticks every second while a timer runs, and every minute otherwise.
    private(set) var now = Date()

    /// True while Test drive's sample data is loaded in place of your own.
    private(set) var isTestDrive = false

    @ObservationIgnored var calendar = Calendar.current
    @ObservationIgnored private let dataFileURL: URL
    @ObservationIgnored private var fileURL: URL
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var isSwapping = false

    /// Test drive saves next to the real data, which it never touches.
    private var testDriveFileURL: URL {
        dataFileURL.deletingLastPathComponent().appendingPathComponent("test-drive.json")
    }

    /// Application Support/Clocked/data.json, or the path in CLOCKED_DATA_FILE (handy for trying
    /// the app with sample data).
    nonisolated static var defaultFileURL: URL {
        if let path = ProcessInfo.processInfo.environment["CLOCKED_DATA_FILE"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clocked", isDirectory: true)
            .appendingPathComponent("data.json")
    }

    init(fileURL: URL = TimeStore.defaultFileURL, testDrive: Bool = false, ticking: Bool = true) {
        dataFileURL = fileURL
        self.fileURL = fileURL
        load()
        setTestDrive(testDrive)
        if ticking { startTicker() }
    }

    // MARK: Test drive

    /// Swaps your data for freshly made sample data, or puts your data back. Your own data,
    /// including a running timer, is saved as it is and carries on counting underneath.
    func setTestDrive(_ on: Bool) {
        guard on != isTestDrive else { return }
        isTestDrive = on
        // Nothing may be saved mid-swap, or an emptied store would overwrite your data.
        isSwapping = true
        if on {
            fileURL = testDriveFileURL
            let sample = SampleData.make(now: Date(), calendar: calendar)
            companies = sample.companies
            sessions = sample.sessions
            selectedCompanyID = sample.selectedCompanyID
        } else {
            fileURL = dataFileURL
            companies = []
            sessions = []
            selectedCompanyID = nil
            load()
        }
        isSwapping = false
        now = Date()
        if on { save() }
    }

    // MARK: Lookup

    var selectedCompany: Company? { selectedCompanyID.flatMap(company) }
    var running: Session? { sessions.last(where: \.isRunning) }
    /// The company the menu bar talks about: the running one, otherwise the selected one.
    var currentCompanyID: UUID? { running?.companyID ?? selectedCompanyID }
    var currentCompany: Company? { currentCompanyID.flatMap(company) }

    func company(_ id: UUID) -> Company? { companies.first { $0.id == id } }

    // MARK: Timer

    func start(_ companyID: UUID) {
        closeRunning()
        sessions.append(Session(companyID: companyID, start: Date()))
        now = Date()
        save()
    }

    func stop() {
        closeRunning()
        now = Date()
        save()
    }

    /// Selects a company; if a timer is running for another company it moves to this one.
    func switchTo(_ companyID: UUID) {
        selectedCompanyID = companyID
        if let running, running.companyID != companyID { start(companyID) }
    }

    private func closeRunning() {
        guard let i = sessions.lastIndex(where: \.isRunning) else { return }
        sessions[i].end = Date()
    }

    // MARK: Companies

    @discardableResult
    func addCompany(name: String, colorIndex: Int) -> Company {
        let company = Company(name: name, colorIndex: colorIndex)
        companies.append(company)
        selectedCompanyID = company.id
        save()
        return company
    }

    func updateCompany(_ company: Company) {
        guard let i = companies.firstIndex(where: { $0.id == company.id }) else { return }
        companies[i] = company
        save()
    }

    /// Removes a company and all of its time.
    func removeCompany(_ id: UUID) {
        sessions.removeAll { $0.companyID == id }
        companies.removeAll { $0.id == id }
        if selectedCompanyID == id { selectedCompanyID = companies.first?.id }
        save()
    }

    /// A palette colour no other company uses yet, picked at random.
    func randomUnusedColorIndex() -> Int {
        let used = Set(companies.map(\.colorIndex))
        let free = Palette.indices.filter { !used.contains($0) }
        return (free.isEmpty ? Array(Palette.indices) : free).randomElement() ?? 0
    }

    // MARK: Totals

    func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    /// Actual time per day for a company, keyed by start of day.
    func dailyTotals(for companyID: UUID) -> [Date: TimeInterval] {
        var totals: [Date: TimeInterval] = [:]
        for session in sessions where session.companyID == companyID {
            totals[startOfDay(session.start), default: 0] += session.duration(now: now)
        }
        return totals
    }

    func actualTotal(for companyID: UUID, on day: Date) -> TimeInterval {
        let day = startOfDay(day)
        return sessions
            .filter { $0.companyID == companyID && startOfDay($0.start) == day }
            .reduce(0) { $0 + $1.duration(now: now) }
    }

    /// The day the company's time is counting toward right now: the running session's day
    /// (which can be yesterday after midnight), otherwise today.
    func currentDay(for companyID: UUID) -> Date {
        if let running, running.companyID == companyID { return startOfDay(running.start) }
        return startOfDay(now)
    }

    /// Sum of each day's rounded total for days starting inside `interval`.
    func total(for companyID: UUID, in interval: DateInterval, rule: RoundingRule) -> TimeInterval {
        dailyTotals(for: companyID)
            .filter { $0.key >= interval.start && $0.key < interval.end }
            .values
            .reduce(0) { $0 + rule.apply($1) }
    }

    /// Each day's rounded total from the start of `interval` through today, for the card graphs.
    func dayTotals(for companyID: UUID, in interval: DateInterval, rule: RoundingRule) -> [TimeInterval] {
        let totals = dailyTotals(for: companyID)
        let today = startOfDay(now)
        var day = startOfDay(interval.start)
        var result: [TimeInterval] = []
        while day < interval.end, day <= today {
            result.append(rule.apply(totals[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// One entry per day with time, newest first.
    func loggedDays(for companyID: UUID) -> [LoggedDay] {
        let runningDay = running.flatMap { $0.companyID == companyID ? startOfDay($0.start) : nil }
        return dailyTotals(for: companyID)
            .map { LoggedDay(day: $0.key, seconds: $0.value, isRunning: $0.key == runningDay) }
            .sorted { $0.day > $1.day }
    }

    // MARK: Editing the log

    /// Replaces a day's finished sessions with one session of `seconds`, on `newDay`. It keeps
    /// the time of day the original work started. Zero seconds deletes the day.
    func editDay(companyID: UUID, day: Date, newDay: Date, seconds: TimeInterval) {
        let old = finishedSessions(companyID: companyID, day: day)
        let anchor = old.map(\.start).min()
        let offset = anchor.map { $0.timeIntervalSince(startOfDay($0)) } ?? 9 * 3600
        let oldIDs = Set(old.map(\.id))
        sessions.removeAll { oldIDs.contains($0.id) }
        if seconds > 0 {
            let start = startOfDay(newDay).addingTimeInterval(offset)
            sessions.append(Session(companyID: companyID, start: start, end: start.addingTimeInterval(seconds)))
            sessions.sort { $0.start < $1.start }
        }
        save()
    }

    /// Adds time to a day without running the timer. It goes after the day's last session,
    /// or at 9:00 on an empty day.
    func addEntry(companyID: UUID, day: Date, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let day = startOfDay(day)
        let lastEnd = sessions
            .filter { $0.companyID == companyID && startOfDay($0.start) == day }
            .map { $0.end ?? now }
            .max()
        let start = lastEnd ?? day.addingTimeInterval(9 * 3600)
        sessions.append(Session(companyID: companyID, start: start, end: start.addingTimeInterval(seconds)))
        sessions.sort { $0.start < $1.start }
        save()
    }

    func deleteDay(companyID: UUID, day: Date) {
        let ids = Set(finishedSessions(companyID: companyID, day: day).map(\.id))
        sessions.removeAll { ids.contains($0.id) }
        save()
    }

    private func finishedSessions(companyID: UUID, day: Date) -> [Session] {
        let day = startOfDay(day)
        return sessions.filter { $0.companyID == companyID && !$0.isRunning && startOfDay($0.start) == day }
    }

    // MARK: Ticking

    private func startTicker() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let date = Date()
        if running != nil || !calendar.isDate(date, equalTo: now, toGranularity: .minute) {
            now = date
        }
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var companies: [Company]
        var sessions: [Session]
        var selectedCompanyID: UUID?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            companies = snapshot.companies
            sessions = snapshot.sessions
            selectedCompanyID = snapshot.selectedCompanyID ?? companies.first?.id
        } catch {
            NSLog("Clocked: could not read \(fileURL.path): \(error)")
        }
    }

    private func save() {
        guard !isSwapping else { return }
        let snapshot = Snapshot(companies: companies, sessions: sessions, selectedCompanyID: selectedCompanyID)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Clocked: could not save \(fileURL.path): \(error)")
        }
    }
}
