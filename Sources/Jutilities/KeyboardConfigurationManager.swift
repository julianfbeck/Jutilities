import AppKit
import Combine
import CoreFoundation
import Foundation
import JutilitiesCore

@MainActor
final class KeyboardConfigurationManager: ObservableObject {
    let isPreview: Bool
    @Published private(set) var keyboards: [KeyboardDevice] = []
    @Published var selectedKeyboardID: UInt64? { didSet { if oldValue != selectedKeyboardID { refreshSelectedKeyboard() } } }
    @Published private(set) var currentMappings: [KeyboardKeyMapping] = []
    @Published private(set) var profiles: [KeyboardModifierProfile] = []
    @Published var selectedProfileID: UUID?
    @Published private(set) var errorMessage: String?
    @Published private(set) var message: String?
    @Published private(set) var isApplying = false
    @Published private(set) var canRevert = false

    private var currentState: KeyboardModifierState?
    private var backup: KeyboardModifierBackup?
    private var profileLoadFailed = false
    private var backupLoadFailed = false
    private let directory: URL

    var selectedKeyboard: KeyboardDevice? { keyboards.first { $0.id == selectedKeyboardID } }
    var selectedProfile: KeyboardModifierProfile? { profiles.first { $0.id == selectedProfileID } }
    var currentModifierSummary: String {
        let changed = currentMappings.filter { $0.source != $0.destination }
        guard currentState != nil else { return "Choose a connected keyboard" }
        return changed.isEmpty ? "Standard modifier keys" : "\(changed.count) modifier \(changed.count == 1 ? "remapping" : "remappings")"
    }
    var canApply: Bool { !isApplying && !backupLoadFailed && selectedKeyboard != nil && currentState != nil && selectedProfile != nil && !isAmbiguous }
    var isAmbiguous: Bool {
        guard let device = selectedKeyboard else { return false }
        return keyboards.filter { $0.hasSameModel(as: device) }.count != 1
    }

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jutilities/Keyboard", isDirectory: true)
        if isPreview {
            let device = KeyboardDevice(id: 1, vendorID: 1452, productID: 1, locationID: 1, name: "Example Keyboard", transport: "USB")
            keyboards = [device]
            selectedKeyboardID = device.id
            currentState = try? .init(nativeMappings: [.init(source: 0x700000039, destination: 0x700000029)], userMappings: [])
            currentMappings = currentState?.capturedModifiers(includeFunction: true) ?? []
            if let profile = try? KeyboardModifierProfile(name: "My keyboard", sourceKeyboardName: device.name, mappings: currentMappings) {
                profiles = [profile]
                selectedProfileID = profile.id
            }
        } else {
            loadSavedConfigurations()
            refresh()
        }
    }

    func refresh() {
        guard !isApplying, !isPreview else { return }
        do {
            let previous = selectedKeyboardID
            keyboards = try connectedKeyboards()
            selectedKeyboardID = keyboards.contains(where: { $0.id == previous }) ? previous : keyboards.first?.id
            refreshSelectedKeyboard()
            if keyboards.isEmpty { message = "Connect a physical keyboard, then refresh." }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveCurrentProfile(named name: String) {
        guard let device = selectedKeyboard, currentState != nil, !isApplying else { return }
        do {
            guard !profileLoadFailed else { throw KeyboardOperationError.profileStorage }
            if !isPreview { try refreshLiveState(device) }
            let profile = try KeyboardModifierProfile(name: name, sourceKeyboardName: device.name, mappings: currentMappings)
            let updated = profiles + [profile]
            let archive = KeyboardModifierProfileArchive(profiles: updated)
            try archive.validate()
            if !isPreview { try store(archive, name: "profiles.json") }
            profiles = updated
            selectedProfileID = profile.id
            errorMessage = nil
            message = "Saved \(profile.name). Select another keyboard and choose Apply to use it."
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteSelectedProfile() {
        guard let profile = selectedProfile, !isApplying else { return }
        do {
            guard !profileLoadFailed else { throw KeyboardOperationError.profileStorage }
            let updated = profiles.filter { $0.id != profile.id }
            if !isPreview { try store(KeyboardModifierProfileArchive(profiles: updated), name: "profiles.json") }
            profiles = updated
            selectedProfileID = profiles.first?.id
            errorMessage = nil
            message = "Saved configuration removed."
        } catch { errorMessage = error.localizedDescription }
    }

    func applySelectedProfile() {
        guard let device = selectedKeyboard, let profile = selectedProfile, !isApplying else { return }
        guard !isPreview else { message = "Preview only. No keyboard settings were changed."; return }
        isApplying = true
        defer { isApplying = false }
        do {
            guard !backupLoadFailed else { throw KeyboardOperationError.backupStorage }
            try requireUniqueConnectedDevice(device)
            let before = try liveState(device)
            let plan = try KeyboardModifierPlan(profile: profile, current: before, supportsFunction: supportsFunction(device, state: before))
            let preferences = try readPreference(device)
            try KeyboardModifierPlan.validateUnrelatedPreferenceMappings(current: before, persisted: preferences)
            let change = try KeyboardModifierBackup(device: device, originalNative: before.nativeMappings,
                                                originalUser: before.userMappings, originalPreference: preferences,
                                                appliedNative: plan.nativeMappings)
            // Persist the undo record before the first system mutation.
            try store(change, name: "last-change.json")
            backup = change
            canRevert = true
            do {
                try setLiveMappings(plan.nativeMappings, device: device)
                try verifyState(device, native: plan.nativeMappings, user: before.userMappings)
                try writePreference(plan.nativeMappings, device: device)
            } catch {
                let originalError = error
                do {
                    try restore(change)
                    try removeBackup()
                } catch { throw KeyboardOperationError.rollback }
                throw originalError
            }
            try refreshLiveState(device)
            errorMessage = profileLoadFailed ? KeyboardOperationError.profileStorage.localizedDescription : nil
            message = "Applied \(profile.name) to \(device.name). The previous settings are backed up; use Undo last change to restore them."
        } catch { errorMessage = error.localizedDescription; message = nil }
    }

    func revertLastChange() {
        guard let change = backup, !isApplying, !isPreview else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            let device = try recoveryDevice(change.device)
            try restore(change, device: device)
            try removeBackup()
            keyboards = try connectedKeyboards()
            selectedKeyboardID = device.id
            try refreshLiveState(device)
            errorMessage = nil
            message = "Previous modifier settings restored."
        } catch { errorMessage = error.localizedDescription; message = nil }
    }

    func openSystemKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshSelectedKeyboard() {
        guard !isPreview else { return }
        currentState = nil
        currentMappings = []
        guard let device = selectedKeyboard else { return }
        do {
            try refreshLiveState(device)
            errorMessage = backupLoadFailed ? KeyboardOperationError.backupStorage.localizedDescription
                : (profileLoadFailed ? KeyboardOperationError.profileStorage.localizedDescription : nil)
            message = isAmbiguous ? "Two connected keyboards share this model. Disconnect one before applying; macOS shares their saved modifier preferences." : nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshLiveState(_ device: KeyboardDevice) throws {
        let state = try liveState(device)
        currentState = state
        currentMappings = state.capturedModifiers(includeFunction: supportsFunction(device, state: state))
    }

    private func supportsFunction(_ device: KeyboardDevice, state: KeyboardModifierState) -> Bool {
        device.vendorID == 1452 || (state.nativeMappings + state.userMappings).contains {
            $0.source == KeyboardModifierKey.functionUsage || $0.destination == KeyboardModifierKey.functionUsage
        }
    }

    private func connectedKeyboards() throws -> [KeyboardDevice] {
        try KeyboardConfigurationParser.devices(ndjson: KeyboardCommands.read(["list", "--ndjson", "--matching", "keyboard"]))
    }

    private func liveState(_ device: KeyboardDevice) throws -> KeyboardModifierState {
        // The filter's live maps reflect native Modifier Keys settings. A direct
        // hidutil property --get can incorrectly report null for these settings.
        // Parse the dump in memory and keep only the requested key mappings.
        try KeyboardConfigurationParser.state(plist: KeyboardCommands.read(["dump", "services", "-f", "xml"]), registryID: device.id)
    }

    private func requireUniqueConnectedDevice(_ device: KeyboardDevice) throws {
        let attached = try connectedKeyboards()
        guard attached.contains(device) else { throw KeyboardOperationError.disconnected }
        guard attached.filter({ $0.hasSameModel(as: device) }).count == 1 else { throw KeyboardOperationError.ambiguous }
    }

    private func setLiveMappings(_ mappings: [KeyboardKeyMapping], device: KeyboardDevice) throws {
        try requireUniqueConnectedDevice(device)
        let matching = try JSONSerialization.data(withJSONObject: device.matchingDictionary, options: [.sortedKeys])
        let property = try JSONSerialization.data(withJSONObject: ["HIDKeyboardModifierMappingPairs": mappings.map(\.propertyDictionary)], options: [.sortedKeys])
        _ = try KeyboardCommands.read(["property", "--matching", String(decoding: matching, as: UTF8.self),
                                       "--set", String(decoding: property, as: UTF8.self)])
    }

    private func verifyState(_ device: KeyboardDevice, native: [KeyboardKeyMapping], user: [KeyboardKeyMapping]) throws {
        let state = try liveState(device)
        guard Set(state.nativeMappings) == Set(native), Set(state.userMappings) == Set(user) else {
            throw KeyboardOperationError.verification
        }
    }

    private func readPreference(_ device: KeyboardDevice) throws -> [KeyboardKeyMapping]? {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard let value = CFPreferencesCopyValue(device.preferenceKey as CFString, kCFPreferencesAnyApplication,
                                                kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else { return nil }
        return try KeyboardConfigurationParser.mappings(value)
    }

    private func writePreference(_ mappings: [KeyboardKeyMapping]?, device: KeyboardDevice) throws {
        let value: CFArray? = mappings.map { $0.map(\.propertyDictionary) as CFArray }
        CFPreferencesSetValue(device.preferenceKey as CFString, value,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost),
              try readPreference(device) == mappings else { throw KeyboardOperationError.preference }
    }

    private func recoveryDevice(_ previous: KeyboardDevice) throws -> KeyboardDevice {
        let devices = try connectedKeyboards()
        let sameModel = devices.filter { $0.hasSameModel(as: previous) }
        guard sameModel.count == 1 else { throw sameModel.isEmpty ? KeyboardOperationError.disconnected : KeyboardOperationError.ambiguous }
        let current = sameModel[0]
        guard current.locationID == previous.locationID, current.transport == previous.transport else {
            throw KeyboardOperationError.disconnected
        }
        return current
    }

    private func restore(_ change: KeyboardModifierBackup, device: KeyboardDevice? = nil) throws {
        let device = try device ?? recoveryDevice(change.device)
        try requireUniqueConnectedDevice(device)
        let recovery = try KeyboardModifierRecoveryPlan(backup: change, current: liveState(device), currentPreference: readPreference(device))
        try setLiveMappings(recovery.nativeMappings, device: device)
        try verifyState(device, native: recovery.nativeMappings, user: change.originalUser)
        try writePreference(recovery.preferenceMappings, device: device)
    }

    private func loadSavedConfigurations() {
        let profileURL = directory.appendingPathComponent("profiles.json")
        if FileManager.default.fileExists(atPath: profileURL.path) {
            do {
                let archive = try JSONDecoder().decode(KeyboardModifierProfileArchive.self, from: Data(contentsOf: profileURL))
                try archive.validate()
                profiles = archive.profiles
                selectedProfileID = profiles.first?.id
            } catch { profileLoadFailed = true; errorMessage = KeyboardOperationError.profileStorage.localizedDescription }
        }
        let backupURL = directory.appendingPathComponent("last-change.json")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            do {
                backup = try JSONDecoder().decode(KeyboardModifierBackup.self, from: Data(contentsOf: backupURL))
                canRevert = true
            } catch { backupLoadFailed = true; errorMessage = KeyboardOperationError.backupStorage.localizedDescription }
        }
    }

    private func store<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeBackup() throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("last-change.json"))
        backup = nil
        canRevert = false
    }
}

private enum KeyboardOperationError: LocalizedError {
    case process, disconnected, ambiguous, verification, preference, rollback, profileStorage, backupStorage
    var errorDescription: String? {
        switch self {
        case .process: "macOS could not complete the keyboard operation. Open Keyboard settings to check the selected keyboard."
        case .disconnected: "This keyboard disconnected or changed. Refresh and select it again."
        case .ambiguous: "Two connected keyboards have the same vendor and product. Disconnect one before applying to avoid changing both."
        case .verification: "macOS did not confirm the modifier change. The previous settings will be restored when possible."
        case .preference: "macOS could not save the modifier preference."
        case .rollback: "The change could not be verified and automatic restoration failed. The backup is preserved. Check Modifier Keys in System Settings before continuing."
        case .profileStorage: "Saved keyboard configurations could not be read safely. The existing file has been preserved."
        case .backupStorage: "The saved keyboard recovery record could not be read safely. It has been preserved; new changes are blocked."
        }
    }
}

private enum KeyboardCommands {
    static func read(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0, data.count < 8_000_000 else { throw KeyboardOperationError.process }
        return data
    }
}
