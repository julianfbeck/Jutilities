import Foundation
import XCTest
@testable import JutilitiesCore

final class PowerSettingsTests: XCTestCase {
    func testParsesExactSettingsWithAssertionSuffix() {
        let snapshot = PowerSettingsSnapshot.parsePMSet("""
        System-wide power settings:
          Sleep On Power Button 1
        Currently in use:
          sleep 0 (sleep prevented by powerd)
          displaysleep 20
          disksleep 10
          standby 1
        """)
        XCTAssertEqual(snapshot.systemSleepMinutes, 0)
        XCTAssertEqual(snapshot.displaySleepMinutes, 20)
    }

    func testMalformedOrMissingValuesStayUnknown() {
        let snapshot = PowerSettingsSnapshot.parsePMSet("sleep -1\ndisplaysleep unknown\nSleep 10")
        XCTAssertNil(snapshot.systemSleepMinutes)
        XCTAssertNil(snapshot.displaySleepMinutes)
    }

    func testUnchangedSettingsProduceNoWrites() throws {
        let current = PowerSettingsSnapshot(systemSleepMinutes: 0, displaySleepMinutes: 0, screenSaverIdleSeconds: 0)
        let draft = PowerSettingsDraft(systemSleepMinutes: 0, displaySleepMinutes: 0, screenSaverIdleSeconds: 0)
        let plan = try PowerSettingsPlan(current: current, draft: draft)
        XCTAssertFalse(plan.hasChanges)
        XCTAssertNil(plan.privilegedCommand)
    }

    func testOnlyChangedAndSelectedSettingsAppearInCommand() throws {
        let current = PowerSettingsSnapshot(systemSleepMinutes: 0, displaySleepMinutes: 0)
        let plan = try PowerSettingsPlan(current: current, draft: .init(displaySleepMinutes: 30))
        XCTAssertEqual(plan.privilegedCommand, "/usr/bin/pmset -a displaysleep 30")
        XCTAssertNil(plan.screenSaverIdleSeconds)
    }

    func testValidBoundariesAndScreenSaverUnits() throws {
        let plan = try PowerSettingsPlan(current: .init(), draft: .init(systemSleepMinutes: 1440, displaySleepMinutes: 0, screenSaverIdleSeconds: 900))
        XCTAssertEqual(plan.pmsetArguments, ["-a", "sleep", "1440", "displaysleep", "0"])
        XCTAssertEqual(plan.screenSaverIdleSeconds, 900)
    }

    func testInvalidValuesCannotReachPrivilegedCommand() {
        for value in [-1, 1441, Int.max] {
            XCTAssertThrowsError(try PowerSettingsPlan(current: .init(), draft: .init(systemSleepMinutes: value)))
            XCTAssertThrowsError(try PowerSettingsPlan(current: .init(), draft: .init(displaySleepMinutes: value)))
        }
        XCTAssertThrowsError(try PowerSettingsPlan(current: .init(), draft: .init(screenSaverIdleSeconds: -1)))
        XCTAssertThrowsError(try PowerSettingsPlan(current: .init(), draft: .init(screenSaverIdleSeconds: 86401)))
    }

    func testTimedAndIndefiniteSessions() throws {
        let start = Date(timeIntervalSince1970: 100)
        for seconds in [900.0, 1800.0, 3600.0, 7200.0] {
            let plan = try PowerSessionPlan(duration: seconds, display: true)
            XCTAssertEqual(plan.endDate(from: start), start.addingTimeInterval(seconds))
            XCTAssertFalse(plan.hasExpired(startedAt: start, now: start.addingTimeInterval(seconds - 1)))
            XCTAssertTrue(plan.hasExpired(startedAt: start, now: start.addingTimeInterval(seconds)))
        }
        let forever = try PowerSessionPlan(duration: nil, display: false)
        XCTAssertNil(forever.endDate(from: start))
        XCTAssertFalse(forever.hasExpired(startedAt: start, now: .distantFuture))
    }

    func testInvalidDurationsAreRejected() {
        for duration in [0.0, -1.0, Double.infinity, Double.nan, 86401.0] {
            XCTAssertThrowsError(try PowerSessionPlan(duration: duration, display: false))
        }
    }

    func testLockStatusAndCredentialFreeCommandPlan() {
        XCTAssertEqual(PowerLockSetting.parseStatus("sysadminctl[123]: screenLock is off"), .never)
        XCTAssertEqual(PowerLockSetting.parseStatus("screenLock delay is immediate"), .immediately)
        XCTAssertEqual(PowerLockSetting.parseStatus("screenLock delay is 300 seconds"), .after(seconds: 300))
        XCTAssertNil(PowerLockSetting.parseStatus("Unknown state for screenLock"))
        XCTAssertNil(PowerLockSetting.parseStatus("screenLock delay is -1 seconds"))
        XCTAssertEqual(PowerLockSetting.never.interactiveArguments, ["-q", "/dev/null", "/usr/sbin/sysadminctl", "-screenLock", "off", "-password", "-"])
        XCTAssertNil(PowerLockSetting.after(seconds: -1).interactiveArguments)
        XCTAssertNil(PowerLockSetting.after(seconds: 28801).interactiveArguments)
    }
}
