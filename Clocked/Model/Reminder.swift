import AppKit
import UserNotifications

/// The first time each day the Mac wakes (screen wakes, screen unlocks, or Clocked starts),
/// waits the minutes set in Preferences and, if no timer is running by then, posts a
/// "No timer running" notification. At most once a day.
@MainActor
final class Reminder: NSObject, UNUserNotificationCenterDelegate {
    static let lastDayKey = "reminderLastDay"

    var calendar = Calendar.current
    private let prefs: Preferences
    private let defaults: UserDefaults
    private let isRunning: () -> Bool
    private let post: () -> Void
    private var pending: Timer?

    init(
        prefs: Preferences,
        defaults: UserDefaults = .standard,
        isRunning: @escaping () -> Bool,
        post: (() -> Void)? = nil
    ) {
        self.prefs = prefs
        self.defaults = defaults
        self.isRunning = isRunning
        self.post = post ?? Reminder.postNotification
    }

    /// Starts listening for wakes, and counts this launch as one.
    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(woke), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil
        )
        UNUserNotificationCenter.current().delegate = self
        if prefs.reminderEnabled { Self.requestPermission() }
        woke()
    }

    @objc private func woke() {
        armIfFirstToday(now: Date())
    }

    /// Schedules today's check unless one has already been scheduled today.
    @discardableResult
    func armIfFirstToday(now: Date) -> Bool {
        guard prefs.reminderEnabled else { return false }
        if let last = defaults.object(forKey: Self.lastDayKey) as? Date, calendar.isDate(last, inSameDayAs: now) {
            return false
        }
        defaults.set(calendar.startOfDay(for: now), forKey: Self.lastDayKey)
        pending?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(prefs.reminderMinutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pending = timer
        return true
    }

    /// Posts the reminder if it is still wanted and nothing is running.
    func fire() {
        pending = nil
        guard prefs.reminderEnabled, !isRunning() else { return }
        post()
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postNotification() {
        let content = UNMutableNotificationContent()
        content.title = "No timer running"
        content.body = "Clocked isn't tracking any time yet today."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "no-timer-running", content: content, trigger: nil))
    }

    /// Shows the banner even when Clocked is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
