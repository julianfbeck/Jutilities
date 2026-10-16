import Foundation
import CoreFoundation

public struct KeyboardKeyMapping: Codable, Equatable, Hashable, Sendable {
    public var source: UInt64
    public var destination: UInt64

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    public var propertyDictionary: [String: UInt64] {
        ["HIDKeyboardModifierMappingSrc": source, "HIDKeyboardModifierMappingDst": destination]
    }
}

public struct KeyboardModifierKey: Identifiable, Equatable, Sendable {
    public let usage: UInt64
    public let label: String
    public var id: UInt64 { usage }

    public static let functionUsage: UInt64 = 0xFF00000003
    public static let standard: [KeyboardModifierKey] = [
        .init(usage: 0x700000039, label: "Caps Lock"),
        .init(usage: 0x7000000E0, label: "Left Control"),
        .init(usage: 0x7000000E4, label: "Right Control"),
        .init(usage: 0x7000000E2, label: "Left Option"),
        .init(usage: 0x7000000E6, label: "Right Option"),
        .init(usage: 0x7000000E3, label: "Left Command"),
        .init(usage: 0x7000000E7, label: "Right Command"),
        .init(usage: 0x7000000E1, label: "Left Shift"),
        .init(usage: 0x7000000E5, label: "Right Shift")
    ]
    public static let function = KeyboardModifierKey(usage: functionUsage, label: "Fn / Globe")
    public static let all = standard + [function]
    public static let sources = Set(all.map(\.usage))

    public static func label(for usage: UInt64) -> String {
        if let key = all.first(where: { $0.usage == usage }) { return key.label }
        if usage == 0x700000029 { return "Escape" }
        if usage == 0 { return "No action" }
        return String(format: "Key 0x%llX", usage)
    }
}

public struct KeyboardDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let vendorID: UInt32
    public let productID: UInt32
    public let locationID: UInt32
    public let name: String
    public let transport: String

    public init(id: UInt64, vendorID: UInt32, productID: UInt32, locationID: UInt32, name: String, transport: String) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.name = name
        self.transport = transport
    }

    // macOS stores modifier preferences by keyboard model, not registry ID.
    public var preferenceKey: String { "com.apple.keyboard.modifiermapping.\(vendorID)-\(productID)-0" }
    public var modelDescription: String { "\(transport) · \(vendorID):\(productID)" }
    public var matchingDictionary: [String: Any] {
        ["VendorID": vendorID, "ProductID": productID, "LocationID": locationID,
         "Transport": transport, "PrimaryUsagePage": 1, "PrimaryUsage": 6]
    }

    public func hasSameModel(as other: KeyboardDevice) -> Bool {
        vendorID == other.vendorID && productID == other.productID
    }
}

public struct KeyboardModifierState: Equatable, Sendable {
    public let nativeMappings: [KeyboardKeyMapping]
    public let userMappings: [KeyboardKeyMapping]

    public init(nativeMappings: [KeyboardKeyMapping], userMappings: [KeyboardKeyMapping]) throws {
        try KeyboardModifierPlan.validateUniqueSources(nativeMappings)
        try KeyboardModifierPlan.validateUniqueSources(userMappings)
        self.nativeMappings = nativeMappings
        self.userMappings = userMappings
    }

    public func effectiveDestination(for source: UInt64) -> UInt64 {
        let native = nativeMappings.first(where: { $0.source == source })?.destination ?? source
        return userMappings.first(where: { $0.source == native })?.destination ?? native
    }

    public func capturedModifiers(includeFunction: Bool) -> [KeyboardKeyMapping] {
        let keys = KeyboardModifierKey.standard + (includeFunction ? [KeyboardModifierKey.function] : [])
        return keys.map { .init(source: $0.usage, destination: effectiveDestination(for: $0.usage)) }
    }
}

public struct KeyboardModifierProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let sourceKeyboardName: String
    public let createdAt: Date
    public let mappings: [KeyboardKeyMapping]

    public init(id: UUID = UUID(), name: String, sourceKeyboardName: String, createdAt: Date = Date(), mappings: [KeyboardKeyMapping]) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw KeyboardConfigurationError.invalidName }
        try Self.validateMappings(mappings)
        self.id = id
        self.name = trimmed
        self.sourceKeyboardName = String(sourceKeyboardName.prefix(200))
        self.createdAt = createdAt
        self.mappings = mappings
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              sourceKeyboardName.count <= 200 else { throw KeyboardConfigurationError.invalidProfile }
        try Self.validateMappings(mappings)
    }

    private static func validateMappings(_ mappings: [KeyboardKeyMapping]) throws {
        try KeyboardModifierPlan.validateUniqueSources(mappings)
        let sources = Set(mappings.map(\.source))
        guard sources.isSuperset(of: Set(KeyboardModifierKey.standard.map(\.usage))),
              sources.isSubset(of: KeyboardModifierKey.sources), mappings.count <= 10,
              mappings.allSatisfy({ $0.destination <= 0xFFFFFFFFFFFF }) else {
            throw KeyboardConfigurationError.invalidProfile
        }
    }
}

public struct KeyboardModifierProfileArchive: Codable, Equatable, Sendable {
    public let version: Int
    public var profiles: [KeyboardModifierProfile]

    public init(profiles: [KeyboardModifierProfile] = []) { version = 1; self.profiles = profiles }

    public func validate() throws {
        guard version == 1, profiles.count <= 100, Set(profiles.map(\.id)).count == profiles.count else {
            throw KeyboardConfigurationError.invalidProfile
        }
        try profiles.forEach { try $0.validate() }
    }
}

public struct KeyboardModifierPlan: Equatable, Sendable {
    public let nativeMappings: [KeyboardKeyMapping]

    public init(profile: KeyboardModifierProfile, current: KeyboardModifierState, supportsFunction: Bool) throws {
        try profile.validate()
        let requested = profile.mappings.filter { supportsFunction || $0.source != KeyboardModifierKey.functionUsage }
        let replacedSources = Set(requested.map(\.source))
        // Only modifier sources are replaced. Other native and all UserKeyMapping
        // remaps remain intact. Apple applies UserKeyMapping after native modifiers.
        let planned = current.nativeMappings.filter { !replacedSources.contains($0.source) } + requested
        let final = try KeyboardModifierState(nativeMappings: planned, userMappings: current.userMappings)
        guard requested.allSatisfy({ final.effectiveDestination(for: $0.source) == $0.destination }) else {
            throw KeyboardConfigurationError.conflictingUserMapping
        }
        nativeMappings = planned
    }

    public static func validateUniqueSources(_ mappings: [KeyboardKeyMapping]) throws {
        guard mappings.count <= 512, Set(mappings.map(\.source)).count == mappings.count else {
            throw KeyboardConfigurationError.invalidMapping
        }
    }

    public static func validateUnrelatedPreferenceMappings(current: KeyboardModifierState,
                                                           persisted: [KeyboardKeyMapping]?) throws {
        if let persisted { try validateUniqueSources(persisted) }
        let liveOther = Set(current.nativeMappings.filter { !KeyboardModifierKey.sources.contains($0.source) })
        let savedOther = Set((persisted ?? []).filter { !KeyboardModifierKey.sources.contains($0.source) })
        guard liveOther == savedOther else { throw KeyboardConfigurationError.inconsistentNativePreference }
    }
}

public struct KeyboardModifierBackup: Codable, Equatable, Sendable {
    public let version: Int
    public let device: KeyboardDevice
    public let originalNative: [KeyboardKeyMapping]
    public let originalUser: [KeyboardKeyMapping]
    public let originalPreference: [KeyboardKeyMapping]?
    public let appliedNative: [KeyboardKeyMapping]

    public init(device: KeyboardDevice, originalNative: [KeyboardKeyMapping], originalUser: [KeyboardKeyMapping],
                originalPreference: [KeyboardKeyMapping]?, appliedNative: [KeyboardKeyMapping]) throws {
        version = 1
        self.device = device
        self.originalNative = originalNative
        self.originalUser = originalUser
        self.originalPreference = originalPreference
        self.appliedNative = appliedNative
        try validate()
    }

    public func validate() throws {
        guard version == 1, device.id > 0, device.vendorID > 0, device.productID > 0,
              ["USB", "Bluetooth", "Bluetooth Low Energy", "SPI", "I2C"].contains(device.transport) else {
            throw KeyboardConfigurationError.invalidProfile
        }
        try KeyboardModifierPlan.validateUniqueSources(originalNative)
        try KeyboardModifierPlan.validateUniqueSources(originalUser)
        try KeyboardModifierPlan.validateUniqueSources(appliedNative)
        if let originalPreference { try KeyboardModifierPlan.validateUniqueSources(originalPreference) }
        let originalOther = Set(originalNative.filter { !KeyboardModifierKey.sources.contains($0.source) })
        let appliedOther = Set(appliedNative.filter { !KeyboardModifierKey.sources.contains($0.source) })
        guard originalOther == appliedOther else { throw KeyboardConfigurationError.invalidProfile }
    }

    private enum CodingKeys: String, CodingKey {
        case version, device, originalNative, originalUser, originalPreference, appliedNative
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        device = try container.decode(KeyboardDevice.self, forKey: .device)
        originalNative = try container.decode([KeyboardKeyMapping].self, forKey: .originalNative)
        originalUser = try container.decode([KeyboardKeyMapping].self, forKey: .originalUser)
        originalPreference = try container.decodeIfPresent([KeyboardKeyMapping].self, forKey: .originalPreference)
        appliedNative = try container.decode([KeyboardKeyMapping].self, forKey: .appliedNative)
        try validate()
    }
}

public struct KeyboardModifierRecoveryPlan: Equatable, Sendable {
    public let nativeMappings: [KeyboardKeyMapping]
    public let preferenceMappings: [KeyboardKeyMapping]?

    public init(backup: KeyboardModifierBackup, current: KeyboardModifierState,
                currentPreference: [KeyboardKeyMapping]?) throws {
        try backup.validate()
        if let currentPreference { try KeyboardModifierPlan.validateUniqueSources(currentPreference) }
        let native = Set(current.nativeMappings)
        let preference = currentPreference.map(Set.init)
        guard Set(current.userMappings) == Set(backup.originalUser),
              native == Set(backup.originalNative) || native == Set(backup.appliedNative),
              preference == backup.originalPreference.map(Set.init) || preference == Set(backup.appliedNative) else {
            throw KeyboardConfigurationError.changedSinceApply
        }
        nativeMappings = backup.originalNative
        preferenceMappings = backup.originalPreference
    }
}

/// Parsers operate on fixtures too; they never enumerate or change real devices.
public enum KeyboardConfigurationParser {
    public static func devices(ndjson: Data) throws -> [KeyboardDevice] {
        guard ndjson.count < 4_000_000, let text = String(data: ndjson, encoding: .utf8) else {
            throw KeyboardConfigurationError.invalidInventory
        }
        var devices: [KeyboardDevice] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw KeyboardConfigurationError.invalidInventory
            }
            guard record["type"] as? String == "service",
                  number(record["PrimaryUsagePage"]) == 1, number(record["PrimaryUsage"]) == 6 else { continue }
            guard let transport = record["Transport"] as? String,
                  ["USB", "Bluetooth", "Bluetooth Low Energy", "SPI", "I2C"].contains(transport),
                  let name = record["Product"] as? String,
                  !name.localizedCaseInsensitiveContains("virtual"),
                  !name.localizedCaseInsensitiveContains("touchbar"),
                  let id = number(record["IORegistryEntryID"]),
                  let vendor = number(record["VendorID"]), vendor > 0, vendor <= UInt32.max,
                  let product = number(record["ProductID"]), product > 0, product <= UInt32.max,
                  let location = number(record["LocationID"]), location <= UInt32.max else { continue }
            devices.append(.init(id: id, vendorID: UInt32(vendor), productID: UInt32(product),
                                 locationID: UInt32(location), name: String(name.prefix(200)), transport: transport))
        }
        guard Set(devices.map(\.id)).count == devices.count else { throw KeyboardConfigurationError.invalidInventory }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func state(plist: Data, registryID: UInt64) throws -> KeyboardModifierState {
        guard plist.count < 8_000_000,
              let root = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let records = root["ServiceRecords"] as? [[String: Any]] else {
            throw KeyboardConfigurationError.unavailableState
        }
        let matches = records.filter { number($0["IORegistryEntryID"]) == registryID }
        guard matches.count == 1,
              let filters = matches[0]["ServiceFilterDebug"] as? [[String: Any]] else {
            throw KeyboardConfigurationError.unavailableState
        }
        let plugins = filters.compactMap { $0["plugin"] as? [String: Any] }
            .filter { $0["Class"] as? String == "IOHIDKeyboardFilter" }
        guard plugins.count == 1, let native = plugins[0]["HIDKeyboardModifierMappingPairs"],
              let user = plugins[0]["UserKeyMapping"] else { throw KeyboardConfigurationError.unavailableState }
        return try .init(nativeMappings: mappings(native), userMappings: mappings(user))
    }

    public static func mappings(_ value: Any) throws -> [KeyboardKeyMapping] {
        guard let values = value as? [[String: Any]], values.count <= 512 else {
            throw KeyboardConfigurationError.invalidMapping
        }
        let mappings = try values.map { value -> KeyboardKeyMapping in
            guard let source = number(value["HIDKeyboardModifierMappingSrc"] ?? value["Src"]),
                  let destination = number(value["HIDKeyboardModifierMappingDst"] ?? value["Dst"]) else {
                throw KeyboardConfigurationError.invalidMapping
            }
            return .init(source: source, destination: destination)
        }
        try KeyboardModifierPlan.validateUniqueSources(mappings)
        return mappings
    }

    private static func number(_ value: Any?) -> UInt64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0,
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
        return UInt64(value.stringValue)
    }
}

public enum KeyboardConfigurationError: LocalizedError {
    case invalidName, invalidProfile, invalidMapping, invalidInventory, unavailableState, conflictingUserMapping, changedSinceApply, inconsistentNativePreference

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a configuration name of 1–80 characters."
        case .invalidProfile: "This saved keyboard configuration is not valid."
        case .invalidMapping: "macOS reported an unsupported or ambiguous key mapping."
        case .invalidInventory: "The connected keyboards could not be identified safely."
        case .unavailableState: "macOS did not report this keyboard’s live modifier mappings. Open Keyboard settings to inspect them."
        case .conflictingUserMapping: "Another key-remapping tool changes the requested modifiers. Adjust its UserKeyMapping first, then refresh; Jutilities kept it unchanged."
        case .changedSinceApply: "Modifier settings have changed since Apply. Undo stopped to preserve those changes; check Keyboard settings."
        case .inconsistentNativePreference: "Other live key remappings differ from this keyboard’s saved macOS settings. Check Keyboard settings or the other remapping tool before applying; Jutilities kept both unchanged."
        }
    }
}
