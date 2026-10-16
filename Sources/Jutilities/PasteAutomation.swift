import AppKit
import ApplicationServices
import CryptoKit

struct PastePermissionStatus: Equatable {
    let accessibilityTrusted: Bool
    let canPostEvents: Bool

    var allowsAutomaticPaste: Bool { accessibilityTrusted && canPostEvents }

    static func current() -> PastePermissionStatus {
        // Query this executable each time. A checked entry for an older build in
        // System Settings does not grant a newly signed executable permission.
        PastePermissionStatus(accessibilityTrusted: AXIsProcessTrusted(),
                              canPostEvents: CGPreflightPostEventAccess())
    }
}

enum PastePermissionDiagnostics {
    struct Identity: Codable, Equatable {
        let bundleIdentifier: String
        let executablePath: String
        let version: String
        let build: String
        let executableSHA256: String?
    }

    struct Record: Codable {
        let recordedAt: Date
        let processIdentifier: pid_t
        let processLaunchDate: Date?
        let identity: Identity
        let accessibilityTrusted: Bool
        let canPostEvents: Bool
        let automaticPasteAvailable: Bool
    }

    struct LiveProcess {
        let processIdentifier: pid_t
        let launchDate: Date?
        let bundleIdentifier: String?
        let executablePath: String?
    }

    struct GUIReport: Codable {
        enum State: String, Codable {
            case valid, missing, unreadable, stale, notRunning, identityMismatch
        }
        let state: State
        let report: Record?
    }

    struct CommandLineReport: Codable {
        let currentProcess: Record
        let latestGUI: GUIReport
    }

    // Cache at process startup/first GUI report so a replaced app on disk does
    // not make an older running instance appear to be the replacement build.
    private static let identity: Identity = {
        let bundle = Bundle.main
        let executable = bundle.executableURL?.resolvingSymlinksInPath()
        let digest = executable.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        return Identity(bundleIdentifier: bundle.bundleIdentifier ?? "",
                        executablePath: executable?.path ?? "",
                        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                        build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                        executableSHA256: digest)
    }()

    @MainActor
    static func recordGUI(status: PastePermissionStatus) {
        guard NSApp?.isRunning == true else { return }
        let record = makeRecord(status: status)
        guard let url = statusURL() else { return }
        try? write(record, to: url)
    }

    static func commandLineReport() -> CommandLineReport {
        CommandLineReport(currentProcess: makeRecord(status: .current()), latestGUI: latestGUIReport())
    }

    static func encodedCommandLineReport() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(commandLineReport()) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func validate(_ record: Record, expectedIdentity: Identity, liveProcess: LiveProcess?,
                         now: Date = Date()) -> GUIReport {
        guard now.timeIntervalSince(record.recordedAt) >= -5,
              now.timeIntervalSince(record.recordedAt) <= 300 else {
            return GUIReport(state: .stale, report: nil)
        }
        guard let liveProcess else { return GUIReport(state: .notRunning, report: nil) }
        guard let recordedLaunch = record.processLaunchDate, let actualLaunch = liveProcess.launchDate,
              record.identity == expectedIdentity, expectedIdentity.executableSHA256 != nil,
              !expectedIdentity.bundleIdentifier.isEmpty, !expectedIdentity.executablePath.isEmpty,
              record.processIdentifier == liveProcess.processIdentifier,
              abs(recordedLaunch.timeIntervalSince(actualLaunch)) < 1,
              liveProcess.bundleIdentifier == expectedIdentity.bundleIdentifier,
              liveProcess.executablePath == expectedIdentity.executablePath else {
            return GUIReport(state: .identityMismatch, report: nil)
        }
        return GUIReport(state: .valid, report: record)
    }

    static func write(_ record: Record, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(record).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func makeRecord(status: PastePermissionStatus) -> Record {
        Record(recordedAt: Date(), processIdentifier: getpid(),
               processLaunchDate: NSRunningApplication.current.launchDate, identity: identity,
               accessibilityTrusted: status.accessibilityTrusted, canPostEvents: status.canPostEvents,
               automaticPasteAvailable: status.allowsAutomaticPaste)
    }

    private static func statusURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Jutilities", isDirectory: true)
            .appendingPathComponent("permission-status.json")
    }

    private static func latestGUIReport() -> GUIReport {
        guard let url = statusURL(), FileManager.default.fileExists(atPath: url.path) else {
            return GUIReport(state: .missing, report: nil)
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 32_768, let data = try? Data(contentsOf: url) else {
            return GUIReport(state: .unreadable, report: nil)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let record = try? decoder.decode(Record.self, from: data) else {
            return GUIReport(state: .unreadable, report: nil)
        }
        let running = NSRunningApplication(processIdentifier: record.processIdentifier)
        let live = running.flatMap { application -> LiveProcess? in
            guard !application.isTerminated else { return nil }
            return LiveProcess(processIdentifier: application.processIdentifier, launchDate: application.launchDate,
                               bundleIdentifier: application.bundleIdentifier,
                               executablePath: application.executableURL?.resolvingSymlinksInPath().path)
        }
        return validate(record, expectedIdentity: identity, liveProcess: live)
    }
}

@MainActor
final class PasteAutomation {
    enum Outcome: Equatable {
        case pasted
        case permissionRequired
        case targetUnavailable
        case activationFailed
        case focusNotRestored
        case focusChanged
        case cancelled
        case eventCreationFailed
    }

    struct Environment {
        var permission: () -> PastePermissionStatus
        var clipboardChangeCount: () -> Int
        var activate: (pid_t) -> Bool
        var isRunning: (pid_t) -> Bool
        var frontmostPID: () -> pid_t?
        var postPaste: () -> Bool
        var pause: () async throws -> Void

        static var live: Environment {
            Environment(
                permission: PastePermissionStatus.current,
                clipboardChangeCount: { NSPasteboard.general.changeCount },
                activate: { NSRunningApplication(processIdentifier: $0)?.activate(options: []) ?? false },
                isRunning: { identifier in
                    guard identifier != getpid(),
                          let application = NSRunningApplication(processIdentifier: identifier) else { return false }
                    return !application.isTerminated
                },
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                postPaste: {
                    guard let source = CGEventSource(stateID: .privateState),
                          let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
                    down.flags = .maskCommand
                    up.flags = .maskCommand
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                    return true
                },
                pause: { try await Task.sleep(for: .milliseconds(30)) }
            )
        }
    }

    private let environment: Environment

    init(environment: Environment? = nil) {
        self.environment = environment ?? .live
    }

    func paste(into targetPID: pid_t, clipboardChangeCount: Int,
               operationIsCurrent: @escaping () -> Bool) async -> Outcome {
        func isCurrent() -> Bool {
            !Task.isCancelled && operationIsCurrent()
                && environment.clipboardChangeCount() == clipboardChangeCount
        }
        guard isCurrent() else { return .cancelled }
        guard environment.permission().allowsAutomaticPaste else { return .permissionRequired }
        guard environment.isRunning(targetPID) else { return .targetUnavailable }
        let originalFrontmost = environment.frontmostPID()
        guard environment.activate(targetPID) else { return .activationFailed }

        // Activation is asynchronous. Wait for the destination to stay frontmost
        // over two checks instead of assuming it is ready after one fixed delay.
        var consecutiveFocusChecks = 0
        for _ in 0..<25 {
            guard isCurrent() else { return .cancelled }
            guard environment.isRunning(targetPID) else { return .targetUnavailable }
            let frontmost = environment.frontmostPID()
            if frontmost == targetPID {
                consecutiveFocusChecks += 1
                if consecutiveFocusChecks == 2 {
                    guard environment.permission().allowsAutomaticPaste else { return .permissionRequired }
                    guard isCurrent() else { return .cancelled }
                    return environment.postPaste() ? .pasted : .eventCreationFailed
                }
            } else {
                // Do not send keystrokes if the user switches to a third app.
                if consecutiveFocusChecks > 0 || (frontmost != nil && frontmost != originalFrontmost) {
                    return .focusChanged
                }
            }
            do { try await environment.pause() }
            catch { return .cancelled }
        }
        return .focusNotRestored
    }
}
