import SwiftUI
import JutilitiesCore

struct PowerMenuView: View {
    @ObservedObject var manager: PowerManager
    @State private var durationMinutes = 60
    @State private var display = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Keep awake", systemImage: "cup.and.saucer.fill")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(manager.isKeepingAwake ? "On" : "Off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(manager.isKeepingAwake ? .green : .secondary)
            }
            if manager.isKeepingAwake {
                if let until = manager.until {
                    HStack {
                        Text("Remaining")
                        Spacer()
                        Text(until, style: .timer).monospacedDigit()
                    }
                    .font(.caption)
                } else {
                    Text("Until you stop it or quit Jutilities")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("For", selection: $durationMinutes) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
                Text("Indefinitely").tag(0)
            }
            .controlSize(.small)
            Toggle("Keep display awake too", isOn: $display)
                .toggleStyle(.switch)
                .controlSize(.small)
            HStack {
                Button(manager.isKeepingAwake ? "Restart session" : "Start") {
                    manager.start(duration: durationMinutes == 0 ? nil : TimeInterval(durationMinutes * 60), display: display)
                }
                .buttonStyle(.borderedProminent)
                if manager.isKeepingAwake {
                    Button("Stop") { manager.stop() }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            Text("Screen saver and locking still follow macOS. Manual sleep stays available.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { display = manager.keepDisplayAwake }
    }
}

struct PowerSettingsView: View {
    @ObservedObject var manager: PowerManager
    @State private var showsSleepSettings = false
    private let minuteChoices = [0, 1, 2, 5, 10, 15, 30, 60, 120, 180, 240, 480, 1440]
    private let saverChoices = [0, 60, 120, 300, 600, 900, 1200, 1800, 3600, 7200]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PowerMenuView(manager: manager)
            Divider().overlay(JutilitiesTheme.separator)
            DisclosureGroup(isExpanded: $showsSleepSettings) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Saved macOS settings")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { manager.refreshSettings() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Read current macOS settings")
                        .disabled(manager.isApplying)
                    }
                    .font(.caption)
                    VStack(spacing: 9) {
                        timeoutPicker("Computer sleep", selection: $manager.systemSleepMinutes, choices: minuteChoices, seconds: false)
                        timeoutPicker("Display sleep", selection: $manager.displaySleepMinutes, choices: minuteChoices, seconds: false)
                        timeoutPicker("Screen saver", selection: $manager.screenSaverIdleSeconds, choices: saverChoices, seconds: true)
                            .disabled(manager.screenSaverIsManaged)
                        Picker("Require password", selection: $manager.lockSetting) {
                            Text("Not reported by macOS").tag(Optional<PowerLockSetting>.none)
                            ForEach(lockChoices, id: \.self) { setting in
                                Text(setting.label).tag(Optional(setting))
                            }
                        }
                    }
                    .controlSize(.small)
                    .disabled(manager.isApplying)
                    Text("Sleep changes apply to all power sources and may ask for administrator approval. Password delay applies after screen saver or display sleep and may ask for your account password.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Apply changes") { manager.applySettings() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!manager.hasPendingChanges || manager.isApplying)
                        if manager.isApplying { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    HStack {
                        Button("Lock Screen settings…") { manager.openLockScreenSettings() }
                        Spacer()
                        Button("Screen Saver…") { manager.openScreenSaverSettings() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(.top, 10)
            } label: {
                Label("Sleep & lock settings", systemImage: "moon.zzz")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            if let error = manager.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let message = manager.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lockChoices: [PowerLockSetting] {
        var choices = PowerLockSetting.choices
        if let value = manager.lockSetting, !choices.contains(value) { choices.append(value) }
        return choices
    }

    @ViewBuilder
    private func timeoutPicker(_ title: String, selection: Binding<Int?>, choices: [Int], seconds: Bool) -> some View {
        let current = selection.wrappedValue
        let values = choices + (current.map { choices.contains($0) ? [] : [$0] } ?? [])
        Picker(title, selection: selection) {
            Text("Use existing setting").tag(Optional<Int>.none)
            ForEach(values, id: \.self) { value in
                Text(value == 0 ? "Never" : "After \(seconds ? value / 60 : value) minutes")
                    .tag(Optional(value))
            }
        }
    }
}
