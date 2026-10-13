import Foundation

public struct PowerSettingsSnapshot: Equatable, Sendable {
    public var systemSleepMinutes: Int?
    public var displaySleepMinutes: Int?
    public var screenSaverIdleSeconds: Int?

    public init(systemSleepMinutes: Int? = nil, displaySleepMinutes: Int? = nil, screenSaverIdleSeconds: Int? = nil) {
        self.systemSleepMinutes = systemSleepMinutes
        self.displaySleepMinutes = displaySleepMinutes
        self.screenSaverIdleSeconds = screenSaverIdleSeconds
    }

    /// Parses exact pmset keys, ignoring assertions and unrelated settings.
    public static func parsePMSet(_ output: String) -> Self {
        var result = Self()
        for line in output.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            guard words.count >= 2, let minutes = Int(words[1]), minutes >= 0 else { continue }
            switch words[0] {
            case "sleep": result.systemSleepMinutes = minutes
            case "displaysleep": result.displaySleepMinutes = minutes
            default: break
            }
        }
        return result
    }
}

public struct PowerSettingsDraft: Equatable, Sendable {
    public var systemSleepMinutes: Int?
    public var displaySleepMinutes: Int?
    public var screenSaverIdleSeconds: Int?

    public init(systemSleepMinutes: Int? = nil, displaySleepMinutes: Int? = nil, screenSaverIdleSeconds: Int? = nil) {
        self.systemSleepMinutes = systemSleepMinutes
        self.displaySleepMinutes = displaySleepMinutes
        self.screenSaverIdleSeconds = screenSaverIdleSeconds
    }
}

public enum PowerSettingsError: LocalizedError, Equatable {
    case invalidMinutes
    case invalidScreenSaverSeconds
    case invalidDuration

    public var errorDescription: String? {
        switch self {
        case .invalidMinutes: "Sleep time must be between 0 and 1440 minutes."
        case .invalidScreenSaverSeconds: "Screen saver time must be between 0 and 86400 seconds."
        case .invalidDuration: "Keep-awake duration must be positive and no longer than 24 hours."
        }
    }
}

/// Contains only validated changes. Constructing a plan never changes the computer.
public struct PowerSettingsPlan: Equatable, Sendable {
    public let pmsetArguments: [String]
    public let screenSaverIdleSeconds: Int?

    public init(current: PowerSettingsSnapshot, draft: PowerSettingsDraft) throws {
        for minutes in [draft.systemSleepMinutes, draft.displaySleepMinutes].compactMap({ $0 }) {
            guard (0...1440).contains(minutes) else { throw PowerSettingsError.invalidMinutes }
        }
        if let seconds = draft.screenSaverIdleSeconds, !(0...86400).contains(seconds) {
            throw PowerSettingsError.invalidScreenSaverSeconds
        }

        var changes: [String] = []
        if let minutes = draft.systemSleepMinutes, minutes != current.systemSleepMinutes {
            changes += ["sleep", String(minutes)]
        }
        if let minutes = draft.displaySleepMinutes, minutes != current.displaySleepMinutes {
            changes += ["displaysleep", String(minutes)]
        }
        pmsetArguments = changes.isEmpty ? [] : ["-a"] + changes
        screenSaverIdleSeconds = draft.screenSaverIdleSeconds != current.screenSaverIdleSeconds
            ? draft.screenSaverIdleSeconds : nil
    }

    public var hasChanges: Bool { !pmsetArguments.isEmpty || screenSaverIdleSeconds != nil }

    /// Every token is a constant or a validated integer, never user-supplied shell text.
    public var privilegedCommand: String? {
        pmsetArguments.isEmpty ? nil : (["/usr/bin/pmset"] + pmsetArguments).joined(separator: " ")
    }
}

public struct PowerSessionPlan: Equatable, Sendable {
    public let duration: TimeInterval?
    public let keepsDisplayAwake: Bool

    public init(duration: TimeInterval?, display: Bool) throws {
        if let duration, !duration.isFinite || duration <= 0 || duration > 86400 {
            throw PowerSettingsError.invalidDuration
        }
        self.duration = duration
        keepsDisplayAwake = display
    }

    public func endDate(from start: Date) -> Date? { duration.map { start.addingTimeInterval($0) } }
    public func hasExpired(startedAt: Date, now: Date) -> Bool {
        guard let end = endDate(from: startedAt) else { return false }
        return now >= end
    }
}

public enum PowerLockSetting: Equatable, Hashable, Sendable {
    case never
    case immediately
    case after(seconds: Int)

    public static let choices: [Self] = [.never, .immediately, .after(seconds: 5), .after(seconds: 60), .after(seconds: 300), .after(seconds: 900), .after(seconds: 3600), .after(seconds: 14400), .after(seconds: 28800)]

    public var label: String {
        switch self {
        case .never: "Never"
        case .immediately: "Immediately"
        case .after(let seconds):
            seconds < 60 ? "After \(seconds) seconds" : "After \(seconds / 60) minutes"
        }
    }

    public static func parseStatus(_ output: String) -> Self? {
        if output.contains("screenLock is off") { return .never }
        if output.contains("screenLock delay is immediate") { return .immediately }
        guard let range = output.range(of: #"screenLock delay is [0-9]+ seconds"#, options: .regularExpression) else { return nil }
        let words = output[range].split(separator: " ")
        guard words.count == 5, let seconds = Int(words[3]), (0...28800).contains(seconds) else { return nil }
        return seconds == 0 ? .immediately : .after(seconds: seconds)
    }

    public var commandArgument: String? {
        switch self {
        case .never: "off"
        case .immediately: "immediate"
        case .after(let seconds): (1...28800).contains(seconds) ? String(seconds) : nil
        }
    }

    /// Password is supplied only through a private pipe after a terminal prompt.
    public var interactiveArguments: [String]? {
        guard let commandArgument else { return nil }
        return ["-q", "/dev/null", "/usr/sbin/sysadminctl", "-screenLock", commandArgument, "-password", "-"]
    }
}
