import AppKit
import SwiftUI

@main
struct ClockedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: TimeStore
    @State private var prefs = Preferences.shared
    @State private var reminder: Reminder

    init() {
        let store = TimeStore(testDrive: Preferences.shared.testDrive)
        let reminder = Reminder(prefs: .shared, isRunning: { store.running != nil })
        _store = State(initialValue: store)
        _reminder = State(initialValue: reminder)
        // Not while unit tests run inside the app, so they never use up today's reminder.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            DispatchQueue.main.async { reminder.start() }
        }
    }

    var body: some Scene {
        Window("Clocked", id: "main") {
            MainWindow()
                .environment(store)
                .environment(prefs)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 900, height: 560)

        // Also follows the item being dragged out of the menu bar with ⌘.
        MenuBarExtra(isInserted: Binding(get: { prefs.showMenuBarItem }, set: { prefs.showMenuBarItem = $0 })) {
            MenuBarPanel()
                .environment(store)
                .environment(prefs)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
                .environment(store)
                .environment(prefs)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.shared.applyAppearance()
    }

    /// Closing the window leaves Clocked running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
