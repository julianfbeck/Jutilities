import XCTest

@MainActor
final class PasteAutomationTests: XCTestCase {
    private final class Fixture {
        var permission = PastePermissionStatus(accessibilityTrusted: true, canPostEvents: true)
        var changeCount = 42
        var running = true
        var activationSucceeds = true
        var current = true
        var frontmost: pid_t? = 10
        var pauseCount = 0
        var activationCount = 0
        var posted = 0
        var eventCreationSucceeds = true
        var onPause: (Fixture) -> Void = { _ in }

        var environment: PasteAutomation.Environment {
            PasteAutomation.Environment(
                permission: { self.permission },
                clipboardChangeCount: { self.changeCount },
                activate: { _ in self.activationCount += 1; return self.activationSucceeds },
                isRunning: { _ in self.running },
                frontmostPID: { self.frontmost },
                postPaste: { self.posted += 1; return self.eventCreationSucceeds },
                pause: { self.pauseCount += 1; self.onPause(self) }
            )
        }

        func run() async -> PasteAutomation.Outcome {
            await PasteAutomation(environment: environment)
                .paste(into: 20, clipboardChangeCount: 42, operationIsCurrent: { self.current })
        }
    }

    func testMissingPermissionNeverActivatesOrPosts() async {
        let fixture = Fixture()
        fixture.permission = PastePermissionStatus(accessibilityTrusted: false, canPostEvents: false)
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .permissionRequired)
        XCTAssertEqual(fixture.activationCount, 0)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testEventPostingPermissionIsCheckedSeparately() async {
        let fixture = Fixture()
        fixture.permission = PastePermissionStatus(accessibilityTrusted: true, canPostEvents: false)
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .permissionRequired)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testSlowActivationWaitsForStableFocusThenPostsOnce() async {
        let fixture = Fixture()
        fixture.onPause = { if $0.pauseCount == 10 { $0.frontmost = 20 } }
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(fixture.pauseCount, 11)
        XCTAssertEqual(fixture.posted, 1)
    }

    func testFocusNeverRestoredStopsAfterBoundedWait() async {
        let fixture = Fixture()
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .focusNotRestored)
        XCTAssertEqual(fixture.pauseCount, 25)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testSwitchingToAnotherAppCancelsRatherThanPastingThere() async {
        let fixture = Fixture()
        fixture.onPause = { $0.frontmost = 30 }
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .focusChanged)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testLosingFocusAfterActivationCancels() async {
        let fixture = Fixture()
        fixture.frontmost = 20
        fixture.onPause = { $0.frontmost = 10 }
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .focusChanged)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testNewClipboardContentCancelsPendingPaste() async {
        let fixture = Fixture()
        fixture.onPause = { $0.changeCount += 1; $0.frontmost = 20 }
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testNewRequestCancelsPendingPaste() async {
        let fixture = Fixture()
        fixture.onPause = { $0.current = false; $0.frontmost = 20 }
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testPermissionRevokedDuringActivationNeverPosts() async {
        let fixture = Fixture()
        fixture.frontmost = 20
        fixture.onPause = {
            $0.permission = PastePermissionStatus(accessibilityTrusted: false, canPostEvents: false)
        }
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .permissionRequired)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testUnavailableDestinationDoesNotActivate() async {
        let fixture = Fixture()
        fixture.running = false
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .targetUnavailable)
        XCTAssertEqual(fixture.activationCount, 0)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testFailedActivationDoesNotPost() async {
        let fixture = Fixture()
        fixture.activationSucceeds = false
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .activationFailed)
        XCTAssertEqual(fixture.posted, 0)
    }

    func testEventCreationFailureIsNotReportedAsPaste() async {
        let fixture = Fixture()
        fixture.frontmost = 20
        fixture.eventCreationSucceeds = false
        let outcome = await fixture.run()
        XCTAssertEqual(outcome, .eventCreationFailed)
    }
}
