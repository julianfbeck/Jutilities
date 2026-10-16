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

final class PastePermissionDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func identity(version: String = "0.2.0", hash: String? = "fixture-executable-hash") -> PastePermissionDiagnostics.Identity {
        PastePermissionDiagnostics.Identity(bundleIdentifier: "test.Jutilities",
                                            executablePath: "/Applications/Jutilities.app/Contents/MacOS/Jutilities",
                                            version: version, build: "2", executableSHA256: hash)
    }

    private func record(age: TimeInterval = 0) -> PastePermissionDiagnostics.Record {
        PastePermissionDiagnostics.Record(recordedAt: now.addingTimeInterval(-age), processIdentifier: 123,
                                          processLaunchDate: now.addingTimeInterval(-600), identity: identity(),
                                          accessibilityTrusted: false, canPostEvents: true,
                                          automaticPasteAvailable: false)
    }

    private func liveProcess(launchOffset: TimeInterval = -600,
                             bundle: String? = "test.Jutilities",
                             path: String? = "/Applications/Jutilities.app/Contents/MacOS/Jutilities") -> PastePermissionDiagnostics.LiveProcess {
        PastePermissionDiagnostics.LiveProcess(processIdentifier: 123,
                                               launchDate: now.addingTimeInterval(launchOffset),
                                               bundleIdentifier: bundle, executablePath: path)
    }

    func testCurrentLiveGUIReportKeepsSeparatePermissionValues() {
        let result = PastePermissionDiagnostics.validate(record(), expectedIdentity: identity(),
                                                        liveProcess: liveProcess(), now: now)
        XCTAssertEqual(result.state, .valid)
        XCTAssertEqual(result.report?.accessibilityTrusted, false)
        XCTAssertEqual(result.report?.canPostEvents, true)
        XCTAssertEqual(result.report?.automaticPasteAvailable, false)
    }

    func testStaleGUIReportIsNotPresentedAsCurrentPermission() {
        let result = PastePermissionDiagnostics.validate(record(age: 301), expectedIdentity: identity(),
                                                        liveProcess: liveProcess(), now: now)
        XCTAssertEqual(result.state, .stale)
        XCTAssertNil(result.report)
    }

    func testFutureDatedReportIsRejected() {
        let result = PastePermissionDiagnostics.validate(record(age: -10), expectedIdentity: identity(),
                                                        liveProcess: liveProcess(), now: now)
        XCTAssertEqual(result.state, .stale)
        XCTAssertNil(result.report)
    }

    func testExitedGUIProcessIsRejected() {
        let result = PastePermissionDiagnostics.validate(record(), expectedIdentity: identity(),
                                                        liveProcess: nil, now: now)
        XCTAssertEqual(result.state, .notRunning)
        XCTAssertNil(result.report)
    }

    func testReusedProcessIdentifierIsRejected() {
        let result = PastePermissionDiagnostics.validate(record(), expectedIdentity: identity(),
                                                        liveProcess: liveProcess(launchOffset: -20), now: now)
        XCTAssertEqual(result.state, .identityMismatch)
        XCTAssertNil(result.report)
    }

    func testOtherApplicationWithSamePIDIsRejected() {
        let result = PastePermissionDiagnostics.validate(record(), expectedIdentity: identity(),
                                                        liveProcess: liveProcess(bundle: "another.app"), now: now)
        XCTAssertEqual(result.state, .identityMismatch)
        XCTAssertNil(result.report)
    }

    func testDifferentInstalledLocationIsRejected() {
        let result = PastePermissionDiagnostics.validate(record(), expectedIdentity: identity(),
                                                        liveProcess: liveProcess(path: "/tmp/Jutilities"), now: now)
        XCTAssertEqual(result.state, .identityMismatch)
        XCTAssertNil(result.report)
    }

    func testReplacedExecutableWithSameVersionIsRejected() {
        let result = PastePermissionDiagnostics.validate(record(), expectedIdentity: identity(hash: "new-binary"),
                                                        liveProcess: liveProcess(), now: now)
        XCTAssertEqual(result.state, .identityMismatch)
        XCTAssertNil(result.report)
    }

    func testMissingExecutableFingerprintCannotValidateGUIIdentity() {
        let result = PastePermissionDiagnostics.validate(record(), expectedIdentity: identity(hash: nil),
                                                        liveProcess: liveProcess(), now: now)
        XCTAssertEqual(result.state, .identityMismatch)
        XCTAssertNil(result.report)
    }

    func testDiagnosticMetadataHasPrivateDirectoryAndFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Jutilities-Permission-Fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("permission-status.json")
        try PastePermissionDiagnostics.write(record(), to: url)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let saved = try decoder.decode(PastePermissionDiagnostics.Record.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.processIdentifier, 123)
        XCTAssertEqual(saved.identity, identity())
    }
}
