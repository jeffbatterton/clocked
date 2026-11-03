import AppKit
import Observation
import UserNotifications

/// What Claude has changed, so it can be shown and undone. Changes that come in close together,
/// like the two sessions from "9 to 11:30 Acme, then 2 hours of Northwind", make one change with
/// one notice and one Undo.
@MainActor
@Observable
final class ClaudeActivity {
    /// One edit, with what was there before. Nothing before means Claude added it.
    enum Edit {
        case session(id: UUID, before: Session?)
        case adjustment(id: UUID, before: Adjustment?)
    }

    struct Change: Identifiable {
        let id = UUID()
        var edits: [Edit] = []
        var lastAt = Date()
    }

    /// One company's line in a notice: how much time the change added or took off, if any.
    struct CompanyLine: Identifiable {
        let company: Company
        let seconds: TimeInterval
        var id: UUID { company.id }
    }

    static let noticeSeconds: TimeInterval = 8
    /// Changes this close to the last one join it.
    static let joinSeconds: TimeInterval = 20
    static let notificationCategory = "claude-change"

    /// The change shown at the bottom of the main window.
    private(set) var notice: Change?
    private(set) var noticeDeadline: Date?
    /// Time left while the pointer is over the notice, which holds it.
    private(set) var noticePausedRemaining: TimeInterval?
    /// Sessions that just changed, which glow on the timeline for a few seconds.
    private(set) var fresh: Set<UUID> = []
    private(set) var lastUsed: Date?
    private(set) var lastCompanyID: UUID?
    /// Set by the main window while it's on screen.
    var windowIsOpen = false

    @ObservationIgnored private let store: TimeStore
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let defaults: UserDefaults
    /// The change new edits join while they keep coming.
    @ObservationIgnored private(set) var current: Change?
    /// Recent changes by id, so a notification's Undo still works after the notice has gone.
    @ObservationIgnored private var recent: [UUID: Change] = [:]
    @ObservationIgnored private var noticeTimer: Timer?
    @ObservationIgnored private var freshTimer: Timer?
    /// Posts a change as a notification. Tests swap it out.
    @ObservationIgnored var notify: (Change, ClaudeActivity) -> Void = ClaudeActivity.postNotification
    /// Whether Clocked is frontmost, so the notice can show in the window.
    @ObservationIgnored var appIsActive: () -> Bool = { NSApp?.isActive ?? false }
    /// Opens the main window. Set by a view that has `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    init(store: TimeStore, prefs: Preferences, defaults: UserDefaults = .standard) {
        self.store = store
        self.prefs = prefs
        self.defaults = defaults
        lastUsed = defaults.object(forKey: Key.lastUsed) as? Date
        lastCompanyID = defaults.string(forKey: Key.lastCompany).flatMap(UUID.init)
    }

    // MARK: Recording

    /// Claude used Clocked, even just to read.
    func touch() {
        lastUsed = Date()
        defaults.set(lastUsed, forKey: Key.lastUsed)
    }

    /// Adds edits Claude just made to the current change, or starts a new one, and shows it.
    func record(_ edits: [Edit]) {
        guard !edits.isEmpty else { return }
        touch()
        let date = Date()
        var change = current.flatMap { date.timeIntervalSince($0.lastAt) < Self.joinSeconds ? $0 : nil } ?? Change()
        change.edits += edits
        change.lastAt = date
        current = change
        recent[change.id] = change
        if recent.count > 30, let oldest = recent.values.min(by: { $0.lastAt < $1.lastAt }) {
            recent[oldest.id] = nil
        }
        if let company = companyLines(for: change).first?.company.id {
            lastCompanyID = company
            defaults.set(company.uuidString, forKey: Key.lastCompany)
        }
        markFresh(edits)
        guard prefs.showClaudeChanges else { return }
        if windowIsOpen && appIsActive() {
            show(change)
        } else {
            notify(change, self)
        }
    }

    private func markFresh(_ edits: [Edit]) {
        for case let .session(id, _) in edits where store.session(id) != nil { fresh.insert(id) }
        freshTimer?.invalidate()
        freshTimer = scheduled(after: Self.noticeSeconds) { [weak self] in self?.fresh = [] }
    }

    // MARK: Undo

    /// Takes back a whole change, newest edit first. Anything you've deleted since stays deleted.
    func undo(_ id: UUID) {
        guard let change = recent[id] else { return }
        for edit in change.edits.reversed() {
            switch edit {
            case let .session(sessionID, before?):
                // A stopped timer can't run again if the company's timer has started since.
                if before.isRunning, let running = store.running(for: before.companyID), running.id != sessionID { continue }
                if store.session(sessionID) != nil { store.restore(before) }
            case let .session(sessionID, nil):
                store.deleteSession(sessionID)
            case let .adjustment(adjustmentID, before?):
                if store.adjustment(adjustmentID) != nil { store.restore(before) }
            case let .adjustment(adjustmentID, nil):
                store.deleteAdjustment(adjustmentID)
            }
        }
        recent[id] = nil
        if current?.id == id { current = nil }
        if notice?.id == id { dismissNotice() }
        fresh = []
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID(id)])
    }

    // MARK: The notice

    private func show(_ change: Change) {
        notice = change
        noticePausedRemaining = nil
        startNoticeTimer(Self.noticeSeconds)
    }

    func dismissNotice() {
        noticeTimer?.invalidate()
        notice = nil
        noticeDeadline = nil
        noticePausedRemaining = nil
    }

    /// Holds the notice while the pointer is over it.
    func setNoticeHovered(_ hovered: Bool) {
        guard notice != nil else { return }
        if hovered, let deadline = noticeDeadline {
            noticeTimer?.invalidate()
            noticePausedRemaining = max(0, deadline.timeIntervalSinceNow)
            noticeDeadline = nil
        } else if !hovered, let remaining = noticePausedRemaining {
            noticePausedRemaining = nil
            startNoticeTimer(max(remaining, 1.5))
        }
    }

    private func startNoticeTimer(_ seconds: TimeInterval) {
        noticeTimer?.invalidate()
        noticeDeadline = Date().addingTimeInterval(seconds)
        noticeTimer = scheduled(after: seconds) { [weak self] in self?.dismissNotice() }
    }

    private func scheduled(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Showing a change

    /// Brings Clocked forward on the change's first company, on the day it changed.
    func reveal(_ id: UUID) {
        if let change = recent[id], let line = companyLines(for: change).first {
            store.selectedCompanyID = line.company.id
            let day = days(of: change).first ?? store.startOfDay(store.now)
            let mode: MainMode = day == store.startOfDay(store.now) ? .today : .log
            defaults.set(mode.rawValue, forKey: "mainMode")
        }
        openMainWindow?()
        NSApp.activate()
    }

    /// Opens a company's Log, for "Show in Log" in Preferences.
    func showLog(for companyID: UUID?) {
        if let companyID { store.selectedCompanyID = companyID }
        defaults.set(MainMode.log.rawValue, forKey: "mainMode")
        openMainWindow?()
        NSApp.activate()
    }

    // MARK: Describing a change

    /// "Claude added 2 sessions", "Claude started a timer and wrote a note".
    func title(for change: Change) -> String {
        var added = 0, started = 0, stopped = 0, moved = 0, notes = 0, adjusted = 0
        for edit in change.edits {
            switch edit {
            case let .session(id, nil):
                if store.session(id)?.isRunning == true { started += 1 } else { added += 1 }
            case let .session(id, before?):
                guard let after = store.session(id) else { continue }
                if before.isRunning && !after.isRunning { stopped += 1 }
                if before.start != after.start || (!before.isRunning && before.end != after.end) { moved += 1 }
                if before.note != after.note { notes += 1 }
            case .adjustment:
                adjusted += 1
            }
        }
        let phrases = [
            phrase(added, "added a session", "added \(added) sessions"),
            phrase(started, "started a timer", "started \(started) timers"),
            phrase(stopped, "stopped a timer", "stopped \(stopped) timers"),
            phrase(moved, "moved a session", "moved \(moved) sessions"),
            phrase(notes, "wrote a note", "wrote \(notes) notes"),
            phrase(adjusted, "adjusted a day", "adjusted \(adjusted) days"),
        ].compactMap { $0 }
        guard !phrases.isEmpty else { return "Claude changed your time" }
        let list = phrases.count == 1 ? phrases[0]
            : phrases.dropLast().joined(separator: ", ") + " and " + phrases[phrases.count - 1]
        return "Claude " + list
    }

    private func phrase(_ count: Int, _ one: String, _ many: String) -> String? {
        count == 0 ? nil : count == 1 ? one : many
    }

    /// Each company the change touched, with the time it added or took off.
    func companyLines(for change: Change) -> [CompanyLine] {
        var order: [UUID] = []
        var seconds: [UUID: TimeInterval] = [:]
        func add(_ companyID: UUID, _ delta: TimeInterval) {
            if seconds[companyID] == nil { order.append(companyID) }
            seconds[companyID, default: 0] += delta
        }
        for edit in change.edits {
            switch edit {
            case let .session(id, before):
                let after = store.session(id)
                guard let companyID = after?.companyID ?? before?.companyID else { continue }
                // A running timer's time isn't settled yet, so it counts once it stops.
                let afterTime = after.map { $0.isRunning ? 0 : $0.duration(now: store.now) } ?? 0
                let beforeTime = before.map { $0.isRunning ? 0 : $0.duration(now: store.now) } ?? 0
                add(companyID, afterTime - beforeTime)
            case let .adjustment(id, before):
                let after = store.adjustment(id)
                guard let companyID = after?.companyID ?? before?.companyID else { continue }
                add(companyID, (after?.seconds ?? 0) - (before?.seconds ?? 0))
            }
        }
        return order.compactMap { id in store.company(id).map { CompanyLine(company: $0, seconds: seconds[id] ?? 0) } }
    }

    /// The days a change touched, earliest first.
    private func days(of change: Change) -> [Date] {
        let days = change.edits.compactMap { edit -> Date? in
            switch edit {
            case let .session(id, before): (store.session(id) ?? before).map { store.startOfDay($0.start) }
            case let .adjustment(id, before): (store.adjustment(id) ?? before).map { store.startOfDay($0.day) }
            }
        }
        return Array(Set(days)).sorted()
    }

    /// "Acme Co 2:30 · Northwind 2:00"
    func summary(for change: Change) -> String {
        companyLines(for: change)
            .map { $0.seconds == 0 ? $0.company.name : "\($0.company.name) \(TimeFormat.signedClockIfNegative($0.seconds))" }
            .joined(separator: " · ")
    }

    // MARK: Notifications

    static func notificationID(_ changeID: UUID) -> String { "claude-\(changeID.uuidString)" }

    /// The Mac notification for a change, with Undo and Show. A change that grows replaces its
    /// notification rather than adding another.
    private static func postNotification(_ change: Change, _ activity: ClaudeActivity) {
        let content = UNMutableNotificationContent()
        content.title = activity.title(for: change)
        content.body = activity.summary(for: change)
        content.categoryIdentifier = notificationCategory
        content.userInfo = ["change": change.id.uuidString]
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            center.add(UNNotificationRequest(identifier: notificationID(change.id), content: content, trigger: nil))
        }
    }

    static var notificationCategoryDefinition: UNNotificationCategory {
        UNNotificationCategory(
            identifier: notificationCategory,
            actions: [
                UNNotificationAction(identifier: "undo", title: "Undo"),
                UNNotificationAction(identifier: "show", title: "Show", options: [.foreground]),
            ],
            intentIdentifiers: []
        )
    }

    private enum Key {
        static let lastUsed = "claudeLastUsed"
        static let lastCompany = "claudeLastCompany"
    }
}

extension TimeFormat {
    /// "2:30", or "−0:20" when time was taken off.
    static func signedClockIfNegative(_ seconds: TimeInterval) -> String {
        seconds < 0 ? signedClock(seconds) : clock(seconds)
    }
}
