import XCTest
@testable import JutilitiesCore

final class ClipboardActionNavigationTests: XCTestCase {
    func testOpeningSelectsFirstEnabledAction() {
        var navigation = ClipboardActionNavigation()
        navigation.selectFirst(in: [.paste, .copy, .backup])
        XCTAssertEqual(navigation.selectedAction, .paste)
        navigation.selectFirst(in: [.toggleCapture, .backup, .clear])
        XCTAssertEqual(navigation.selectedAction, .toggleCapture)
    }

    func testArrowNavigationSkipsDisabledActionsAndWraps() {
        var navigation = ClipboardActionNavigation()
        let enabled: [ClipboardActionID] = [.paste, .copy, .pin, .delete, .toggleCapture, .backup, .clear]
        navigation.selectFirst(in: enabled)
        navigation.move(1, in: enabled)
        XCTAssertEqual(navigation.selectedAction, .copy)
        navigation.move(1, in: enabled)
        XCTAssertEqual(navigation.selectedAction, .pin)
        navigation.selectLast(in: enabled)
        navigation.move(1, in: enabled)
        XCTAssertEqual(navigation.selectedAction, .paste)
        navigation.move(-1, in: enabled)
        XCTAssertEqual(navigation.selectedAction, .clear)
    }

    func testHoverCannotSelectDisabledAction() {
        var navigation = ClipboardActionNavigation()
        navigation.selectFirst(in: [.paste, .copy, .backup])
        navigation.select(.copyText, in: [.paste, .copy, .backup])
        XCTAssertEqual(navigation.selectedAction, .paste)
        navigation.select(.backup, in: [.paste, .copy, .backup])
        XCTAssertEqual(navigation.selectedAction, .backup)
    }

    func testChangingSelectionReconcilesUnavailableAction() {
        var navigation = ClipboardActionNavigation()
        navigation.select(.airDrop, in: [.paste, .airDrop, .backup])
        navigation.reconcile(with: [.paste, .backup])
        XCTAssertEqual(navigation.selectedAction, .paste)
        navigation.reconcile(with: [.paste, .copy, .backup])
        XCTAssertEqual(navigation.selectedAction, .paste)
        navigation.reconcile(with: [])
        XCTAssertNil(navigation.selectedAction)
    }

    func testArrowNavigationWithNoAvailableActionIsSafe() {
        var navigation = ClipboardActionNavigation()
        navigation.move(1, in: [])
        XCTAssertNil(navigation.selectedAction)
        navigation.move(-1, in: [.backup, .clear])
        XCTAssertEqual(navigation.selectedAction, .clear)
    }
}
