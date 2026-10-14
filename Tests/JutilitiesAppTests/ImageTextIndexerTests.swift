import Foundation
import JutilitiesCore
import XCTest

final class ImageTextIndexerTests: XCTestCase {
    @MainActor
    func testFailedImageDoesNotPreventLaterImagesFromBeingIndexed() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let later = try store.insert(image(2), now: Date().addingTimeInterval(-60))
        let failing = try store.insert(image(1))
        let indexed = expectation(description: "The next pending image is indexed after a recognition failure")
        let indexer = ImageTextIndexer(store: store, storageQueue: DispatchQueue(label: "JutilitiesIndexerTests.storage")) {
            representations in
            if representations.first?.data.first == 1 { throw FixtureError.recognition }
            return "Surviving image text"
        }
        var didFinish = false
        indexer.onChange = {
            if !didFinish, (try? store.recognizedText(for: later.id)) == "Surviving image text" {
                didFinish = true
                indexed.fulfill()
            }
        }
        defer { indexer.invalidate(); indexer.onChange = {} }

        indexer.start()
        await fulfillment(of: [indexed], timeout: 5)

        XCTAssertNotNil(indexer.error(for: failing.id))
        XCTAssertNil(indexer.error(for: later.id))
        XCTAssertNil(try store.recognizedText(for: failing.id))
        XCTAssertEqual(try store.recognizedText(for: later.id), "Surviving image text")
        XCTAssertEqual(try store.imagesNeedingRecognition(limit: 10).map(\.id), [failing.id])
    }

    @MainActor
    func testRetryRunsRecognizerAgainAndClearsFailureAfterSuccess() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let entry = try store.insert(image(1))
        let attempts = AttemptCounter()
        let failed = expectation(description: "Initial recognition fails")
        let indexed = expectation(description: "Explicit retry succeeds")
        let indexer = ImageTextIndexer(store: store, storageQueue: DispatchQueue(label: "JutilitiesIndexerTests.storage")) {
            _ in
            if attempts.next() == 1 { throw FixtureError.recognition }
            return "Recovered image text"
        }
        var didReportFailure = false
        var didFinish = false
        indexer.onChange = { [weak indexer] in
            if !didReportFailure, indexer?.error(for: entry.id) != nil {
                didReportFailure = true
                failed.fulfill()
            }
            if !didFinish, (try? store.recognizedText(for: entry.id)) == "Recovered image text" {
                didFinish = true
                indexed.fulfill()
            }
        }
        defer { indexer.invalidate(); indexer.onChange = {} }

        indexer.start()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertNil(try store.recognizedText(for: entry.id))

        indexer.retry(id: entry.id)
        await fulfillment(of: [indexed], timeout: 5)

        XCTAssertNil(indexer.error(for: entry.id))
        XCTAssertEqual(try store.recognizedText(for: entry.id), "Recovered image text")
        XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(try store.imagesNeedingRecognition().isEmpty)
    }

    @MainActor
    func testInvalidateDuringRecognitionDiscardsStaleResultWithoutBlockingMainActor() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let entry = try store.insert(image(1))
        let began = expectation(description: "Recognition is running away from the main thread")
        let completed = expectation(description: "Blocked recognition returns after invalidation")
        let unexpectedChange = expectation(description: "Stale recognition must not notify or save")
        unexpectedChange.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let indexer = ImageTextIndexer(store: store, storageQueue: DispatchQueue(label: "JutilitiesIndexerTests.storage")) {
            _ in
            XCTAssertFalse(Thread.isMainThread, "The synchronous recognizer must not block the main actor.")
            began.fulfill()
            defer { completed.fulfill() }
            guard release.wait(timeout: .now() + 5) == .success else {
                XCTFail("The main actor must remain responsive enough to release recognition.")
                throw FixtureError.timeout
            }
            return "Stale text that must never persist"
        }
        indexer.onChange = { unexpectedChange.fulfill() }
        defer { release.signal(); indexer.invalidate(); indexer.onChange = {} }

        indexer.start()
        await fulfillment(of: [began], timeout: 2)
        // This executes on the main actor while the synchronous recognizer is
        // still blocked. A restore or clear can therefore invalidate its work.
        indexer.invalidate()
        release.signal()
        await fulfillment(of: [completed, unexpectedChange], timeout: 1)

        XCTAssertNil(try store.recognizedText(for: entry.id))
        XCTAssertEqual(try store.imagesNeedingRecognition().map(\.id), [entry.id])
        XCTAssertEqual(try store.entries(search: "Stale text"), [])
        XCTAssertNil(indexer.error(for: entry.id))
    }

    private func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("JutilitiesIndexerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func image(_ identifier: UInt8) -> ClipboardCapture {
        ClipboardCapture(kind: .image, title: "Synthetic image \(identifier)", text: nil,
                         sourceApp: "Tests", sourceBundleID: "dev.jutilities.tests",
                         representations: [.init(type: "public.png", data: Data([identifier, 2, 3]))],
                         imageWidth: 80, imageHeight: 40)
    }

    private enum FixtureError: Error { case recognition, timeout }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
