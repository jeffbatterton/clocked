import AppKit
import SwiftUI

extension Notification.Name {
    /// Changing time was turned on or off, so connected clients should fetch the tools again.
    static let claudeToolsChanged = Notification.Name("ClockedClaudeToolsChanged")
}

/// Preferences' Claude section: connect Claude Desktop with a click, copy the command for
/// Claude Code, and once connected, when Claude last used Clocked.
struct ClaudeSection: View {
    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(ClaudeActivity.self) private var activity
    @State private var desktopConnected = ClaudeConnections.isDesktopConnected
    @State private var codeConnected = ClaudeConnections.isCodeConnected
    /// Connected in this window, so Claude Desktop still needs restarting to see it.
    @State private var desktopNeedsRestart = false
    @State private var copied = false
    @State private var problem: String?

    var body: some View {
        Section {
            LabeledContent {
                if desktopConnected {
                    Button("Disconnect", action: disconnectDesktop)
                } else {
                    Button("Connect", action: connectDesktop)
                        .buttonStyle(.borderedProminent)
                }
            } label: {
                row(.desktop, "Claude Desktop") {
                    if desktopConnected {
                        ConnectedLabel(extra: desktopNeedsRestart ? "restart Claude Desktop to use it" : nil)
                    } else {
                        Text("Ask about your time and log it from any chat")
                    }
                }
            }

            if codeConnected {
                LabeledContent {
                    copyButton(copied ? "Copied" : "Copy command")
                } label: {
                    row(.code, "Claude Code") { ConnectedLabel() }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    row(.code, "Claude Code") { Text("Run this once in Terminal") }
                    HStack(spacing: 8) {
                        Text(ClaudeConnections.codeCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        copyButton(copied ? "Copied" : "Copy")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                }
            }

            if (desktopConnected || codeConnected), let lastUsed = activity.lastUsed {
                HStack {
                    lastUsedText(lastUsed)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Show in Log") { activity.showLog(for: activity.lastCompanyID ?? store.selectedCompanyID) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .alert(
            "Couldn't change Claude Desktop's settings",
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func row(_ app: ClaudeAppIcon.App, _ title: String, @ViewBuilder detail: () -> some View) -> some View {
        HStack(spacing: 10) {
            ClaudeAppIcon(app: app)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                detail()
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyButton(_ title: String) -> some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ClaudeConnections.codeCommand, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }

    /// "Last used today at 2:14 PM · added 2 sessions this week"
    private func lastUsedText(_ date: Date) -> Text {
        let calendar = prefs.calendar
        let time = TimeFormat.time(date)
        let when = calendar.isDateInToday(date) ? "today at \(time)"
            : calendar.isDateInYesterday(date) ? "yesterday at \(time)"
            : "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
        let week = calendar.dateInterval(of: .weekOfYear, for: store.now)
        let added = store.sessions.filter { $0.source == .assistant && week?.contains($0.start) == true }.count
        var text = Text("Last used ") + Text(when).foregroundColor(.primary)
        if added > 0 { text = text + Text(" · added \(added) session\(added == 1 ? "" : "s") this week") }
        return text
    }

    private func refresh() {
        desktopConnected = ClaudeConnections.isDesktopConnected
        codeConnected = ClaudeConnections.isCodeConnected
    }

    private func connectDesktop() {
        do {
            try ClaudeConnections.connectDesktop()
            desktopNeedsRestart = ClaudeConnections.desktopAppURL != nil
            refresh()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func disconnectDesktop() {
        do {
            try ClaudeConnections.disconnectDesktop()
            desktopNeedsRestart = false
            refresh()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A green dot and "Connected".
private struct ConnectedLabel: View {
    var extra: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.start).frame(width: 7, height: 7)
            Text(["Connected", extra].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

/// Claude Desktop's own icon when it's installed, and a terminal prompt for Claude Code.
private struct ClaudeAppIcon: View {
    enum App { case desktop, code }
    let app: App

    var body: some View {
        Group {
            switch app {
            case .desktop:
                if let url = ClaudeConnections.desktopAppURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xe2896a)), Color(nsColor: NSColor(hex: 0xc96442))], startPoint: .top, endPoint: .bottom))
                        .overlay(Image(systemName: "asterisk").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                }
            case .code:
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: NSColor(hex: 0x262624)))
                    .overlay(
                        Text(">_")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(nsColor: NSColor(hex: 0xe6a385)))
                    )
            }
        }
        .frame(width: 28, height: 28)
    }
}
