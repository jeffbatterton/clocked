import SwiftUI

struct TodayView: View {
    let company: Company
    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        VStack(spacing: 16) {
            DayTimeline(company: company)
                .frame(maxHeight: .infinity)
            HStack(spacing: 12) {
                card("Today", .day, graph: false)
                card("This Week", .weekOfYear, graph: true)
                card("This Month", .month, graph: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 22)
    }

    private func card(_ title: String, _ component: Calendar.Component, graph: Bool) -> some View {
        let calendar = prefs.calendar
        let interval = calendar.dateInterval(of: component, for: store.now) ?? DateInterval(start: store.now, duration: 0)
        let total = store.total(for: company.id, in: interval, rule: prefs.rule)
        let periodDays = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1

        return ZStack(alignment: .topLeading) {
            Theme.panel
            if graph {
                RisingArea(
                    days: store.dayTotals(for: company.id, in: interval, rule: prefs.rule),
                    periodDays: periodDays,
                    color: Palette.color(company.colorIndex)
                )
                .frame(height: 48)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            VStack(alignment: .leading, spacing: 4) {
                CapsLabel(text: title)
                Text(TimeFormat.duration(total))
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// The running total across a week or month, rising to today: a line in the company's
/// colour over a wash that fades downward, a dot at today, and a dotted line on to the
/// end of the period.
private struct RisingArea: View {
    /// Each day's total from the start of the period through today.
    let days: [TimeInterval]
    let periodDays: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let points = points(in: geo.size)
            if let last = points.last {
                curve(points, closingAt: geo.size.height)
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                curve(points)
                    .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                Path { path in
                    path.move(to: last)
                    path.addLine(to: CGPoint(x: geo.size.width, y: last.y))
                }
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 4]))
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                    .position(x: min(last.x, geo.size.width - 6), y: last.y)
            }
        }
    }

    /// One point at the start of the period, then one at the end of each day so far.
    private func points(in size: CGSize) -> [CGPoint] {
        guard periodDays > 0, !days.isEmpty else { return [] }
        var cumulative: [TimeInterval] = [0]
        for day in days { cumulative.append(cumulative.last! + day) }
        let top = max(cumulative.last! * 1.15, 1)
        let step = size.width / CGFloat(periodDays)
        return cumulative.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: size.height - 2 - CGFloat(value / top) * (size.height - 8))
        }
    }

    /// A smooth curve through the points; closed down to the bottom edge when filling.
    private func curve(_ points: [CGPoint], closingAt bottom: CGFloat? = nil) -> Path {
        Path { path in
            path.move(to: points[0])
            for (a, b) in zip(points, points.dropFirst()) {
                let mid = (a.x + b.x) / 2
                path.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
            }
            if let bottom, let last = points.last {
                path.addLine(to: CGPoint(x: last.x, y: bottom))
                path.addLine(to: CGPoint(x: points[0].x, y: bottom))
                path.closeSubpath()
            }
        }
    }
}

/// Today's sessions for the selected company laid out on a horizontal day, each block the
/// full height of the track. Other companies' time is left out. The axis runs between the
/// times set in Preferences, and grows to fit any session that falls outside them.
struct TimelineModel {
    struct Block: Identifiable {
        let id: UUID
        let start: TimeInterval
        let end: TimeInterval
        let startDate: Date
        let endDate: Date?
    }

    var blocks: [Block] = []
    var total: TimeInterval = 0
    var rangeStart: TimeInterval
    var rangeEnd: TimeInterval
    var configuredStart: TimeInterval
    var configuredEnd: TimeInterval
    var now: TimeInterval

    @MainActor
    init(store: TimeStore, prefs: Preferences, companyID: UUID) {
        let dayStart = store.startOfDay(store.now)
        configuredStart = TimeInterval(prefs.timelineStartHour) * 3600
        configuredEnd = TimeInterval(prefs.timelineEndHour) * 3600
        now = store.now.timeIntervalSince(dayStart)

        let todays = store.sessions
            .filter { $0.companyID == companyID && store.startOfDay($0.start) == dayStart }
            .sorted { $0.start < $1.start }

        var low = configuredStart, high = configuredEnd
        for session in todays {
            let a = session.start.timeIntervalSince(dayStart)
            let b = max(a, (session.end ?? store.now).timeIntervalSince(dayStart))
            total += b - a
            blocks.append(Block(id: session.id, start: a, end: b, startDate: session.start, endDate: session.end))
            low = min(low, (a / 3600).rounded(.down) * 3600)
            high = max(high, (b / 3600).rounded(.up) * 3600)
        }
        rangeStart = low
        rangeEnd = max(high, low + 3600)
    }

    var hours: [Int] {
        let first = Int(rangeStart / 3600), last = Int(rangeEnd / 3600)
        let step = last - first > 14 ? 2 : 1
        return Array(stride(from: first, through: last, by: step))
    }
}

struct DayTimeline: View {
    let company: Company
    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        let model = TimelineModel(store: store, prefs: prefs, companyID: company.id)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                CapsLabel(text: TimeFormat.longDay(store.now))
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    CompanyDot(company: company, size: 8)
                    Text("\(company.name) \(TimeFormat.duration(model.total))")
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                TimelineTrack(model: model, company: company, size: geo.size)
            }
            .overlay {
                if model.blocks.isEmpty {
                    Text("Nothing logged today")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TimelineTrack: View {
    let model: TimelineModel
    let company: Company
    let size: CGSize

    @Environment(TimeStore.self) private var store

    private let labelHeight: CGFloat = 18
    /// Room above the blocks for the current time on the now line.
    private let topInset: CGFloat = 22

    private func x(_ t: TimeInterval) -> CGFloat {
        CGFloat((t - model.rangeStart) / (model.rangeEnd - model.rangeStart)) * size.width
    }

    var body: some View {
        let trackHeight = max(0, size.height - labelHeight)

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                // Time outside the usual start and end is hatched, with a dashed edge.
                for (a, b, edge) in overflow {
                    let rect = CGRect(x: x(a), y: 0, width: x(b) - x(a), height: trackHeight)
                    context.drawLayer { layer in
                        layer.clip(to: Path(rect))
                        var stripes = Path()
                        var sx = rect.minX - rect.height
                        while sx < rect.maxX {
                            stripes.move(to: CGPoint(x: sx, y: rect.maxY))
                            stripes.addLine(to: CGPoint(x: sx + rect.height, y: rect.minY))
                            sx += 8
                        }
                        layer.stroke(stripes, with: .color(Theme.grid), lineWidth: 4)
                    }
                    var line = Path()
                    line.move(to: CGPoint(x: x(edge), y: 0))
                    line.addLine(to: CGPoint(x: x(edge), y: trackHeight))
                    context.stroke(line, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for hour in model.hours {
                    let rect = CGRect(x: x(TimeInterval(hour) * 3600) - 0.5, y: 0, width: 1, height: trackHeight)
                    context.fill(Path(rect), with: .color(Theme.grid))
                }
            }

            ForEach(model.hours, id: \.self) { hour in
                Text(TimeFormat.hourLabel(hour))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: x(TimeInterval(hour) * 3600), y: trackHeight + labelHeight / 2 + 2)
            }

            ForEach(model.blocks) { block in
                TimelineBlock(block: block, company: company)
                    .frame(width: max(3, x(block.end) - x(block.start)), height: max(0, trackHeight - topInset - 6))
                    .offset(x: x(block.start), y: topInset)
            }

            if model.now >= model.rangeStart, model.now <= model.rangeEnd {
                Rectangle()
                    .fill(Theme.live)
                    .frame(width: 2, height: max(0, trackHeight - 8))
                    .offset(x: x(model.now) - 1, y: 8)
                Text(TimeFormat.shortTime(store.now))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.live, in: RoundedRectangle(cornerRadius: 4))
                    .position(x: x(model.now), y: 8)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Hatched stretches before the start time or after the end time, with the edge to dash.
    private var overflow: [(TimeInterval, TimeInterval, TimeInterval)] {
        var ranges: [(TimeInterval, TimeInterval, TimeInterval)] = []
        if model.rangeStart < model.configuredStart {
            ranges.append((model.rangeStart, model.configuredStart, model.configuredStart))
        }
        if model.rangeEnd > model.configuredEnd {
            ranges.append((model.configuredEnd, model.rangeEnd, model.configuredEnd))
        }
        return ranges
    }
}

/// One session: its length, then the time range, in the top-left corner.
private struct TimelineBlock: View {
    let block: TimelineModel.Block
    let company: Company

    private var range: String {
        let start = TimeFormat.shortTime(block.startDate)
        guard let end = block.endDate else { return "\(start) – now" }
        return "\(start)–\(TimeFormat.shortTime(end))"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let duration = TimeFormat.duration(block.end - block.start)
        shape
            .fill(Palette.color(company.colorIndex))
            .overlay {
                if block.endDate == nil { RunningStripes() }
            }
            .overlay(alignment: .topLeading) {
                // Labels run under the block's edge rather than ending in "…"; tiny blocks have none.
                GeometryReader { geo in
                    if geo.size.width >= 28 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(duration).fontWeight(.semibold)
                            Text(range)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                    }
                }
            }
            .clipShape(shape)
            .help("\(company.name) · \(range) · \(duration)")
    }
}

private struct RunningStripes: View {
    var body: some View {
        Canvas { context, size in
            var stripes = Path()
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 12
            }
            context.stroke(stripes, with: .color(.white.opacity(0.18)), lineWidth: 6)
        }
    }
}
