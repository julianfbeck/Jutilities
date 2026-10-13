import AppKit
import JutilitiesCore
import XCTest

final class PasteboardMonitorTests: XCTestCase {
    @MainActor
    func testCapturesNewTextFromIsolatedPasteboardOnce() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("JutilitiesTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let monitor = PasteboardMonitor(pasteboard: board, frontmostApplication: { nil })
        var captures: [ClipboardCapture] = []
        monitor.onCapture = { captures.append($0) }

        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("Ordinary test content", forType: .string))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))

        monitor.poll()
        monitor.poll()

        let capture = try XCTUnwrap(captures.first)
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(capture.kind, .text)
        XCTAssertEqual(capture.text, "Ordinary test content")
        XCTAssertEqual(capture.representations, [
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue,
                                    data: Data("Ordinary test content".utf8))
        ])
    }

    @MainActor
    func testDiscardsCaptureWhenPromisedDataReplacesClipboardWithConcealedText() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("JutilitiesTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let monitor = PasteboardMonitor(pasteboard: board, frontmostApplication: { nil })
        var captures: [ClipboardCapture] = []
        monitor.onCapture = { captures.append($0) }
        let provider = ConcealedReplacementProvider(board: board)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("Original ordinary content", forType: .string))
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.rtf]))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))

        monitor.poll()

        XCTAssertTrue(provider.wasInvoked, "The test must exercise a replacement during promised-data capture.")
        XCTAssertTrue(provider.replacementSucceeded)
        XCTAssertTrue(captures.isEmpty, "A changed clipboard generation must discard the entire capture.")

        monitor.poll()
        XCTAssertTrue(captures.isEmpty, "The replacement concealed content must also remain excluded.")
    }
}

private final class ConcealedReplacementProvider: NSObject, NSPasteboardItemDataProvider {
    private let board: NSPasteboard
    private(set) var wasInvoked = false
    private(set) var replacementSucceeded = false

    init(board: NSPasteboard) {
        self.board = board
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        wasInvoked = true
        item.setData(Data("{\\rtf1 Original ordinary content}".utf8), forType: type)
        let replacement = NSPasteboardItem()
        replacement.setString("Synthetic concealed test content", forType: .string)
        replacement.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.clearContents()
        replacementSucceeded = board.writeObjects([replacement])
    }
}
