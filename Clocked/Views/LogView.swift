import SwiftUI

/// The selected company's month as a calendar. Each day shows its rounded (billed) time and a
/// pill for each session; hovering shows its actual time, and clicking opens the day to add or
/// edit time. Future days open too, so time over a monthly cap can be rolled ahead.
struct LogView: View {
    let company: Company
    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs

    @State private var month = Date()
    @State private var editingDay: Date?

    var body: some View {
        let calendar = prefs.calendar
        let monthInterval = calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, duration: 0)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(TimeFormat.month(monthInterval.start))
                    .font(.system(size: 20, weight: .bold))
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous month")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next month")
                Spacer()
                Text("Total").foregroundStyle(.secondary)
                Text(TimeFormat.duration(store.total(for: company.id, in: monthInterval, rule: prefs.rule)))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
            }
            .controlSize(.small)

            MonthGrid(
                company: company,
                monthInterval: monthInterval,
                calendar: calendar,
                editingDay: $editingDay
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .onChange(of: company.id) { month = Date() }
    }

    private func step(_ months: Int) {
        month = prefs.calendar.date(byAdding: .month, value: months, to: month) ?? month
    }
}

private struct MonthGrid: View {
    let company: Company
    let monthInterval: DateInterval
    let calendar: Calendar
    @Binding var editingDay: Date?

    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs

    /// The month's days, padded with nils so the first lands under its weekday.
    private var slots: [Date?] {
        let leading = (calendar.component(.weekday, from: monthInterval.start) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: monthInterval.start)?.count ?? 30
        var slots: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            slots.append(calendar.date(byAdding: .day, value: offset, to: monthInterval.start))
        }
        while slots.count % 7 != 0 { slots.append(nil) }
        return slots
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        let slots = slots
        let totals = store.dailyTotals(for: company.id)
        // Each day's sessions, gathered once for the whole month.
        let sessionsByDay = Dictionary(grouping: store.sessions.filter { $0.companyID == company.id }) {
            store.startOfDay($0.start)
        }

        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(0..<(slots.count / 7), id: \.self) { week in
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { weekday in
                        if let day = slots[week * 7 + weekday] {
                            let key = store.startOfDay(day)
                            DayCell(
                                company: company,
                                day: key,
                                seconds: totals[key] ?? 0,
                                sessions: (sessionsByDay[key] ?? []).sorted { $0.start < $1.start },
                                editingDay: $editingDay
                            )
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }
}

/// A day: its number, its billed time and a pill per session. Hovering tints it and shows the
/// actual time; clicking opens it.
private struct DayCell: View {
    let company: Company
    let day: Date
    let seconds: TimeInterval
    let sessions: [Session]
    @Binding var editingDay: Date?

    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @State private var hovering = false

    var body: some View {
        let color = Palette.color(company.colorIndex)
        let today = store.startOfDay(store.now)
        let isFuture = day > today
        let isToday = day == today
        let isEditing = editingDay == day
        let showsActual = hovering && seconds > 0

        Button { editingDay = day } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if seconds > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(showsActual ? TimeFormat.clock(seconds) : TimeFormat.duration(prefs.rule.apply(seconds)))
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                        if showsActual {
                            Text("actual")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                if !sessions.isEmpty {
                    SessionPills(sessions: sessions, color: color)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .background {
                // The wash sits on the panel colour, so it reads the same in light and dark.
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.panel)
                    if hovering { RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.07)) }
                }
            }
            .overlay {
                if isEditing {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 2)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.35), lineWidth: 1.5)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.live, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Future days stay clickable so time can be rolled ahead; empty ones are faded.
        .opacity(isFuture && seconds == 0 ? 0.6 : 1)
        .popover(
            isPresented: Binding(get: { editingDay == day }, set: { if !$0 { editingDay = nil } }),
            arrowEdge: .trailing
        ) {
            DayPopover(company: company, day: day)
        }
    }
}

/// A pill per session in the order they happened, each as wide as the session was long. The
/// cell's full width is a 9-hour day. Sessions under 45 minutes are lighter.
private struct SessionPills: View {
    let sessions: [Session]
    let color: Color
    @Environment(TimeStore.self) private var store

    private let fullDay: TimeInterval = 9 * 3600
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: gap) {
                ForEach(sessions) { session in
                    let length = session.duration(now: store.now)
                    Capsule()
                        .fill(color.opacity(length < 45 * 60 ? 0.55 : 1))
                        .frame(width: max(4, geo.size.width * min(1, length / fullDay) - gap))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 10)
        .clipped()
    }
}

/// A day opened from the log: its sessions on a small timeline, edited the way they are on
/// Today, its adjustments underneath, and its actual time. The billed time stays on the cell.
struct DayPopover: View {
    let company: Company
    let day: Date

    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @State private var openSession: UUID?
    @State private var editingAdjustment: UUID?
    @State private var addingAdjustment = false

    private let width: CGFloat = 400
    private let hourHeight: CGFloat = 46
    private let tallest: CGFloat = 440

    var body: some View {
        let model = TimelineModel(store: store, prefs: prefs, companyID: company.id, day: day, trimmed: true)
        let adjustments = store.adjustments(for: company.id, on: day)
        let color = Palette.color(company.colorIndex)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(TimeFormat.clock(model.total))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 10)

            if model.blocks.isEmpty {
                Text("No sessions on this day.")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            } else {
                let height = CGFloat(max(1, model.hours.count - 1)) * hourHeight
                ScrollView(.vertical) {
                    TimelineTrack(
                        model: model,
                        company: company,
                        size: CGSize(width: width - 28, height: height),
                        openSession: $openSession,
                        inlineTimes: true
                    )
                }
                .frame(height: min(height, tallest))
                .scrollDisabled(height <= tallest)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(adjustments) { adjustment in
                    if editingAdjustment == adjustment.id {
                        AdjustmentRowEditor(company: company, day: day, adjustment: adjustment) { editingAdjustment = nil }
                    } else {
                        AdjustmentChip(adjustment: adjustment, color: color)
                            .onTapGesture { editingAdjustment = adjustment.id }
                    }
                }
                if addingAdjustment {
                    AdjustmentRowEditor(company: company, day: day, adjustment: nil) { addingAdjustment = false }
                }
            }
            .padding(.leading, model.blocks.isEmpty ? 0 : 56)
            .padding(.top, adjustments.isEmpty && !addingAdjustment ? 0 : 10)

            Divider().padding(.top, 12).padding(.bottom, 10)

            HStack(spacing: 16) {
                Button("+ Add session", action: addSession)
                Button("± Adjust") { addingAdjustment = true }
                Spacer()
                if !model.blocks.isEmpty || !adjustments.isEmpty {
                    Button("Delete day") { store.deleteDay(companyID: company.id, day: day) }
                        .foregroundStyle(Theme.live)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
        }
        .padding(14)
        .frame(width: width)
    }

    /// Adds an hour after the day's last session (before its first, if that's taken) and opens
    /// its times.
    private func addSession() {
        var start = store.nextFreeStart(companyID: company.id, day: day)
        if store.problem(withTimes: start, start.addingTimeInterval(3600), for: company.id, excluding: nil) != nil,
           let first = store.sessions(for: company.id, on: day).first {
            start = first.start.addingTimeInterval(-3600)
        }
        guard store.problem(withTimes: start, start.addingTimeInterval(3600), for: company.id, excluding: nil) == nil else { return }
        let session = store.addSession(companyID: company.id, start: start, end: start.addingTimeInterval(3600))
        // Its block appears on the next update.
        DispatchQueue.main.async { openSession = session.id }
    }
}

/// An adjustment under the day's timeline: its time and why, in a dashed outline.
private struct AdjustmentChip: View {
    let adjustment: Adjustment
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(TimeFormat.signedClock(adjustment.seconds))
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(adjustment.note.isEmpty ? "Adjustment" : adjustment.note)
                .foregroundStyle(adjustment.note.isEmpty ? .secondary : .primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        )
        .contentShape(Rectangle())
        .help("Click to edit")
    }
}

/// The coloured bar at the start of a row: solid for a session, dashed for an adjustment.
private struct RowBar: View {
    let color: Color
    var dashed = false

    var body: some View {
        if dashed {
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: 2, y: 0))
                    path.addLine(to: CGPoint(x: 2, y: geo.size.height))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 4, dash: [3, 3]))
            }
            .frame(width: 4)
        } else {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
        }
    }
}

/// Saves on ⏎ and when it goes away (another row opened, or the popover closed); esc cancels.
struct SaveKeys: View {
    var save: () -> Void
    var cancel: () -> Void

    var body: some View {
        ZStack {
            Button("Save", action: save).keyboardShortcut(.defaultAction)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// Time added to or taken off the day, with a note saying why.
private struct AdjustmentRowEditor: View {
    let company: Company
    let day: Date
    let adjustment: Adjustment?
    var onClose: () -> Void

    @Environment(TimeStore.self) private var store
    @State private var adds = true
    @State private var hours = 0
    @State private var minutes = 0
    @State private var note = ""
    @State private var finished = false
    @FocusState private var minutesFocused: Bool

    private var seconds: TimeInterval {
        let total = TimeInterval(min(max(hours, 0), 24) * 3600 + min(max(minutes, 0), 59) * 60)
        return adds ? total : -total
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RowBar(color: Palette.color(company.colorIndex), dashed: true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Picker("Add or take off", selection: $adds) {
                        Text("+").tag(true)
                        Text("−").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    TextField("Hours", value: $hours, format: .number)
                        .frame(width: 36)
                        .multilineTextAlignment(.trailing)
                        .padding(.leading, 6)
                    Text("h").foregroundStyle(.secondary)
                    TextField("Minutes", value: $minutes, format: .number)
                        .frame(width: 36)
                        .multilineTextAlignment(.trailing)
                        .focused($minutesFocused)
                        .padding(.leading, 4)
                    Text("m").foregroundStyle(.secondary)
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                TextField("Note", text: $note, prompt: Text("Why? e.g. Forgot to start the timer"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack {
                    Button(adjustment == nil ? "Remove" : "Delete adjustment") {
                        finished = true
                        if let adjustment { store.deleteAdjustment(adjustment.id) }
                        onClose()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.live)
                    Spacer()
                }
                .font(.system(size: 12))
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 2)
        .background(SaveKeys(save: save, cancel: { finished = true; onClose() }))
        .onAppear {
            if let adjustment {
                adds = adjustment.seconds >= 0
                let total = Int(abs(adjustment.seconds) / 60)
                hours = total / 60
                minutes = total % 60
                note = adjustment.note
            }
            minutesFocused = true
        }
        .onDisappear { if !finished { commit() } }
    }

    private func save() {
        commit()
        onClose()
    }

    private func commit() {
        finished = true
        if let adjustment {
            store.updateAdjustment(adjustment.id, seconds: seconds, note: note)
        } else {
            store.addAdjustment(companyID: company.id, day: day, seconds: seconds, note: note)
        }
    }
}
