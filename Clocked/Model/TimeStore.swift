import Foundation
import Observation

/// Companies, sessions and adjustments, saved as JSON in Application Support. Actual start
/// and stop times are always kept; rounding is applied to each day's total whenever it is
/// shown. A session counts toward the day it started on, and a day's total is its sessions
/// plus its adjustments.
@MainActor
@Observable
final class TimeStore {
    private(set) var companies: [Company] = []
    private(set) var sessions: [Session] = []
    private(set) var adjustments: [Adjustment] = []
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
            adjustments = []
            selectedCompanyID = sample.selectedCompanyID
        } else {
            fileURL = dataFileURL
            companies = []
            sessions = []
            adjustments = []
            selectedCompanyID = nil
            load()
        }
        isSwapping = false
        now = Date()
        if on { save() }
    }

    // MARK: Lookup

    var selectedCompany: Company? { selectedCompanyID.flatMap(company) }
    /// Every running timer, the longest-running first. Each company has its own, and any
    /// number can run at once.
    var runningSessions: [Session] { sessions.filter(\.isRunning).sorted { $0.start < $1.start } }
    var isAnyRunning: Bool { sessions.contains(where: \.isRunning) }

    func running(for companyID: UUID) -> Session? {
        sessions.last { $0.isRunning && $0.companyID == companyID }
    }

    func company(_ id: UUID) -> Company? { companies.first { $0.id == id } }

    // MARK: Timer

    /// Starts the company's timer, leaving any other company's timer running.
    func start(_ companyID: UUID) {
        guard running(for: companyID) == nil else { return }
        sessions.append(Session(companyID: companyID, start: Date()))
        now = Date()
        save()
    }

    func stop(_ companyID: UUID) {
        guard let i = sessions.lastIndex(where: { $0.isRunning && $0.companyID == companyID }) else { return }
        sessions[i].end = Date()
        now = Date()
        save()
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
        adjustments.removeAll { $0.companyID == id }
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

    /// `time`'s hour and minute on `day`. Time pickers only change the time of day, so this
    /// keeps what they pick on the session's own day.
    func moving(_ time: Date, to day: Date) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: day) ?? time
    }

    /// Actual time per day for a company, keyed by start of day: its sessions plus its
    /// adjustments, never below zero.
    func dailyTotals(for companyID: UUID) -> [Date: TimeInterval] {
        var totals: [Date: TimeInterval] = [:]
        for session in sessions where session.companyID == companyID {
            totals[startOfDay(session.start), default: 0] += session.duration(now: now)
        }
        for adjustment in adjustments where adjustment.companyID == companyID {
            totals[startOfDay(adjustment.day), default: 0] += adjustment.seconds
        }
        return totals.mapValues { max(0, $0) }
    }

    func actualTotal(for companyID: UUID, on day: Date) -> TimeInterval {
        let sessionTime = sessions(for: companyID, on: day).reduce(0) { $0 + $1.duration(now: now) }
        let adjusted = adjustments(for: companyID, on: day).reduce(0) { $0 + $1.seconds }
        return max(0, sessionTime + adjusted)
    }

    /// A day's sessions for a company, earliest first, including a running one.
    func sessions(for companyID: UUID, on day: Date) -> [Session] {
        let day = startOfDay(day)
        return sessions
            .filter { $0.companyID == companyID && startOfDay($0.start) == day }
            .sorted { $0.start < $1.start }
    }

    func adjustments(for companyID: UUID, on day: Date) -> [Adjustment] {
        let day = startOfDay(day)
        return adjustments.filter { $0.companyID == companyID && startOfDay($0.day) == day }
    }

    func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }

    /// The day the company's time is counting toward right now: its running session's day
    /// (which can be yesterday after midnight), otherwise today.
    func currentDay(for companyID: UUID) -> Date {
        if let running = running(for: companyID) { return startOfDay(running.start) }
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
        let runningDay = running(for: companyID).map { startOfDay($0.start) }
        return dailyTotals(for: companyID)
            .map { LoggedDay(day: $0.key, seconds: $0.value, isRunning: $0.key == runningDay) }
            .sorted { $0.day > $1.day }
    }

    // MARK: Editing sessions

    /// Adds finished time without running the timer. It goes after the day's last session,
    /// or at 9:00 on an empty day.
    @discardableResult
    func addEntry(companyID: UUID, day: Date, seconds: TimeInterval, note: String = "") -> Session? {
        guard seconds > 0 else { return nil }
        let start = nextFreeStart(companyID: companyID, day: day)
        return addSession(companyID: companyID, start: start, end: start.addingTimeInterval(seconds), note: note)
    }

    /// Where time added to a day by hand goes: after the day's last session, or at 9:00.
    func nextFreeStart(companyID: UUID, day: Date) -> Date {
        let day = startOfDay(day)
        let lastEnd = sessions(for: companyID, on: day).map { $0.end ?? now }.max()
        return lastEnd ?? day.addingTimeInterval(9 * 3600)
    }

    /// Adds a finished session entered by hand (or by an assistant).
    @discardableResult
    func addSession(companyID: UUID, start: Date, end: Date, note: String = "", source: Session.Source = .manual) -> Session {
        let session = Session(companyID: companyID, start: start, end: max(start, end), note: note, source: source)
        sessions.append(session)
        sessions.sort { $0.start < $1.start }
        save()
        return session
    }

    func setNote(_ note: String, for id: UUID) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].note != note else { return }
        sessions[i].note = note
        save()
    }

    /// Moves a session's start and end. A running session keeps running; its `end` is ignored.
    func setTimes(for id: UUID, start: Date, end: Date?) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].start = start
        if !sessions[i].isRunning, let end { sessions[i].end = max(start, end) }
        sessions.sort { $0.start < $1.start }
        now = Date()
        save()
    }

    /// Why a session can't have these times, or nil if it can. Sessions for the same company
    /// never overlap, and a running session can't start in the future.
    func problem(withTimes start: Date, _ end: Date?, for companyID: UUID, excluding id: UUID?) -> String? {
        let running = end == nil
        if running, start > Date() { return "The start can't be in the future." }
        if let end, end <= start { return "The end has to be after the start." }
        let finish = end ?? .distantFuture
        let clash = sessions.first { other in
            other.companyID == companyID && other.id != id
                && other.start < finish && (other.end ?? .distantFuture) > start
        }
        guard let clash else { return nil }
        let range = TimeFormat.range(clash.start, clash.end)
        return "That overlaps \(range)."
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        now = Date()
        save()
    }

    // MARK: Adjustments

    @discardableResult
    func addAdjustment(companyID: UUID, day: Date, seconds: TimeInterval, note: String = "") -> Adjustment? {
        guard seconds != 0 else { return nil }
        let adjustment = Adjustment(companyID: companyID, day: startOfDay(day), seconds: seconds, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        adjustments.append(adjustment)
        save()
        return adjustment
    }

    /// Changes an adjustment's time and note. Zero time removes it.
    func updateAdjustment(_ id: UUID, seconds: TimeInterval, note: String) {
        guard let i = adjustments.firstIndex(where: { $0.id == id }) else { return }
        if seconds == 0 {
            adjustments.remove(at: i)
        } else {
            adjustments[i].seconds = seconds
            adjustments[i].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        save()
    }

    func deleteAdjustment(_ id: UUID) {
        adjustments.removeAll { $0.id == id }
        save()
    }

    /// Removes a day's finished sessions and its adjustments. A running timer carries on.
    func deleteDay(companyID: UUID, day: Date) {
        let day = startOfDay(day)
        sessions.removeAll { $0.companyID == companyID && !$0.isRunning && startOfDay($0.start) == day }
        adjustments.removeAll { $0.companyID == companyID && startOfDay($0.day) == day }
        save()
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
        if isAnyRunning || !calendar.isDate(date, equalTo: now, toGranularity: .minute) {
            now = date
        }
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var companies: [Company]
        var sessions: [Session]
        /// Missing from files saved before adjustments existed.
        var adjustments: [Adjustment]?
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
            adjustments = snapshot.adjustments ?? []
            selectedCompanyID = snapshot.selectedCompanyID ?? companies.first?.id
        } catch {
            NSLog("Clocked: could not read \(fileURL.path): \(error)")
        }
    }

    private func save() {
        guard !isSwapping else { return }
        let snapshot = Snapshot(companies: companies, sessions: sessions, adjustments: adjustments, selectedCompanyID: selectedCompanyID)
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
