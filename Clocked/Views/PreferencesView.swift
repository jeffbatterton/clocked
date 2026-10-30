import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(TimeStore.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var prefs = prefs

        Form {
            Section {
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle(isOn: $prefs.roundingEnabled) {
                    Text("Round time")
                    Text("Each day's total per company is rounded")
                }
                Picker("Round to", selection: $prefs.roundingUnitMinutes) {
                    ForEach(Preferences.unitChoices, id: \.self) { Text(TimeFormat.unitName($0)).tag($0) }
                }
                .disabled(!prefs.roundingEnabled)
                Picker(selection: $prefs.roundUpAfterMinutes) {
                    ForEach(prefs.roundUpChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Any time" : TimeFormat.unitName(minutes)).tag(minutes)
                    }
                } label: {
                    Text("Round up after")
                    Text(examples)
                }
                .disabled(!prefs.roundingEnabled)
            }

            Section {
                Picker(selection: $prefs.timelineStartHour) {
                    ForEach(0..<24, id: \.self) { Text(TimeFormat.hourOfDay($0)).tag($0) }
                } label: {
                    Text("Timeline starts")
                    Text("The Today timeline runs between these times")
                }
                Picker(selection: $prefs.timelineEndHour) {
                    ForEach((prefs.timelineStartHour + 1)...24, id: \.self) { Text(TimeFormat.hourOfDay($0)).tag($0) }
                } label: {
                    Text("Timeline ends")
                    Text("Extends automatically if a timer runs later")
                }
            }

            Section {
                Picker("Week starts on", selection: $prefs.firstWeekday) {
                    Text("Sunday").tag(1)
                    Text("Monday").tag(2)
                }
                Toggle(isOn: $prefs.showMenuBarItem) {
                    Text("Show in menu bar")
                    Text("Today's time and a Start/Stop button. Preferences is always in the Clocked menu (⌘,).")
                }
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            }

            Section {
                Toggle(isOn: Binding(get: { prefs.reminderEnabled }, set: { on in
                    prefs.reminderEnabled = on
                    if on { Reminder.requestPermission() }
                })) {
                    Text("Remind me when no timer is running")
                    Text("Once a day, a little while after your Mac first wakes up")
                }
                Picker("Remind after", selection: $prefs.reminderMinutes) {
                    ForEach(Preferences.reminderChoices, id: \.self) { Text(TimeFormat.unitName($0)).tag($0) }
                }
                .disabled(!prefs.reminderEnabled)
            }

            Section {
                Toggle(isOn: Binding(get: { prefs.testDrive }, set: { on in
                    prefs.testDrive = on
                    store.setTestDrive(on)
                })) {
                    Text("Test drive")
                    Text("Fills Clocked with sample companies and time to try it out. Your own data is set aside, untouched, and comes back when you turn this off.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .alert(
            "Couldn't change Launch at login",
            isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginError ?? "")
        }
    }

    /// e.g. "2h 16m → 3h · 2h 15m → 2h · 20m → 1h" for 1 hour, round up after 15 minutes.
    private var examples: String {
        let rule = RoundingRule(enabled: true, unitMinutes: prefs.roundingUnitMinutes, roundUpAfterMinutes: prefs.roundUpAfterMinutes)
        let unit = prefs.roundingUnitMinutes, threshold = prefs.roundUpAfterMinutes
        var samples = [2 * unit + threshold + 1, 2 * unit + threshold]
        let small = threshold + (threshold + 5 < unit ? 5 : 1)
        if small < unit { samples.append(small) }
        return samples
            .map { "\(TimeFormat.duration(TimeInterval($0 * 60))) → \(TimeFormat.duration(rule.apply(TimeInterval($0 * 60))))" }
            .joined(separator: " · ")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            loginError = error.localizedDescription
        }
    }
}
