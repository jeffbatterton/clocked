import SwiftUI

/// The selected company's month as a calendar. Each day shows its rounded time and is shaded
/// deeper the longer you worked. Click a day to edit it (or add time to an empty one); the
/// + button adds time to any day without running the timer, including future days, so time
/// over a monthly cap can be rolled ahead.
struct LogView: View {
    let company: Company
    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs

    @State private var month = Date()
    @State private var editingDay: Date?
    @State private var adding = false

    var body: some View {
        let calendar = prefs.calendar
        let monthInterval = calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, duration: 0)
        let isCurrentMonth = calendar.isDate(month, equalTo: store.now, toGranularity: .month)

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
                Button { adding = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .help("Add time without running the timer")
                    .padding(.leading, 6)
                    .popover(isPresented: $adding, arrowEdge: .bottom) {
                        EntryEditor(company: company, mode: .add(isCurrentMonth ? store.now : monthInterval.start)) { adding = false }
                    }
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
        let runningDay = store.running.flatMap { $0.companyID == company.id ? store.startOfDay($0.start) : nil }

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
                                isRunning: key == runningDay,
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

private struct DayCell: View {
    let company: Company
    let day: Date
    let seconds: TimeInterval
    let isRunning: Bool
    @Binding var editingDay: Date?

    @Environment(TimeStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        let today = store.startOfDay(store.now)
        let isFuture = day > today
        let isToday = day == today
        let rounded = prefs.rule.apply(seconds)
        let isEditing = editingDay == day
        // Deeper colour for longer days, topping out at 8 hours.
        let shade = seconds > 0 ? 0.08 + 0.32 * min(1, rounded / (8 * 3600)) : 0

        Button { editingDay = day } label: {
            VStack(alignment: .leading) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if seconds > 0 {
                    Text(TimeFormat.duration(rounded))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .background {
                // The tint sits on the panel colour, so it reads the same in light and dark.
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.panel)
                    RoundedRectangle(cornerRadius: 8).fill(Palette.color(company.colorIndex).opacity(shade))
                }
            }
            .overlay {
                if isEditing {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.live, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Future days stay clickable so time can be rolled ahead; empty ones are faded.
        .opacity(isFuture && seconds == 0 ? 0.6 : 1)
        .help(seconds > 0 ? "\(TimeFormat.rowDay(day)) · \(TimeFormat.duration(rounded))" : TimeFormat.rowDay(day))
        .popover(
            isPresented: Binding(get: { editingDay == day }, set: { if !$0 { editingDay = nil } }),
            arrowEdge: .trailing
        ) {
            EntryEditor(
                company: company,
                mode: seconds > 0 ? .edit(LoggedDay(day: day, seconds: seconds, isRunning: isRunning)) : .add(day)
            ) { editingDay = nil }
        }
    }
}

/// Add time to a day, or edit a day's date and time (or delete it).
struct EntryEditor: View {
    enum Mode {
        case add(Date)
        case edit(LoggedDay)
    }

    let company: Company
    let mode: Mode
    var onDone: () -> Void

    @Environment(TimeStore.self) private var store
    @State private var date: Date
    @State private var hours: Int
    @State private var minutes: Int

    init(company: Company, mode: Mode, onDone: @escaping () -> Void) {
        self.company = company
        self.mode = mode
        self.onDone = onDone
        switch mode {
        case .add(let day):
            _date = State(initialValue: day)
            _hours = State(initialValue: 1)
            _minutes = State(initialValue: 0)
        case .edit(let entry):
            let total = Int(entry.seconds / 60)
            _date = State(initialValue: entry.day)
            _hours = State(initialValue: total / 60)
            _minutes = State(initialValue: total % 60)
        }
    }

    private var editing: LoggedDay? {
        if case .edit(let entry) = mode { return entry }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(editing == nil ? "Add time" : "Edit entry") · \(company.name)")
                .font(.system(size: 13, weight: .semibold))

            if editing?.isRunning == true {
                Text("Stop the timer to edit this day.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("OK", action: onDone).keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Date").foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                    HStack(spacing: 10) {
                        Text("Time").foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                        HStack(spacing: 5) {
                            TextField("Hours", value: $hours, format: .number)
                                .frame(width: 44)
                                .multilineTextAlignment(.trailing)
                            Text("h").foregroundStyle(.secondary).fixedSize()
                            TextField("Minutes", value: $minutes, format: .number)
                                .frame(width: 44)
                                .multilineTextAlignment(.trailing)
                                .padding(.leading, 6)
                            Text("m").foregroundStyle(.secondary).fixedSize()
                        }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    }
                }
                HStack(spacing: 8) {
                    if let editing {
                        Button("Delete", role: .destructive) {
                            store.deleteDay(companyID: company.id, day: editing.day)
                            onDone()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.live)
                    }
                    Spacer()
                    Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                    Button(editing == nil ? "Add" : "Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(seconds == 0 && editing == nil)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private var seconds: TimeInterval {
        TimeInterval(min(max(hours, 0), 24) * 3600 + min(max(minutes, 0), 59) * 60)
    }

    private func save() {
        if let editing {
            store.editDay(companyID: company.id, day: editing.day, newDay: date, seconds: seconds)
        } else {
            store.addEntry(companyID: company.id, day: date, seconds: seconds)
        }
        onDone()
    }
}
