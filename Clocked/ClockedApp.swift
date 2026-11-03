import AppKit
import SwiftUI

@main
struct ClockedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: TimeStore
    @State private var prefs = Preferences.shared
    @State private var reminder: Reminder
    @State private var activity: ClaudeActivity
    @State private var router: NotificationRouter
    @State private var socket: MCPSocketServer

    init() {
        let store = TimeStore(testDrive: Preferences.shared.testDrive)
        let reminder = Reminder(prefs: .shared, isRunning: { store.isAnyRunning })
        let activity = ClaudeActivity(store: store, prefs: .shared)
        let server = MCPServer(tools: ClaudeTools(store: store, prefs: .shared, activity: activity))
        let socket = MCPSocketServer { server.handle($0) }
        let router = NotificationRouter(activity: activity)
        _store = State(initialValue: store)
        _reminder = State(initialValue: reminder)
        _activity = State(initialValue: activity)
        _router = State(initialValue: router)
        _socket = State(initialValue: socket)
        // Not while unit tests run inside the app, so they never use up today's reminder or
        // take the running app's socket.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            DispatchQueue.main.async {
                router.start()
                reminder.start()
                socket.start()
            }
            NotificationCenter.default.addObserver(forName: .claudeToolsChanged, object: nil, queue: .main) { _ in
                socket.broadcast(MCPServer.toolsChangedMessage)
            }
        }
    }

    var body: some Scene {
        Window("Clocked", id: "main") {
            MainWindow()
                .environment(store)
                .environment(prefs)
                .environment(activity)
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
                .opensMainWindow()
                .environment(activity)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
                .environment(store)
                .environment(prefs)
                .environment(activity)
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
