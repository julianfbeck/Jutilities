import SwiftUI
import JutilitiesCore

struct KeyboardSettingsView: View {
    @ObservedObject var manager: KeyboardConfigurationManager
    @State private var profileName = ""

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keyboard configurations")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Save modifier keys from one keyboard and apply them to another.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { manager.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh connected keyboards and their current modifier mappings")
                    .accessibilityLabel("Refresh keyboard configurations")
                    .disabled(manager.isApplying)
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Keyboard", selection: $manager.selectedKeyboardID) {
                    if manager.keyboards.isEmpty { Text("No physical keyboard connected").tag(Optional<UInt64>.none) }
                    ForEach(manager.keyboards) { keyboard in
                        Text(keyboard.name).tag(Optional(keyboard.id))
                    }
                }
                if let keyboard = manager.selectedKeyboard {
                    Text(keyboard.modelDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("CURRENT MODIFIER KEYS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.currentMappings, id: \.source) { mapping in
                            HStack(spacing: 12) {
                                Text(KeyboardModifierKey.label(for: mapping.source))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Text(KeyboardModifierKey.label(for: mapping.destination))
                                    .foregroundStyle(mapping.source == mapping.destination ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(mapping.source == mapping.destination ? Color.clear : Color.accentColor.opacity(0.055))
                            .accessibilityElement(children: .combine)
                        }
                        if manager.currentMappings.isEmpty {
                            Text("Select a keyboard to read its live mappings.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        }
                    }
                }
                .frame(height: manager.currentMappings.count > 9 ? 270 : 244)
                .background(JutilitiesTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(JutilitiesTheme.separator))
                HStack(spacing: 8) {
                    TextField("Configuration name", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveCurrent)
                    Button("Save current", action: saveCurrent)
                        .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.currentMappings.isEmpty || manager.isApplying)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Picker("Saved configuration", selection: $manager.selectedProfileID) {
                    Text("Choose a configuration").tag(Optional<UUID>.none)
                    ForEach(manager.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                if let profile = manager.selectedProfile {
                    Text("Saved from \(profile.sourceKeyboardName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Delete saved", role: .destructive) { manager.deleteSelectedProfile() }
                        .disabled(manager.selectedProfile == nil || manager.isApplying)
                    Spacer()
                    Button("Undo last change") { manager.revertLastChange() }
                        .disabled(!manager.canRevert || manager.isApplying)
                    Button("Apply to this keyboard") { manager.applySelectedProfile() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!manager.canApply)
                }
                Text("Apply updates macOS modifier settings for this keyboard model. Connect only one keyboard of the same model. Nothing applies automatically when a keyboard connects.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = manager.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = manager.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Fn appears when the keyboard reports support.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Keyboard settings") { manager.openSystemKeyboardSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(TranslucentBackground())
        .controlSize(.small)
    }

    private func saveCurrent() {
        guard !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        manager.saveCurrentProfile(named: profileName)
        if manager.errorMessage == nil { profileName = "" }
    }
}
