import SwiftUI

/// The dark notice at the bottom of the window when Claude changes something: what changed,
/// each company it touched (click one to go there), Undo, and a bar running down the seconds
/// left. The pointer over it holds it.
struct ClaudeNotice: View {
    let change: ClaudeActivity.Change
    @Environment(ClaudeActivity.self) private var activity
    @Environment(TimeStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: NSColor(hex: 0xe6a385)))
            HStack(spacing: 10) {
                Text(activity.title(for: change))
                    .foregroundStyle(.white)
                ForEach(activity.companyLines(for: change)) { line in
                    Button { store.selectedCompanyID = line.company.id } label: {
                        HStack(spacing: 5) {
                            CompanyDot(company: line.company, size: 7)
                            Text(line.seconds == 0 ? line.company.name : "\(line.company.name) \(TimeFormat.signedClockIfNegative(line.seconds))")
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white.opacity(0.75))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12.5))
            .lineLimit(1)

            Button { activity.undo(change.id) } label: {
                Text("Undo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Button { activity.dismissNotice() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Color(white: 0.16).opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) { countdown }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 15, y: 10)
        .fixedSize()
        .onHover { activity.setNoticeHovered($0) }
    }

    private var countdown: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: activity.noticeDeadline == nil)) { context in
            let remaining = activity.noticePausedRemaining
                ?? max(0, (activity.noticeDeadline ?? context.date).timeIntervalSince(context.date))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(.white.opacity(0.45))
                        .frame(width: geo.size.width * remaining / ClaudeActivity.noticeSeconds)
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 12)
            .padding(.bottom, 3)
        }
    }
}
