import SwiftUI
import JutilitiesCore

struct PowerMenuView: View {
    @ObservedObject var manager: PowerManager
    @Binding var durationMinutes: Int
    @Binding var display: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Keep awake", systemImage: "cup.and.saucer.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(manager.isKeepingAwake ? "Active" : "Off")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(manager.isKeepingAwake ? Color.green : JutilitiesTheme.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(manager.isKeepingAwake ? Color.green.opacity(0.10) : JutilitiesTheme.surface, in: Capsule())
            }

            HStack {
                Text("Duration")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Duration", selection: $durationMinutes) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("Indefinitely").tag(0)
                }
                .labelsHidden()
                .frame(width: 142)
            }
            .font(.system(size: 12))
            .controlSize(.small)

            HStack {
                Text("Keep display awake too")
                Spacer()
                Toggle("Keep display awake too", isOn: $display)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .font(.system(size: 12))

            HStack(spacing: 8) {
                Button {
                    manager.start(duration: durationMinutes == 0 ? nil : TimeInterval(durationMinutes * 60), display: display)
                } label: {
                    Label(manager.isKeepingAwake ? "Restart session" : "Start session", systemImage: manager.isKeepingAwake ? "arrow.clockwise" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                if manager.isKeepingAwake {
                    Button { manager.stop() } label: {
                        Text("Stop")
                            .frame(minWidth: 42, minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)

            sessionSummary
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let error = manager.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var sessionSummary: some View {
        if manager.isKeepingAwake {
            if let until = manager.until {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text(until, style: .timer).monospacedDigit()
                    Text("remaining")
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Active until you stop it or quit Jutilities.")
            }
        } else {
            Text("Temporarily prevents idle sleep. Screen saver and locking still follow macOS.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PowerSettingsView: View {
    @ObservedObject var manager: PowerManager
    private let minuteChoices = [0, 1, 2, 5, 10, 15, 30, 60, 120, 180, 240, 480, 1440]
    private let saverChoices = [0, 60, 120, 300, 600, 900, 1200, 1800, 3600, 7200]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("Saved macOS settings")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Button { manager.refreshSettings() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Refresh current macOS settings")
                .help("Read current macOS settings and discard unapplied changes")
                .disabled(manager.isApplying)
            }

            VStack(spacing: 0) {
                settingRow("Computer sleep", current: timeoutLabel(manager.currentSettings.systemSleepMinutes, seconds: false)) {
                    timeoutPicker("Computer sleep", selection: $manager.systemSleepMinutes, choices: minuteChoices, seconds: false)
                }
                settingsDivider
                settingRow("Display sleep", current: timeoutLabel(manager.currentSettings.displaySleepMinutes, seconds: false)) {
                    timeoutPicker("Display sleep", selection: $manager.displaySleepMinutes, choices: minuteChoices, seconds: false)
                }
                settingsDivider
                settingRow("Screen saver", current: timeoutLabel(manager.currentSettings.screenSaverIdleSeconds, seconds: true)) {
                    timeoutPicker("Screen saver", selection: $manager.screenSaverIdleSeconds, choices: saverChoices, seconds: true)
                        .disabled(manager.screenSaverIsManaged)
                }
                if manager.screenSaverIsManaged {
                    Label("Managed by macOS or an administrator", systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
                settingsDivider
                settingRow("Require password", current: manager.currentLockSetting?.label ?? "Not reported") {
                    Picker("Require password", selection: $manager.lockSetting) {
                        Text("Not reported by macOS").tag(Optional<PowerLockSetting>.none)
                        ForEach(lockChoices, id: \.self) { setting in
                            Text(setting.label).tag(Optional(setting))
                        }
                    }
                }
            }
            .controlSize(.small)
            .disabled(manager.isApplying)
            .background(JutilitiesTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(JutilitiesTheme.separator))

            VStack(alignment: .leading, spacing: 10) {
                Text("Sleep changes apply to all power sources and may require administrator approval. Password delay starts after screen saver or display sleep and may require your account password.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = manager.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let message = manager.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("OPEN SYSTEM SETTINGS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                settingsLink("Lock Screen", symbol: "lock.rectangle", action: manager.openLockScreenSettings)
                settingsLink("Screen Saver", symbol: "sparkles.rectangle.stack", action: manager.openScreenSaverSettings)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(JutilitiesTheme.separator)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .accessibilityHidden(true)
    }

    private func settingRow<Control: View>(_ title: String, current: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text("Current: \(current)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .labelsHidden()
                .frame(width: 148)
        }
        .padding(8)
    }

    private func settingsLink(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 17)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11))
            }
            .font(.system(size: 12))
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(title) in System Settings")
    }

    private var lockChoices: [PowerLockSetting] {
        var choices = PowerLockSetting.choices
        if let value = manager.lockSetting, !choices.contains(value) { choices.append(value) }
        return choices
    }

    private func timeoutLabel(_ value: Int?, seconds: Bool) -> String {
        guard let value else { return "Not reported" }
        if value == 0 { return "Never" }
        if seconds && value % 60 != 0 { return "After \(value) seconds" }
        let minutes = seconds ? value / 60 : value
        return minutes == 1 ? "After 1 minute" : "After \(minutes) minutes"
    }

    private func timeoutPicker(_ title: String, selection: Binding<Int?>, choices: [Int], seconds: Bool) -> some View {
        let current = selection.wrappedValue
        let values = choices + (current.map { choices.contains($0) ? [] : [$0] } ?? [])
        return Picker(title, selection: selection) {
            Text("Use existing setting").tag(Optional<Int>.none)
            ForEach(values, id: \.self) { value in
                Text(timeoutLabel(value, seconds: seconds))
                    .tag(Optional(value))
            }
        }
    }
}
