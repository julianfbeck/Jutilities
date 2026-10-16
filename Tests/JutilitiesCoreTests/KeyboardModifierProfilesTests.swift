import XCTest
@testable import JutilitiesCore

final class KeyboardModifierProfilesTests: XCTestCase {
    private let caps: UInt64 = 0x700000039
    private let escape: UInt64 = 0x700000029
    private let control: UInt64 = 0x7000000E0
    private let command: UInt64 = 0x7000000E3
    private let letterA: UInt64 = 0x700000004
    private let letterB: UInt64 = 0x700000005
    private var device: KeyboardDevice {
        .init(id: 17, vendorID: 1452, productID: 999, locationID: 12, name: "Fixture Keyboard", transport: "USB")
    }

    func testInventoryKeepsOnlyPhysicalKeyboardServices() throws {
        let records: [[String: Any]] = [
            inventoryRecord(id: 17),
            inventoryRecord(id: 18, type: "device"),
            inventoryRecord(id: 19, transport: "Virtual"),
            inventoryRecord(id: 20, transport: "UniversalControl"),
            inventoryRecord(id: 21, usage: 2)
        ]
        let bytes = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        let devices = try KeyboardConfigurationParser.devices(ndjson: Data(bytes.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, 17)
        XCTAssertEqual(devices.first?.preferenceKey, "com.apple.keyboard.modifiermapping.1452-999-0")
        XCTAssertEqual(devices.first?.matchingDictionary["LocationID"] as? UInt32, 12)
    }

    func testDuplicateRegistryIdentityFailsClosed() throws {
        let record = String(decoding: try JSONSerialization.data(withJSONObject: inventoryRecord(id: 17)), as: UTF8.self)
        XCTAssertThrowsError(try KeyboardConfigurationParser.devices(ndjson: Data("\(record)\n\(record)".utf8)))
        XCTAssertThrowsError(try KeyboardConfigurationParser.devices(ndjson: Data("not JSON".utf8)))
    }

    func testReadsNativeAndUserMapsFromExactKeyboardFilter() throws {
        let payload = try filterDump(native: [["Src": caps, "Dst": control]], user: [["Src": control, "Dst": command]])
        let state = try KeyboardConfigurationParser.state(plist: payload, registryID: 17)
        XCTAssertEqual(state.nativeMappings, [.init(source: caps, destination: control)])
        XCTAssertEqual(state.effectiveDestination(for: caps), command)
        XCTAssertEqual(state.effectiveDestination(for: escape), escape)
        XCTAssertThrowsError(try KeyboardConfigurationParser.state(plist: payload, registryID: 18))
    }

    func testUnavailableNativeOrUserStateCannotBeAssumedDefault() throws {
        let payload = try filterDump(native: [], user: nil)
        XCTAssertThrowsError(try KeyboardConfigurationParser.state(plist: payload, registryID: 17))
    }

    func testMalformedAndDuplicateSourceMappingsFail() {
        XCTAssertThrowsError(try KeyboardConfigurationParser.mappings([["Src": caps]]))
        XCTAssertThrowsError(try KeyboardConfigurationParser.mappings([["Src": -1, "Dst": 0]]))
        XCTAssertThrowsError(try KeyboardConfigurationParser.mappings([["Src": true, "Dst": 0]]))
        XCTAssertThrowsError(try KeyboardConfigurationParser.mappings([["Src": caps, "Dst": control], ["Src": caps, "Dst": command]]))
    }

    func testCaptureIncludesBothSidesAndEscapeWithoutCapturingNonModifiers() throws {
        let state = try KeyboardModifierState(nativeMappings: [.init(source: caps, destination: escape), .init(source: letterA, destination: letterB)], userMappings: [])
        let mappings = state.capturedModifiers(includeFunction: true)
        XCTAssertEqual(mappings.count, 10)
        XCTAssertEqual(mappings.first { $0.source == caps }?.destination, escape)
        XCTAssertTrue(mappings.contains { $0.source == 0x7000000E4 })
        XCTAssertTrue(mappings.contains { $0.source == 0x7000000E7 })
        XCTAssertTrue(mappings.contains { $0.source == KeyboardModifierKey.functionUsage })
        XCTAssertFalse(mappings.contains { $0.source == letterA })
    }

    func testApplyingSavedModifiersPreservesUnrelatedNativeAndUserMappings() throws {
        let current = try KeyboardModifierState(nativeMappings: [.init(source: letterA, destination: letterB), .init(source: caps, destination: control)],
                                               userMappings: [.init(source: 0x700000006, destination: 0x700000007)])
        let source = try KeyboardModifierState(nativeMappings: [.init(source: caps, destination: escape)], userMappings: [])
        let profile = try KeyboardModifierProfile(name: " Escape caps ", sourceKeyboardName: "Other keyboard", mappings: source.capturedModifiers(includeFunction: false))
        let plan = try KeyboardModifierPlan(profile: profile, current: current, supportsFunction: false)
        XCTAssertEqual(profile.name, "Escape caps")
        XCTAssertTrue(plan.nativeMappings.contains(.init(source: letterA, destination: letterB)))
        XCTAssertEqual(plan.nativeMappings.first { $0.source == caps }?.destination, escape)
        let after = try KeyboardModifierState(nativeMappings: plan.nativeMappings, userMappings: current.userMappings)
        XCTAssertEqual(after.userMappings, current.userMappings)
        XCTAssertEqual(after.effectiveDestination(for: caps), escape)
    }

    func testConflictingUserMappingBlocksApplyWithoutChangingAnyMappings() throws {
        let current = try KeyboardModifierState(nativeMappings: [], userMappings: [.init(source: control, destination: command)])
        let standard = try KeyboardModifierState(nativeMappings: [], userMappings: [])
        let profile = try KeyboardModifierProfile(name: "Standard", sourceKeyboardName: "Other", mappings: standard.capturedModifiers(includeFunction: false))
        XCTAssertThrowsError(try KeyboardModifierPlan(profile: profile, current: current, supportsFunction: false)) { error in
            XCTAssertEqual(error.localizedDescription, KeyboardConfigurationError.conflictingUserMapping.localizedDescription)
        }
        XCTAssertEqual(current.userMappings, [.init(source: control, destination: command)])
    }

    func testUnrelatedSavedAndLiveMappingsMustAgreeBeforeAnyPreferenceWrite() throws {
        let modifierOnly = try KeyboardModifierState(nativeMappings: [.init(source: caps, destination: escape)], userMappings: [])
        XCTAssertNoThrow(try KeyboardModifierPlan.validateUnrelatedPreferenceMappings(current: modifierOnly, persisted: nil))
        let withOther = try KeyboardModifierState(nativeMappings: [.init(source: letterA, destination: letterB)], userMappings: [])
        XCTAssertNoThrow(try KeyboardModifierPlan.validateUnrelatedPreferenceMappings(current: withOther, persisted: [
            .init(source: caps, destination: control), .init(source: letterA, destination: letterB)
        ]))
        // A transient remap must not become persistent incidentally.
        XCTAssertThrowsError(try KeyboardModifierPlan.validateUnrelatedPreferenceMappings(current: withOther, persisted: nil))
        // An inactive saved remap must not be erased incidentally either.
        XCTAssertThrowsError(try KeyboardModifierPlan.validateUnrelatedPreferenceMappings(current: modifierOnly, persisted: [
            .init(source: letterA, destination: letterB)
        ]))
    }

    func testFunctionMappingDoesNotApplyToUnsupportedKeyboard() throws {
        let mappings = try KeyboardModifierState(nativeMappings: [.init(source: KeyboardModifierKey.functionUsage, destination: control)], userMappings: []).capturedModifiers(includeFunction: true)
        let profile = try KeyboardModifierProfile(name: "Apple", sourceKeyboardName: "Apple", mappings: mappings)
        let current = try KeyboardModifierState(nativeMappings: [], userMappings: [])
        XCTAssertFalse(try KeyboardModifierPlan(profile: profile, current: current, supportsFunction: false).nativeMappings.contains { $0.source == KeyboardModifierKey.functionUsage })
        XCTAssertTrue(try KeyboardModifierPlan(profile: profile, current: current, supportsFunction: true).nativeMappings.contains { $0.source == KeyboardModifierKey.functionUsage && $0.destination == control })
    }

    func testProfileRejectsIncompleteNonModifierAndDuplicateConfigurations() throws {
        XCTAssertThrowsError(try KeyboardModifierProfile(name: "Missing", sourceKeyboardName: "Fixture", mappings: [.init(source: caps, destination: escape)]))
        var mappings = try KeyboardModifierState(nativeMappings: [], userMappings: []).capturedModifiers(includeFunction: false)
        mappings.append(.init(source: letterA, destination: letterB))
        XCTAssertThrowsError(try KeyboardModifierProfile(name: "Extra", sourceKeyboardName: "Fixture", mappings: mappings))
        XCTAssertThrowsError(try KeyboardModifierProfile(name: "   ", sourceKeyboardName: "Fixture", mappings: []))
    }

    func testArchiveRoundTripAndUnsupportedVersionValidation() throws {
        let profile = try KeyboardModifierProfile(name: "My keys", sourceKeyboardName: "Fixture", mappings: KeyboardModifierState(nativeMappings: [], userMappings: []).capturedModifiers(includeFunction: true))
        let archive = KeyboardModifierProfileArchive(profiles: [profile])
        let data = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(KeyboardModifierProfileArchive.self, from: data)
        try decoded.validate()
        XCTAssertEqual(decoded, archive)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 999
        let unsupported = try JSONDecoder().decode(KeyboardModifierProfileArchive.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try unsupported.validate())
        XCTAssertThrowsError(try KeyboardModifierProfileArchive(profiles: [profile, profile]).validate())
    }

    func testRecoveryHandlesEachCrashPointAndRejectsOtherToolsChanges() throws {
        let before = [KeyboardKeyMapping(source: caps, destination: control)]
        let applied = [KeyboardKeyMapping(source: caps, destination: escape)]
        let backup = try KeyboardModifierBackup(device: device, originalNative: before, originalUser: [], originalPreference: nil, appliedNative: applied)
        // Before live write, between live and preference writes, fully applied,
        // and between the two restoration writes are all safe to recover.
        let preferences: [[KeyboardKeyMapping]?] = [nil, applied]
        for native in [before, applied] {
            for preference in preferences {
                let state = try KeyboardModifierState(nativeMappings: native, userMappings: [])
                let plan = try KeyboardModifierRecoveryPlan(backup: backup, current: state, currentPreference: preference)
                XCTAssertEqual(plan.nativeMappings, before)
                XCTAssertNil(plan.preferenceMappings)
            }
        }
        let changed = try KeyboardModifierState(nativeMappings: [.init(source: caps, destination: command)], userMappings: [])
        XCTAssertThrowsError(try KeyboardModifierRecoveryPlan(backup: backup, current: changed, currentPreference: applied))
        let changedUser = try KeyboardModifierState(nativeMappings: applied, userMappings: [.init(source: letterA, destination: letterB)])
        XCTAssertThrowsError(try KeyboardModifierRecoveryPlan(backup: backup, current: changedUser, currentPreference: applied))
        let unchanged = try KeyboardModifierState(nativeMappings: applied, userMappings: [])
        XCTAssertThrowsError(try KeyboardModifierRecoveryPlan(backup: backup, current: unchanged, currentPreference: [.init(source: caps, destination: command)]))
    }

    func testBackupDecoderRejectsMissingOrUnsupportedVersionAndNonModifierMutations() throws {
        let backup = try KeyboardModifierBackup(device: device, originalNative: [], originalUser: [], originalPreference: nil,
                                               appliedNative: [.init(source: caps, destination: escape)])
        let encoded = try JSONEncoder().encode(backup)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardModifierBackup.self, from: encoded), backup)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["version"] = 999
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardModifierBackup.self, from: JSONSerialization.data(withJSONObject: json)))
        json.removeValue(forKey: "version")
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardModifierBackup.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try KeyboardModifierBackup(device: device, originalNative: [], originalUser: [], originalPreference: nil,
                                                       appliedNative: [.init(source: letterA, destination: letterB)]))
    }

    private func inventoryRecord(id: UInt64, type: String = "service", transport: String = "USB", usage: Int = 6) -> [String: Any] {
        ["type": type, "PrimaryUsagePage": 1, "PrimaryUsage": usage, "IORegistryEntryID": id,
         "VendorID": 1452, "ProductID": 999, "LocationID": 12, "Product": "Fixture Keyboard", "Transport": transport]
    }

    private func filterDump(native: [[String: UInt64]], user: [[String: UInt64]]?) throws -> Data {
        var plugin: [String: Any] = ["Class": "IOHIDKeyboardFilter", "HIDKeyboardModifierMappingPairs": native]
        if let user { plugin["UserKeyMapping"] = user }
        return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": [
            ["IORegistryEntryID": 17, "ServiceFilterDebug": [["plugin": plugin]]]
        ]], format: .xml, options: 0)
    }
}
