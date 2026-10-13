import Foundation
import IOKit.pwr_mgt
import XCTest

final class PowerManagerTests: XCTestCase {
    @MainActor
    func testStopReleasesNativeSystemSleepAssertion() async throws {
        try requireNativeAssertionSupport()
        let baseline = try activeSystemAssertionCount()
        let manager = PowerManager()
        defer { manager.shutdown() }

        manager.start(duration: nil, display: false)

        XCTAssertTrue(manager.isKeepingAwake, manager.errorMessage ?? "The session did not start.")
        XCTAssertFalse(manager.keepDisplayAwake)
        XCTAssertNil(manager.until)
        let appeared = try await waitForAssertionCount(baseline + 1)
        XCTAssertTrue(appeared, "powerd must report a live system-sleep assertion owned by the test process.")

        manager.stop()

        XCTAssertFalse(manager.isKeepingAwake)
        let released = try await waitForAssertionCount(baseline)
        XCTAssertTrue(released, "Stop must release the actual IOKit assertion.")
    }

    @MainActor
    func testTimedSessionExpiresAndReleasesNativeAssertion() async throws {
        try requireNativeAssertionSupport()
        let baseline = try activeSystemAssertionCount()
        let manager = PowerManager()
        defer { manager.shutdown() }

        manager.start(duration: 1, display: false)

        XCTAssertTrue(manager.isKeepingAwake, manager.errorMessage ?? "The timed session did not start.")
        XCTAssertNotNil(manager.until)
        let appeared = try await waitForAssertionCount(baseline + 1)
        XCTAssertTrue(appeared, "A timed session must create a real assertion before expiring.")

        // Yield the main actor so the manager's expiry task can execute.
        for _ in 0..<150 {
            if !manager.isKeepingAwake { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(manager.isKeepingAwake, "The session must expire without a manual Stop.")
        XCTAssertNil(manager.until)
        let released = try await waitForAssertionCount(baseline)
        XCTAssertTrue(released, "Expiry must release the actual IOKit assertion.")
    }

    @MainActor
    func testInvalidReplacementPreservesNativeAssertion() async throws {
        try requireNativeAssertionSupport()
        let baseline = try activeSystemAssertionCount()
        let manager = PowerManager()
        defer { manager.shutdown() }

        manager.start(duration: nil, display: false)
        let appeared = try await waitForAssertionCount(baseline + 1)
        XCTAssertTrue(appeared)

        manager.start(duration: 0, display: false)

        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.isKeepingAwake, "Rejecting a replacement must preserve the existing session.")
        XCTAssertNil(manager.until)
        XCTAssertEqual(try activeSystemAssertionCount(), baseline + 1,
                       "The existing native assertion must remain alive after validation fails.")
    }

    private func requireNativeAssertionSupport() throws {
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Jutilities native test support probe" as CFString,
            &identifier
        )
        guard result == kIOReturnSuccess else {
            throw XCTSkip("This host cannot create native system keep-awake assertions (IOKit status \(result)).")
        }
        IOPMAssertionRelease(identifier)
    }

    private func activeSystemAssertionCount() throws -> Int {
        var copied: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&copied)
        guard result == kIOReturnSuccess else {
            throw XCTSkip("This host cannot inspect native assertions by process (IOKit status \(result)).")
        }
        let dictionary = try XCTUnwrap(copied, "IOKit returned success without assertion data.")
            .takeRetainedValue() as NSDictionary
        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        let assertions = dictionary[pid] as? [NSDictionary] ?? []
        return assertions.filter { assertion in
            assertion[kIOPMAssertionNameKey] as? String == "Jutilities keep awake"
                && assertion[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep
                && (assertion[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn)
        }.count
    }

    @MainActor
    private func waitForAssertionCount(_ expected: Int) async throws -> Bool {
        for _ in 0..<100 {
            if try activeSystemAssertionCount() == expected { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
