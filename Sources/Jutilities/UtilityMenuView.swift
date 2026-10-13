import ServiceManagement
import SwiftUI

struct UtilityMenuView: View {
    @ObservedObject var model: ClipboardViewModel
    @ObservedObject var power: PowerManager
    let isPreview: Bool
    let openClipboard: () -> Void
    let restoreBackup: () -> Void
    let openStorage: () -> Void
    let quit: () -> Void
    @State private var showsHistoryTools = false
    @State private var loginError: String?
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let loginError {
                        Text(loginError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    clipboardSection
                    separator
                    PowerMenuView(manager: power)
                    separator
                    PowerSettingsView(manager: power)
                }
                .padding(16)
            }
            separator
            footer
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .tint(JutilitiesTheme.accent)
        .preferredColorScheme(.dark)
        .background { TranslucentBackground() }
        .frame(width: JutilitiesLayout.menuSize.width, height: JutilitiesLayout.menuSize.height)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: BrandIcon.image(size: 32))
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            Text("Jutilities")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Menu {
                Toggle("Open Jutilities at login", isOn: Binding(
                    get: { launchesAtLogin }, set: setLaunchesAtLogin))
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(JutilitiesTheme.muted)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("App settings")
            .accessibilityLabel("App settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Clipboard", systemImage: "doc.on.clipboard")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Button(action: openClipboard) {
                HStack {
                    Text("Open history")
                    Spacer()
                    ShortcutKey(label: "⌥V")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background(JutilitiesTheme.selection, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("Open clipboard history (Option–V)")
            .accessibilityLabel("Open clipboard history")
            .accessibilityHint("Option–V opens clipboard history")
            HStack {
                Text("Capture clipboard")
                Spacer()
                Toggle("Capture clipboard", isOn: Binding(
                    get: { !model.isPaused },
                    set: { value in
                        model.isPaused = !value
                        model.onTogglePause(!value)
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text("Stored locally · Cleared after 60 days")
                .font(.system(size: 10))
                .foregroundStyle(JutilitiesTheme.muted)
            DisclosureGroup(isExpanded: $showsHistoryTools) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button("Export backup…") { model.onBackup() }
                            .help("Save a copy of your clipboard history")
                        Button("Restore backup…", action: restoreBackup)
                            .help("Restore clipboard history from a saved backup")
                    }
                    Button("Open history folder", action: openStorage)
                        .buttonStyle(.link)
                }
                .padding(.top, 8)
            } label: {
                Text("History & backups")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(JutilitiesTheme.muted)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let message = model.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(JutilitiesTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Jutilities 0.1.0")
                .font(.system(size: 10))
                .foregroundStyle(JutilitiesTheme.muted)
            Spacer()
            Button("Quit", action: quit)
                .buttonStyle(.plain)
                .help("Quit Jutilities")
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private var separator: some View {
        Rectangle().fill(JutilitiesTheme.separator).frame(height: 1)
    }

    private func setLaunchesAtLogin(_ value: Bool) {
        loginError = nil
        guard !isPreview else {
            loginError = "Preview mode does not change login items."
            return
        }
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchesAtLogin = SMAppService.mainApp.status == .enabled
            if value && !launchesAtLogin {
                loginError = "Allow Jutilities in System Settings → Login Items."
            }
        } catch { loginError = error.localizedDescription }
    }
}
