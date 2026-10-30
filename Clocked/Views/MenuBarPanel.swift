import AppKit
import SwiftUI

/// The red dot (running) or a clock (stopped) beside today's time, with the current company's
/// name in tiny type underneath. Live time, not rounded.
struct MenuBarLabel: View {
    @Environment(TimeStore.self) private var store

    var body: some View {
        let company = store.currentCompany
        let total = company.map { store.actualTotal(for: $0.id, on: store.currentDay(for: $0.id)) } ?? 0
        let time = TimeFormat.clock(total)
        Image(nsImage: MenuBarLabelImage.make(time: time, company: company?.name, running: store.running != nil))
            .accessibilityLabel([time, company?.name, store.running != nil ? "running" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The menu bar only takes one icon and one line of text, so the two-line label is drawn as a
/// single image. Stopped, it is a template image the system tints to suit the menu bar; running,
/// it keeps the red dot and draws its text in the label colour for the menu bar's appearance.
enum MenuBarLabelImage {
    private static let height: CGFloat = 22
    /// Extra room on each side, beyond the menu bar's own spacing.
    private static let inset: CGFloat = 5
    private static let maxNameWidth: CGFloat = 90
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    private static let nameFont = NSFont.systemFont(ofSize: 8, weight: .medium)

    static func make(time: String, company: String?, running: Bool) -> NSImage {
        let timeWidth = ceil((time as NSString).size(withAttributes: [.font: timeFont]).width)
        let nameWidth = company.map { min(ceil(($0 as NSString).size(withAttributes: [.font: nameFont]).width), maxNameWidth) } ?? 0
        let iconWidth: CGFloat = running ? 7 : 13
        let textX = inset + iconWidth + 4
        let size = NSSize(width: textX + max(timeWidth, nameWidth) + inset, height: height)

        let image = NSImage(size: size, flipped: true) { _ in
            let ink: NSColor = running ? .labelColor : .black
            if running {
                NSColor(hex: 0xe5484d).setFill()
                NSBezierPath(ovalIn: NSRect(x: inset, y: (height - 7) / 2, width: 7, height: 7)).fill()
            } else if let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) {
                clock.draw(in: NSRect(x: inset, y: (height - 13) / 2, width: 13, height: 13))
            }

            let timeAttributes: [NSAttributedString.Key: Any] = [.font: timeFont, .foregroundColor: ink]
            guard let company else {
                let timeHeight = (time as NSString).size(withAttributes: timeAttributes).height
                (time as NSString).draw(at: NSPoint(x: textX, y: (height - timeHeight) / 2), withAttributes: timeAttributes)
                return true
            }
            (time as NSString).draw(at: NSPoint(x: textX, y: -1), withAttributes: timeAttributes)
            let truncate = NSMutableParagraphStyle()
            truncate.lineBreakMode = .byTruncatingTail
            (company as NSString).draw(
                with: NSRect(x: textX, y: 12.5, width: nameWidth, height: 10),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: nameFont, .foregroundColor: ink.withAlphaComponent(0.75), .paragraphStyle: truncate]
            )
            return true
        }
        image.isTemplate = !running
        return image
    }
}

/// Today's time with Start/Stop, the companies to switch between, then the app commands.
struct MenuBarPanel: View {
    @Environment(TimeStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let company = store.currentCompany {
                header(company)
            } else {
                Text("No companies yet")
                    .foregroundStyle(.secondary)
                    .padding(10)
            }

            if !store.companies.isEmpty {
                separator
                Text("Companies")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                ForEach(store.companies) { company in
                    MenuRow(action: { store.switchTo(company.id) }) { highlighted in
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(company.id == store.currentCompanyID ? 1 : 0)
                            .frame(width: 12)
                        CompanyDot(company: company, size: 8)
                        Text(company.name).lineLimit(1)
                        Spacer()
                        Text(TimeFormat.clock(store.actualTotal(for: company.id, on: store.currentDay(for: company.id))))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(highlighted ? .white.opacity(0.75) : .secondary)
                    }
                }
            }

            separator
            command("Open Clocked", key: "o", symbol: "⌘O") {
                openWindow(id: "main")
                NSApp.activate()
            }
            command("Preferences…", key: ",", symbol: "⌘,") {
                openSettings()
                NSApp.activate()
            }
            separator
            command("Quit Clocked", key: "q", symbol: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(5)
        .frame(width: 260)
    }

    private func header(_ company: Company) -> some View {
        let isRunning = store.running != nil
        let total = store.actualTotal(for: company.id, on: store.currentDay(for: company.id))

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    CompanyDot(company: company, size: 8)
                    Text("\(company.name) · today").lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Text(TimeFormat.duration(total))
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
            }
            Spacer()
            Button {
                if isRunning { store.stop() } else { store.start(company.id) }
            } label: {
                Text(isRunning ? "Stop" : "Start")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRunning ? Theme.live : Theme.start)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func command(_ title: String, key: KeyEquivalent, symbol: String, action: @escaping () -> Void) -> some View {
        MenuRow(action: {
            dismiss()
            action()
        }) { highlighted in
            Color.clear.frame(width: 12, height: 1)
            Text(title)
            Spacer()
            Text(symbol)
                .font(.system(size: 12))
                .foregroundStyle(highlighted ? .white.opacity(0.75) : .secondary)
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}

/// A menu-style row that highlights in the accent colour on hover.
private struct MenuRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content(hovering) }
                .foregroundStyle(hovering ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(hovering ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
