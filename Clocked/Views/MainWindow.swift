import SwiftUI

enum MainMode: String {
    case today, log
}

struct MainWindow: View {
    @Environment(TimeStore.self) private var store
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
        }
        .ignoresSafeArea()
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

/// "● 1:22:47 Stop" while running, otherwise "Start" for the selected company.
private struct TimerControl: View {
    let company: Company
    @Environment(TimeStore.self) private var store

    var body: some View {
        if let running = store.running {
            HStack(spacing: 8) {
                Circle().fill(Theme.live).frame(width: 7, height: 7)
                // The running company's name under the time, as in the menu bar item.
                VStack(alignment: .leading, spacing: 0) {
                    Text(TimeFormat.stopwatch(store.now.timeIntervalSince(running.start)))
                        .monospacedDigit()
                    if let runningCompany = store.company(running.companyID) {
                        Text(runningCompany.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .leading)
                    }
                }
                .fixedSize()
                Button { store.stop() } label: {
                    Text("Stop").foregroundStyle(Theme.live)
                }
                .controlSize(.small)
            }
        } else {
            Button { store.start(company.id) } label: {
                Text("Start").foregroundStyle(Theme.start)
            }
            .controlSize(.small)
        }
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
