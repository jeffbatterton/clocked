import SwiftUI

struct TodayView: View {
    let company: Company
    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        let model = TimelineModel(store: store, prefs: prefs, companyID: company.id)

        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatCard(title: "Today", value: TimeFormat.clock(model.total), points: model.climb, color: Palette.color(company.colorIndex))
                periodCard("This Week", .weekOfYear)
                periodCard("This Month", .month)
            }
            DayTimeline(company: company, model: model)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 22)
    }

    /// The period's rounded total, with its running total day by day.
    private func periodCard(_ title: String, _ component: Calendar.Component) -> some View {
        let calendar = prefs.calendar
        let interval = calendar.dateInterval(of: component, for: store.now) ?? DateInterval(start: store.now, duration: 0)
        let periodDays = max(1, calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
        let days = store.dayTotals(for: company.id, in: interval, rule: prefs.rule)
        var points = [CGPoint(x: 0, y: 0)]
        for (index, day) in days.enumerated() {
            points.append(CGPoint(x: CGFloat(index + 1) / CGFloat(periodDays), y: points.last!.y + day))
        }
        return StatCard(
            title: title,
            value: TimeFormat.duration(store.total(for: company.id, in: interval, rule: prefs.rule)),
            points: points,
            color: Palette.color(company.colorIndex)
        )
    }
}

/// A short card: a caps title and a total on the left, a small graph on the right.
private struct StatCard: View {
    let title: String
    let value: String
    let points: [CGPoint]
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.panel
            GeometryReader { geo in
                RisingArea(points: points, color: color)
                    .frame(width: geo.size.width * 0.55, height: 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                CapsLabel(text: title)
                Text(value)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A running total rising to now: a line in the company's colour over a wash that fades
/// downward, a dot at the latest point, and a dotted line on to the end of the period.
/// Each point's x runs 0 to 1 across the period; its y is the total so far.
private struct RisingArea: View {
    let points: [CGPoint]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let points = scaled(to: geo.size)
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

    private func scaled(to size: CGSize) -> [CGPoint] {
        guard points.count > 1 else { return [] }
        let top = max((points.map(\.y).max() ?? 0) * 1.15, 1)
        return points.map { point in
            CGPoint(x: point.x * size.width, y: size.height - 2 - point.y / top * (size.height - 8))
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

/// A day's sessions for one company, laid out down the day. Other companies' time is left
/// out. The day runs between the times set in Preferences and grows to fit any session that
/// falls outside them; trimmed, it runs from an hour before the first session to an hour
/// after the last. Times are seconds since the start of the day.
struct TimelineModel {
    struct Block: Identifiable {
        let session: Session
        let start: TimeInterval
        let end: TimeInterval
        var id: UUID { session.id }
    }

    /// Time between two sessions.
    struct Gap: Identifiable {
        let start: Date
        let end: Date
        let from: TimeInterval
        let to: TimeInterval
        var id: TimeInterval { from }
    }

    var blocks: [Block] = []
    var gaps: [Gap] = []
    var total: TimeInterval = 0
    var rangeStart: TimeInterval
    var rangeEnd: TimeInterval
    var configuredStart: TimeInterval
    var configuredEnd: TimeInterval
    var now: TimeInterval
    /// Only today has a now line.
    var isToday: Bool

    /// Gaps shorter than this, like switching tasks, are left alone.
    static let shortestGap: TimeInterval = 5 * 60

    @MainActor
    init(store: TimeStore, prefs: Preferences, companyID: UUID, day: Date? = nil, trimmed: Bool = false) {
        let dayStart = store.startOfDay(day ?? store.now)
        isToday = dayStart == store.startOfDay(store.now)
        configuredStart = TimeInterval(prefs.timelineStartHour) * 3600
        configuredEnd = TimeInterval(prefs.timelineEndHour) * 3600
        now = store.now.timeIntervalSince(dayStart)
        total = store.actualTotal(for: companyID, on: dayStart)

        var low = configuredStart, high = configuredEnd
        for session in store.sessions(for: companyID, on: dayStart) {
            let a = session.start.timeIntervalSince(dayStart)
            let b = max(a, (session.end ?? store.now).timeIntervalSince(dayStart))
            if let previous = blocks.last, a - previous.end >= Self.shortestGap {
                gaps.append(Gap(start: previous.session.end ?? store.now, end: session.start, from: previous.end, to: a))
            }
            blocks.append(Block(session: session, start: a, end: b))
            low = min(low, (a / 3600).rounded(.down) * 3600)
            high = max(high, (b / 3600).rounded(.up) * 3600)
        }
        if trimmed {
            // No hatching: the trimmed day is all "usual hours".
            if let first = blocks.first, let last = blocks.last {
                low = max(0, (first.start / 3600).rounded(.down) * 3600 - 3600)
                high = min(48 * 3600, (last.end / 3600).rounded(.up) * 3600 + 3600)
            } else {
                low = 9 * 3600
                high = 17 * 3600
            }
            configuredStart = low
            configuredEnd = high
        }
        rangeStart = low
        rangeEnd = max(high, low + 3600)
    }

    var hours: [Int] { Array(Int(rangeStart / 3600)...Int(rangeEnd / 3600)) }

    /// Time adding up through the day for the Today card: climbing during sessions, flat
    /// between them, ending at now.
    var climb: [CGPoint] {
        let span = rangeEnd - rangeStart
        func x(_ t: TimeInterval) -> CGFloat { CGFloat((t - rangeStart) / span) }
        var points = [CGPoint(x: 0, y: 0)]
        var sum: TimeInterval = 0
        for block in blocks {
            points.append(CGPoint(x: x(block.start), y: sum))
            sum += block.end - block.start
            points.append(CGPoint(x: x(block.end), y: sum))
        }
        points.append(CGPoint(x: x(min(max(now, rangeStart), rangeEnd)), y: sum))
        return points
    }
}

struct DayTimeline: View {
    let company: Company
    let model: TimelineModel
    @Environment(TimeStore.self) private var store
    @State private var openSession: UUID?

    /// Tall enough for a session's times and a line of note in an hour.
    private let minHourHeight: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                CapsLabel(text: TimeFormat.longDay(store.now))
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    CompanyDot(company: company, size: 8)
                    Text("\(company.name) \(TimeFormat.clock(model.total))")
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)

            GeometryReader { geo in
                let hourCount = CGFloat(max(1, model.hours.count - 1))
                let height = max(geo.size.height, hourCount * minHourHeight)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        TimelineTrack(
                            model: model,
                            company: company,
                            size: CGSize(width: geo.size.width, height: height),
                            openSession: $openSession
                        )
                    }
                    .scrollIndicators(.automatic)
                    .scrollDisabled(height <= geo.size.height)
                    .onAppear { proxy.scrollTo(TimelineTrack.nowID, anchor: .center) }
                }
            }
            .overlay {
                if model.blocks.isEmpty {
                    Text("Nothing logged today")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The hours, sessions, gaps and now line of a day. Clicking a session opens its times: in a
/// popover, or with `inlineTimes`, right in the block (for use inside another popover).
struct TimelineTrack: View {
    static let nowID = "now"

    let model: TimelineModel
    let company: Company
    let size: CGSize
    @Binding var openSession: UUID?
    var inlineTimes = false

    @Environment(TimeStore.self) private var store
    @FocusState private var focusedNote: UUID?
    @State private var hoveredGap: TimeInterval?

    private let labelWidth: CGFloat = 54
    private let lineX: CGFloat = 64
    private let blockX: CGFloat = 72
    /// Room right of the blocks for an open block's ring, which the scroll view would clip.
    private let ringRoom: CGFloat = 4
    /// Room above the first hour and below the last for their labels.
    private let inset: CGFloat = 8

    private func y(_ t: TimeInterval) -> CGFloat {
        inset + CGFloat((t - model.rangeStart) / (model.rangeEnd - model.rangeStart)) * (size.height - inset * 2)
    }

    var body: some View {
        let blockWidth = max(0, size.width - blockX - ringRoom)
        let nowY = y(model.now)
        let showsNow = model.isToday && model.now >= model.rangeStart && model.now <= model.rangeEnd

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                // Time outside the usual start and end is hatched.
                for (a, b) in overflow {
                    let rect = CGRect(x: lineX, y: y(a), width: size.width - lineX, height: y(b) - y(a))
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
                }
                for hour in model.hours {
                    let rect = CGRect(x: lineX, y: y(TimeInterval(hour) * 3600) - 0.5, width: size.width - lineX, height: 1)
                    context.fill(Path(rect), with: .color(Theme.grid))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focusedNote = nil }

            ForEach(model.hours, id: \.self) { hour in
                let hourY = y(TimeInterval(hour) * 3600)
                // The now time takes the place of an hour it would sit on.
                if !(showsNow && abs(hourY - nowY) < 12) {
                    Text(TimeFormat.hourName(hour))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                        .position(x: labelWidth / 2, y: hourY)
                }
            }

            ForEach(model.gaps) { gap in
                GapArea(gap: gap, color: Palette.color(company.colorIndex), isHovered: hoveredGap == gap.id) {
                    let session = store.addSession(companyID: company.id, start: gap.start, end: gap.end)
                    hoveredGap = nil
                    // Its block appears on the next update; type its note straight away.
                    DispatchQueue.main.async { focusedNote = session.id }
                }
                .frame(width: blockWidth, height: max(0, y(gap.to) - y(gap.from) - 2))
                .onHover { hoveredGap = $0 ? gap.id : (hoveredGap == gap.id ? nil : hoveredGap) }
                .offset(x: blockX, y: y(gap.from) + 1)
            }

            ForEach(model.blocks) { block in
                let isEditing = inlineTimes && openSession == block.id
                // Time fields need room; an open short block grows over its neighbours.
                let height = max(isEditing ? 58 : 18, y(block.end) - y(block.start) - 2)
                SessionBlock(
                    session: block.session,
                    company: company,
                    height: height,
                    inlineTimes: inlineTimes,
                    focusedNote: $focusedNote,
                    openSession: $openSession
                )
                .frame(width: blockWidth, height: height)
                .offset(x: blockX, y: y(block.start) + 1)
                .zIndex(isEditing ? 1 : 0)
            }

            if showsNow {
                Rectangle()
                    .fill(Theme.live)
                    .frame(width: size.width - lineX, height: 2)
                    .overlay(alignment: .leading) {
                        Circle().fill(Theme.live).frame(width: 8, height: 8).offset(x: -4)
                    }
                    .offset(x: lineX, y: nowY - 1)
                    .allowsHitTesting(false)
                Text(TimeFormat.shortTime(store.now))
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.live)
                    .frame(width: labelWidth + 2, alignment: .trailing)
                    .position(x: labelWidth / 2, y: nowY)
                    .id(Self.nowID)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Stretches before the start time or after the end time.
    private var overflow: [(TimeInterval, TimeInterval)] {
        var ranges: [(TimeInterval, TimeInterval)] = []
        if model.rangeStart < model.configuredStart { ranges.append((model.rangeStart, model.configuredStart)) }
        if model.rangeEnd > model.configuredEnd { ranges.append((model.configuredEnd, model.rangeEnd)) }
        return ranges
    }
}

/// Untracked time between two sessions. Blank until the pointer is over it, then a dashed
/// box with its length and a way to fill it.
private struct GapArea: View {
    let gap: TimelineModel.Gap
    let color: Color
    let isHovered: Bool
    var add: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                if isHovered {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.window.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(color.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        )
                    if geo.size.height >= 18 {
                        HStack {
                            Text("\(TimeFormat.duration(gap.to - gap.from)) not tracked · \(TimeFormat.range(gap.start, gap.end))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                            Text("+ Add session").foregroundStyle(color)
                        }
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: add)
        .help("Add a session for this time")
    }
}

/// One session: its times and length, and its note, typed straight into the block. Clicking
/// anywhere but the note opens its times, in a popover or (with `inlineTimes`) in the block.
private struct SessionBlock: View {
    let session: Session
    let company: Company
    let height: CGFloat
    let inlineTimes: Bool
    var focusedNote: FocusState<UUID?>.Binding
    @Binding var openSession: UUID?

    @Environment(TimeStore.self) private var store
    @State private var draft = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var problem: String?
    /// Set when the times were already saved or thrown away, so closing doesn't save them.
    @State private var settled = false

    private var isFocused: Bool { focusedNote.wrappedValue == session.id }
    private var isOpen: Bool { openSession == session.id }
    private var editsTimes: Bool { inlineTimes && isOpen }

    var body: some View {
        let color = Palette.color(company.colorIndex)
        let running = session.isRunning
        // Short sessions put the note beside the times.
        let compact = height < 40 && !editsTimes

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(running ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.16)))
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    focusedNote.wrappedValue = nil
                    openSession = session.id
                }

            Group {
                if compact {
                    HStack(spacing: 10) {
                        noteField(running: running, compact: true)
                        times(running: running)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        if editsTimes {
                            timeFields(running: running)
                        } else {
                            times(running: running)
                        }
                        noteField(running: running, compact: false)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isOpen {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color, lineWidth: 2)
                    .padding(-3)
            }
        }
        .popover(
            isPresented: Binding(get: { isOpen && !inlineTimes }, set: { if !$0 { openSession = nil } }),
            arrowEdge: .bottom
        ) {
            SessionPopover(session: session, color: color) { openSession = nil }
        }
        .background {
            if editsTimes { SaveKeys(save: saveTimes, cancel: cancelTimes) }
        }
        .onAppear { draft = session.note }
        .onChange(of: session.note) { _, note in
            if !isFocused { draft = note }
        }
        .onChange(of: focusedNote.wrappedValue) { old, new in
            if old == session.id, new != session.id { store.setNote(draft, for: session.id) }
        }
        .onChange(of: isOpen) { wasOpen, open in
            guard inlineTimes else { return }
            if open {
                start = session.start
                end = session.end ?? store.now
                problem = nil
                settled = false
            } else if wasOpen, !settled {
                // Clicking elsewhere keeps the new times, if they work.
                commitTimes()
            }
        }
        .onDisappear {
            if editsTimes, !settled { commitTimes() }
        }
    }

    private func times(running: Bool) -> some View {
        HStack {
            Text(TimeFormat.range(session.start, session.end))
            Spacer(minLength: 8)
            Text(TimeFormat.clock(session.duration(now: store.now))).fontWeight(.semibold)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(running ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .fixedSize(horizontal: height < 40, vertical: false)
        .allowsHitTesting(false)
    }

    /// Start and end fields in place of the times, with Delete beside them.
    private func timeFields(running: Bool) -> some View {
        let length = (running ? store.now : store.moving(end, to: session.start))
            .timeIntervalSince(store.moving(start, to: session.start))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                Text("–").foregroundStyle(running ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                if running {
                    Text("now").foregroundStyle(.white.opacity(0.85))
                } else {
                    DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                }
                // A running timer is discarded from Today, where it asks first.
                if !running {
                    Button("Delete") {
                        settled = true
                        store.deleteSession(session.id)
                        openSession = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.live)
                    .padding(.leading, 6)
                }
                Spacer(minLength: 6)
                Text(TimeFormat.clock(max(0, length)))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(running ? Color.white : Color.primary)
            }
            .labelsHidden()
            .datePickerStyle(.field)
            .controlSize(.small)
            .font(.system(size: 11))
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(running ? Color.white : Theme.live)
                    .lineLimit(1)
            }
        }
    }

    private func saveTimes() {
        if commitTimes() {
            settled = true
            openSession = nil
        }
    }

    private func cancelTimes() {
        settled = true
        openSession = nil
    }

    /// Saves the fields; false, with the reason shown, if the times don't work.
    @discardableResult
    private func commitTimes() -> Bool {
        let start = store.moving(start, to: session.start)
        let end = session.isRunning ? nil : store.moving(end, to: session.start)
        if let issue = store.problem(withTimes: start, end, for: session.companyID, excluding: session.id) {
            problem = issue
            return false
        }
        if start != session.start || end != session.end {
            store.setTimes(for: session.id, start: start, end: end)
        }
        return true
    }

    private func noteField(running: Bool, compact: Bool) -> some View {
        let color = Palette.color(company.colorIndex)
        return TextField(
            "Note",
            text: $draft,
            prompt: Text("+ Add a note").foregroundStyle(running ? Color.white.opacity(0.6) : color.opacity(0.55)),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.system(size: 13.5))
        .foregroundStyle(running ? Color.white : Color.primary)
        .lineLimit(compact ? 1...1 : 1...6)
        .focused(focusedNote, equals: session.id)
        .onSubmit { focusedNote.wrappedValue = nil }
        .onExitCommand {
            draft = session.note
            focusedNote.wrappedValue = nil
        }
    }
}

/// A session's start and end. A running session has only its start, and can be discarded.
private struct SessionPopover: View {
    let session: Session
    let color: Color
    var onDone: () -> Void

    @Environment(TimeStore.self) private var store
    @State private var start = Date()
    @State private var end = Date()
    @State private var problem: String?
    @State private var confirmingDiscard = false

    var body: some View {
        let running = session.isRunning
        let length = (running ? store.now : store.moving(end, to: session.start)).timeIntervalSince(store.moving(start, to: session.start))

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if running {
                    Circle().fill(Theme.live).frame(width: 7, height: 7)
                    Text("Running session").fontWeight(.semibold)
                    Text("· since \(TimeFormat.time(session.start))").foregroundStyle(.secondary)
                } else {
                    Text("Edit session").fontWeight(.semibold)
                    Text("· \(TimeFormat.rowDay(session.start))").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.bottom, 4)

            HStack(spacing: 10) {
                Text("Start").foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                Spacer()
                Text(TimeFormat.clock(max(0, length)))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            HStack(spacing: 10) {
                Text("End").foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                if running {
                    Text("Still running").foregroundStyle(.secondary)
                } else {
                    DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                }
            }

            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.live)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(running ? "Discard session" : "Delete session") {
                    if running, session.duration(now: store.now) > 5 * 60 {
                        confirmingDiscard = true
                    } else {
                        delete()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.live)
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(color)
            }
            .controlSize(.small)
            .padding(.top, 6)
        }
        .labelsHidden()
        .datePickerStyle(.field)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 290)
        .onAppear {
            start = session.start
            end = session.end ?? store.now
        }
        .alert("Discard this session?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its \(TimeFormat.clock(session.duration(now: store.now))) will be deleted and the timer stops.")
        }
    }

    private func save() {
        let start = store.moving(start, to: session.start)
        let end = session.isRunning ? nil : store.moving(end, to: session.start)
        if let issue = store.problem(withTimes: start, end, for: session.companyID, excluding: session.id) {
            problem = issue
            return
        }
        store.setTimes(for: session.id, start: start, end: end)
        onDone()
    }

    private func delete() {
        store.deleteSession(session.id)
        onDone()
    }
}
