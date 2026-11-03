import SwiftUI

enum MainMode: String {
    case today, log
}

struct MainWindow: View {
    @Environment(TimeStore.self) private var store
    @Environment(ClaudeActivity.self) private var activity
    @AppStorage("mainMode") private var mode: MainMode = .today

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 210)
            Theme.separator.frame(width: 1)
            Group {
                if let company = store.selectedCompany {
                    VStack(spacing: 0) {
                        MainHeader(company: company, mode: $mode)
                        switch mode {
                        case .today: TodayView(company: company)
                        case .log: LogView(company: company)
                        }
                    }
                } else {
                    EmptyState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.window)
            .overlay(alignment: .bottom) {
                if let notice = activity.notice {
                    ClaudeNotice(change: notice)
                        .padding(.bottom, 34)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: activity.notice?.id)
        }
        .ignoresSafeArea()
        .opensMainWindow()
        .onAppear { activity.windowIsOpen = true }
        .onDisappear { activity.windowIsOpen = false }
    }
}

extension View {
    /// Lets Clocked open its main window from outside SwiftUI, such as from a notification.
    func opensMainWindow() -> some View { modifier(MainWindowOpener()) }
}

private struct MainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(ClaudeActivity.self) private var activity

    func body(content: Content) -> some View {
        content.onAppear { activity.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Company name on the left, Today | Log in the middle, the small timer on the right.
private struct MainHeader: View {
    let company: Company
    @Binding var mode: MainMode

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                CompanyDot(company: company, size: 11)
                Text(company.name)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                Spacer()
                TimerControl(company: company)
            }
            Picker("View", selection: $mode) {
                Text("Today").tag(MainMode.today)
                Text("Log").tag(MainMode.log)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .frame(height: 28)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }
}

/// The selected company's own timer: "● 1:22:47 Stop" while it runs, otherwise a fresh
/// "0:00:00 Start", whatever other companies are running.
private struct TimerControl: View {
    let company: Company
    @Environment(TimeStore.self) private var store

    var body: some View {
        let running = store.running(for: company.id)
        HStack(spacing: 8) {
            if running != nil {
                Circle().fill(Theme.live).frame(width: 7, height: 7)
            }
            Text(TimeFormat.stopwatch(running.map { store.now.timeIntervalSince($0.start) } ?? 0))
                .monospacedDigit()
                .foregroundStyle(running == nil ? .tertiary : .primary)
            if running != nil {
                Button { store.stop(company.id) } label: {
                    Text("Stop").foregroundStyle(Theme.live)
                }
                .controlSize(.small)
            } else {
                Button { store.start(company.id) } label: {
                    Text("Start").foregroundStyle(Theme.start)
                }
                .controlSize(.small)
            }
        }
        .fixedSize()
    }
}

private struct EmptyState: View {
    @Environment(TimeStore.self) private var store
    @State private var adding = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Add a company to start tracking time.")
                .foregroundStyle(.secondary)
            Button("Add company") { adding = true }
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    CompanyEditor(company: nil, initialColor: store.randomUnusedColorIndex()) { adding = false }
                }
        }
    }
}
