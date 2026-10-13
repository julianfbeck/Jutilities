import AppKit
import Combine
import CoreFoundation
import Foundation
import IOKit.pwr_mgt
import JutilitiesCore

private final class PowerAssertionLease {
    let identifiers: [IOPMAssertionID]
    init(_ identifiers: [IOPMAssertionID]) { self.identifiers = identifiers }
    deinit { identifiers.forEach { IOPMAssertionRelease($0) } }
}

@MainActor
final class PowerManager: ObservableObject {
    let isPreview: Bool
    @Published private(set) var isKeepingAwake = false
    @Published private(set) var keepDisplayAwake = false
    @Published private(set) var until: Date?
    @Published var message: String?
    @Published var errorMessage: String?
    @Published private(set) var isApplying = false
    @Published var systemSleepMinutes: Int?
    @Published var displaySleepMinutes: Int?
    @Published var screenSaverIdleSeconds: Int?
    @Published var lockSetting: PowerLockSetting?
    @Published private(set) var screenSaverIsManaged = false
    @Published private(set) var currentSettings = PowerSettingsSnapshot()
    @Published private(set) var currentLockSetting: PowerLockSetting?

    private var assertions: PowerAssertionLease?
    private var expiryTask: Task<Void, Never>?
    private var sessionID = UUID()
    private let screenSaverDomain = "com.apple.screensaver" as CFString

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
        refreshSettings()
    }

    var hasPendingChanges: Bool {
        guard let plan = try? makeSettingsPlan() else { return true }
        return plan.hasChanges || (lockSetting != nil && lockSetting != currentLockSetting)
    }

    func start(duration: TimeInterval?, display: Bool) {
        do {
            let plan = try PowerSessionPlan(duration: duration, display: display)
            // Create the replacement before releasing an existing session. A failed
            // replacement therefore leaves the previous protection in place.
            var ids: [IOPMAssertionID] = []
            for type in isPreview ? [] : [kIOPMAssertionTypePreventUserIdleSystemSleep] + (display ? [kIOPMAssertionTypePreventUserIdleDisplaySleep] : []) {
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Jutilities keep awake" as CFString, &id)
                guard result == kIOReturnSuccess else {
                    ids.forEach { IOPMAssertionRelease($0) }
                    throw PowerOperationError.assertion(result)
                }
                ids.append(id)
            }
            expiryTask?.cancel()
            assertions = PowerAssertionLease(ids)
            isKeepingAwake = true
            keepDisplayAwake = display
            until = plan.endDate(from: Date())
            errorMessage = nil
            message = display ? "Computer and display are kept awake." : "Computer is kept awake; display follows macOS settings."
            let id = UUID()
            sessionID = id
            if let duration = plan.duration {
                expiryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                    guard let self, self.sessionID == id else { return }
                    self.stop()
                    self.message = "Keep-awake session finished."
                }
            } else {
                expiryTask = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        sessionID = UUID()
        assertions = nil
        isKeepingAwake = false
        keepDisplayAwake = false
        until = nil
        message = "Keep awake stopped. Your macOS settings remain in effect."
    }

    func shutdown() { stop() }

    func refreshSettings() {
        guard !isApplying else { return }
        if isPreview {
            currentSettings = .init(systemSleepMinutes: 0, displaySleepMinutes: 0, screenSaverIdleSeconds: 0)
            systemSleepMinutes = 0
            displaySleepMinutes = 0
            screenSaverIdleSeconds = 0
            currentLockSetting = .after(seconds: 300)
            lockSetting = currentLockSetting
            return
        }
        do {
            var snapshot = PowerSettingsSnapshot.parsePMSet(try PowerCommands.read(executable: "/usr/bin/pmset", arguments: ["-g"]))
            snapshot.screenSaverIdleSeconds = readScreenSaverIdle()
            currentSettings = snapshot
            systemSleepMinutes = snapshot.systemSleepMinutes
            displaySleepMinutes = snapshot.displaySleepMinutes
            screenSaverIdleSeconds = snapshot.screenSaverIdleSeconds
            screenSaverIsManaged = CFPreferencesAppValueIsForced("idleTime" as CFString, screenSaverDomain)
            currentLockSetting = readLockSetting()
            lockSetting = currentLockSetting
            errorMessage = nil
        } catch {
            errorMessage = "Could not read current power settings. \(error.localizedDescription)"
        }
    }

    func applySettings() {
        guard !isApplying else { return }
        do {
            let plan = try makeSettingsPlan()
            let lockChange = lockSetting != nil && lockSetting != currentLockSetting ? lockSetting : nil
            guard plan.hasChanges || lockChange != nil else {
                message = "Settings are already up to date."
                return
            }
            guard !screenSaverIsManaged || plan.screenSaverIdleSeconds == nil else {
                throw PowerOperationError.managedScreenSaver
            }
            if isPreview {
                message = "Preview only. No macOS settings were changed."
                return
            }
            var password: PowerPassword?
            if lockChange != nil {
                guard let entered = requestLockPassword() else { return }
                password = entered
            }
            // macOS owns the authorization dialog. No administrator credential
            // is received or saved by Jutilities.
            if let command = plan.privilegedCommand {
                try executeAuthorizedPMSet(command)
            }
            if let seconds = plan.screenSaverIdleSeconds {
                try writeScreenSaverIdle(seconds)
            }
            errorMessage = nil
            if let lockChange, let password {
                isApplying = true
                Task { [weak self] in
                    let succeeded = await Task.detached {
                        PowerCommands.setLockSetting(lockChange, password: password)
                    }.value
                    guard let self else { return }
                    self.isApplying = false
                    self.refreshSettings()
                    if succeeded && self.currentLockSetting == lockChange {
                        self.message = "Settings applied. macOS reports \(lockChange.label.lowercased()) for the password delay."
                    } else {
                        self.errorMessage = "macOS could not verify the password-delay change. Open Lock Screen settings to check it; other selected settings may already be applied."
                    }
                }
            } else {
                refreshSettings()
                message = "Settings applied. Screen saver and locking continue to follow macOS settings."
            }
        } catch {
            errorMessage = error.localizedDescription
            message = nil
        }
    }

    func openLockScreenSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func openScreenSaverSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func makeSettingsPlan() throws -> PowerSettingsPlan {
        try PowerSettingsPlan(current: currentSettings, draft: .init(systemSleepMinutes: systemSleepMinutes, displaySleepMinutes: displaySleepMinutes, screenSaverIdleSeconds: screenSaverIdleSeconds))
    }

    private func readScreenSaverIdle() -> Int? {
        CFPreferencesSynchronize(screenSaverDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let value = CFPreferencesCopyValue("idleTime" as CFString, screenSaverDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            ?? CFPreferencesCopyValue("idleTime" as CFString, screenSaverDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? NSNumber)?.intValue
    }

    private func writeScreenSaverIdle(_ seconds: Int) throws {
        CFPreferencesSetValue("idleTime" as CFString, NSNumber(value: seconds), screenSaverDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard CFPreferencesSynchronize(screenSaverDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost), readScreenSaverIdle() == seconds else {
            throw PowerOperationError.screenSaverWrite
        }
    }

    private func readLockSetting() -> PowerLockSetting? {
        guard let output = try? PowerCommands.read(executable: "/usr/sbin/sysadminctl", arguments: ["-screenLock", "status"]) else { return nil }
        return PowerLockSetting.parseStatus(output)
    }

    private func requestLockPassword() -> PowerPassword? {
        let alert = NSAlert()
        alert.messageText = "Change password delay"
        alert.informativeText = "macOS requires the password for your current account to change when it locks. Jutilities sends it only to Apple's sysadminctl password prompt and does not save it."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        field.placeholderString = "Current Mac account password"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        defer { field.stringValue = "" }
        guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return PowerPassword(Data(field.stringValue.utf8))
    }

    private func executeAuthorizedPMSet(_ command: String) throws {
        // command is generated exclusively from validated PowerSettingsPlan tokens.
        let source = "do shell script \"\(command)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { throw PowerOperationError.authorization }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            throw code == -128 ? PowerOperationError.cancelled : PowerOperationError.authorization
        }
    }
}

private enum PowerOperationError: LocalizedError {
    case assertion(IOReturn), authorization, cancelled, managedScreenSaver, screenSaverWrite, process
    var errorDescription: String? {
        switch self {
        case .assertion(let code): "macOS could not start keep awake (\(code))."
        case .authorization: "macOS did not authorize the power-setting change."
        case .cancelled: "Power-setting change cancelled."
        case .managedScreenSaver: "Your screen saver settings are managed by macOS or an administrator."
        case .screenSaverWrite: "macOS did not save the screen saver idle preference."
        case .process: "The macOS settings command failed."
        }
    }
}

private enum PowerCommands {
    static func read(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { throw PowerOperationError.process }
        return String(decoding: data, as: UTF8.self)
    }

    static func setLockSetting(_ setting: PowerLockSetting, password: PowerPassword) -> Bool {
        guard let arguments = setting.interactiveArguments else { return false }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        defer {
            password.erase()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        do { try process.run() } catch { return false }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        var prompt = ""
        var sent = false
        var rejected = false
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            // Interactive output is intentionally never logged or returned.
            if !sent {
                prompt += String(decoding: chunk, as: UTF8.self)
                prompt = String(prompt.suffix(4096))
                if prompt.lowercased().contains("password:") || prompt.lowercased().contains("password for") {
                    do { try password.writeAndErase(to: input.fileHandleForWriting) } catch { rejected = true; break }
                    prompt = ""
                    sent = true
                }
            } else {
                let text = String(decoding: chunk, as: UTF8.self).lowercased()
                if text.contains("error") || text.contains("incorrect") || text.contains("failed") { rejected = true }
            }
        }
        if process.isRunning && rejected { process.terminate() }
        process.waitUntilExit()
        timeout.cancel()
        return sent && !rejected && process.terminationStatus == 0
    }
}

/// A single owner lets the byte buffer be erased immediately after use rather
/// than retaining copies in asynchronous task captures. It is used on one
/// worker thread after creation; no credential is exposed through an argument.
private final class PowerPassword: @unchecked Sendable {
    private var bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    deinit { erase() }
    func erase() {
        bytes.resetBytes(in: 0..<bytes.count)
        bytes.removeAll()
    }
    func writeAndErase(to handle: FileHandle) throws {
        defer { erase() }
        bytes.append(10)
        try handle.write(contentsOf: bytes)
    }
}
