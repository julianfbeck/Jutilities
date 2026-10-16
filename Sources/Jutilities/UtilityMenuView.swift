import AppKit
import ServiceManagement
import SwiftUI

enum UtilityMenuSection: String, CaseIterable, Identifiable {
    case clipboard = "Clipboard"
    case keepAwake = "Keep awake"
    case sleepAndLock = "Sleep & lock"
    case keyboard = "Keyboard"

    var id: Self { self }
}

/// UI drafts survive switching sections and reopening the menu during this run.
@MainActor
final class UtilityMenuState: ObservableObject {
    @Published var section: UtilityMenuSection = .clipboard
    @Published var durationMinutes = 60
    @Published var display = false
}

struct UtilityMenuView: View {
    @ObservedObject var model: ClipboardViewModel
    @ObservedObject var power: PowerManager
    @ObservedObject var menuState: UtilityMenuState
    @ObservedObject var keyboard: KeyboardConfigurationManager
    let automaticPasteStatus: PastePermissionStatus
    let isPreview: Bool
    let maximumHeight: CGFloat
    let resize: (CGSize) -> Void
    let openClipboard: () -> Void
    let restoreBackup: () -> Void
    let openStorage: () -> Void
    let openKeyboard: () -> Void
    let configureAutomaticPaste: () -> Void
    let dismiss: () -> Void
    let quit: () -> Void
    @State private var loginError: String?
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var sectionHeights: [UtilityMenuSection: CGFloat] = [:]
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            navigation
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { topHeight = ceil($0) }
            sectionBody
            bottomBar
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bottomHeight = ceil($0) }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .tint(JutilitiesTheme.accent)
        .preferredColorScheme(.dark)
        .background { TranslucentBackground() }
        .background {
            ClipboardKeyboardMonitor(onKey: handleKey)
                .frame(width: 0, height: 0)
        }
        .onChange(of: power.keepDisplayAwake) { _, display in menuState.display = display }
        .frame(width: JutilitiesLayout.menuWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: resize)
    }

    private var navigation: some View {
        VStack(spacing: 0) {
            header
            UtilityMenuAction(title: "Open clipboard history", symbol: "doc.on.clipboard",
                              shortcut: "⌥V", prominent: true, action: openClipboard)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            Picker("Menu section", selection: $menuState.section) {
                ForEach(UtilityMenuSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Switch sections with ⌘1, ⌘2, ⌘3 or ⌘4")
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            separator
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sectionBody: some View {
        let section = menuState.section
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let loginError { notice(loginError, isError: true) }
                switch section {
                case .clipboard: clipboardSection
                case .keepAwake:
                    card {
                        PowerMenuView(manager: power, durationMinutes: $menuState.durationMinutes,
                                      display: $menuState.display)
                            .padding(10)
                    }
                case .sleepAndLock: PowerSettingsView(manager: power)
                case .keyboard: keyboardSection
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            // Measure the unconstrained content, not the scrolling viewport.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                sectionHeights[section] = ceil($0)
            }
        }
        .frame(height: min(sectionHeights[section] ?? 0, max(0, maximumHeight - topHeight - bottomHeight)))
        .id(section)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            separator
            if menuState.section == .sleepAndLock {
                applyBar
                separator
            }
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: BrandIcon.image(size: 32))
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Jutilities")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Menu {
                Toggle("Open Jutilities at login", isOn: Binding(
                    get: { launchesAtLogin }, set: setLaunchesAtLogin))
                Divider()
                Text("Jutilities \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")")
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(JutilitiesTheme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("App settings")
            .accessibilityLabel("App settings")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Capture clipboard")
                                .font(.system(size: 12, weight: .medium))
                            Text(model.isPaused ? "Paused until you resume" : "Save new text, links and images")
                                .font(.system(size: 11))
                                .foregroundStyle(JutilitiesTheme.muted)
                        }
                        Spacer(minLength: 8)
                        Toggle("Capture clipboard", isOn: Binding(
                            get: { !model.isPaused },
                            set: { value in
                                model.isPaused = !value
                                model.onTogglePause(!value)
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    separator
                    Label("Stored on this Mac · Cleared after 60 days", systemImage: "internaldrive")
                        .font(.system(size: 11))
                        .foregroundStyle(JutilitiesTheme.muted)
                }
                .padding(10)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("History & backups")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(JutilitiesTheme.muted)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 3)
                card {
                    VStack(spacing: 0) {
                        UtilityMenuAction(title: "Export backup…", symbol: "square.and.arrow.up", action: model.onBackup)
                        separator.padding(.leading, 42)
                        UtilityMenuAction(title: "Restore backup…", symbol: "square.and.arrow.down", action: restoreBackup)
                        separator.padding(.leading, 42)
                        UtilityMenuAction(title: "Open history folder", symbol: "folder", action: openStorage)
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 4) {
                    Label(automaticPasteStatus.allowsAutomaticPaste ? "Automatic paste ready" : "Automatic paste needs access",
                          systemImage: automaticPasteStatus.allowsAutomaticPaste ? "checkmark.shield" : "exclamationmark.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(JutilitiesTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    UtilityMenuAction(title: "Review automatic paste access…", symbol: "hand.raised",
                                      action: configureAutomaticPaste)
                }
            }

            Label("Sensitive copies are skipped when detected.", systemImage: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(JutilitiesTheme.muted)
                .help("Copies from supported password managers and clips marked private are skipped. Pause capture for unmarked passwords, including some browser extensions.")
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.errorMessage {
                notice(error, isError: true)
            } else if let message = model.statusMessage {
                notice(message)
            }
        }
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Modifier keys", systemImage: "keyboard")
                        .font(.system(size: 12, weight: .medium))
                    Text(keyboard.selectedKeyboard?.name ?? "Select a connected keyboard")
                        .font(.system(size: 12))
                    Text(keyboard.currentModifierSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(JutilitiesTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
            UtilityMenuAction(title: "Manage keyboard configurations…", symbol: "slider.horizontal.3",
                              action: openKeyboard)
            Text("Save your modifier keys, then apply a saved configuration to another connected keyboard.")
                .font(.system(size: 11))
                .foregroundStyle(JutilitiesTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if power.isKeepingAwake {
                Circle().fill(.green).frame(width: 5, height: 5).accessibilityHidden(true)
                Text("Keeping Mac awake")
            } else {
                Text("⌘1–4 switch sections")
            }
            Spacer()
            Button("Quit", action: quit)
                .buttonStyle(.borderless)
                .help("Quit Jutilities")
                .accessibilityLabel("Quit Jutilities")
        }
        .font(.system(size: 11))
        .foregroundStyle(JutilitiesTheme.muted)
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private var applyBar: some View {
        HStack(spacing: 8) {
            if power.isApplying { ProgressView().controlSize(.small) }
            Text(power.isApplying ? "Applying…" : power.hasPendingChanges ? "Unapplied changes" : "No pending changes")
                .font(.system(size: 11))
                .foregroundStyle(JutilitiesTheme.muted)
            Spacer(minLength: 0)
            Button("Apply changes") { power.applySettings() }
                .buttonStyle(.borderedProminent)
                .disabled(!power.hasPendingChanges || power.isApplying)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.055)))
    }

    private func notice(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(isError ? Color.orange : JutilitiesTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var separator: some View {
        Rectangle().fill(JutilitiesTheme.separator).frame(height: 1)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if modifiers.isEmpty, event.keyCode == 53 { dismiss(); return true }
        guard modifiers == .command else { return false }
        let sections: [String: UtilityMenuSection] = ["1": .clipboard, "2": .keepAwake, "3": .sleepAndLock, "4": .keyboard]
        guard let key = event.charactersIgnoringModifiers, let section = sections[key] else { return false }
        menuState.section = section
        return true
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

private struct UtilityMenuAction: View {
    let title: String
    let symbol: String
    var shortcut: String? = nil
    var prominent = false
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(JutilitiesTheme.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: prominent ? .medium : .regular))
                Spacer(minLength: 4)
                if let shortcut { ShortcutKey(label: shortcut) }
                else {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(JutilitiesTheme.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: prominent ? 40 : 36)
            .contentShape(Rectangle())
            .background(.white.opacity(isHovered ? 0.08 : prominent ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: prominent ? 9 : 7))
            .overlay(RoundedRectangle(cornerRadius: prominent ? 9 : 7)
                .strokeBorder(JutilitiesTheme.accent.opacity(isFocused ? 0.65 : 0)))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
    }
}
