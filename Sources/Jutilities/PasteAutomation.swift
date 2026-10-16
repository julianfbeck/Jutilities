import AppKit
import ApplicationServices

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
