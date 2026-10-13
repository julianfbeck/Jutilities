import AppKit
import ImageIO
import JutilitiesCore
import XCTest

final class ClipboardAirDropPayloadTests: XCTestCase {
    func testExportsOriginalUnicodeTextAndNewlines() throws {
        try withTemporaryRoot { root in
            let text = "Grüße 👋\nSecond line\r\n  trailing spaces  \n"
            let original = Data(text.utf8)
            let payload = try ClipboardAirDropPayload.prepare(kind: .text, representations: [
                representation(.string, original),
                representation(.rtf, Data("{\\rtf1 Alternate formatting}".utf8))
            ], temporaryRoot: root)

            XCTAssertTrue(payload.url.isFileURL)
            XCTAssertEqual(payload.url.lastPathComponent, "Clipboard.txt")
            XCTAssertEqual(try Data(contentsOf: payload.url), original)
            XCTAssertEqual(payload.url.deletingLastPathComponent(), try XCTUnwrap(payload.temporaryDirectory))
        }
    }

    func testSharesValidatedWebURLsWithoutCreatingExports() throws {
        try withTemporaryRoot { root in
            for (type, address) in [(NSPasteboard.PasteboardType.URL, "https://example.com/a?query=fixture#section"),
                                    (.string, "http://example.org/clipboard")] {
                let payload = try ClipboardAirDropPayload.prepare(kind: .link, representations: [
                    representation(type, Data(address.utf8))
                ], temporaryRoot: root)

                XCTAssertEqual(payload.url, URL(string: address))
                XCTAssertNil(payload.temporaryDirectory)
                try payload.removeTemporaryFiles()
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Web links do not need local exports.")
            }
        }
    }

    func testLocalFileURLIsSharedAsLiteralTextWithoutReadingReferencedFile() throws {
        try withTemporaryRoot { root in
            let source = root.deletingLastPathComponent().appendingPathComponent("fixture-source.txt")
            let privateContents = Data("Referenced file must never be shared".utf8)
            try privateContents.write(to: source)
            let literal = Data(source.absoluteString.utf8)
            let payload = try ClipboardAirDropPayload.prepare(kind: .link, representations: [
                representation(.URL, literal)
            ], temporaryRoot: root)

            XCTAssertNotEqual(payload.url, source)
            XCTAssertEqual(payload.url.lastPathComponent, "Clipboard.txt")
            XCTAssertEqual(try Data(contentsOf: payload.url), literal)
            XCTAssertEqual(try Data(contentsOf: source), privateContents)
        }
    }

    func testMailtoLinkFallsBackToExactTextFile() throws {
        try withTemporaryRoot { root in
            let literal = Data("mailto:fixture@example.com?subject=Hello".utf8)
            let payload = try ClipboardAirDropPayload.prepare(kind: .link, representations: [
                representation(.URL, literal)
            ], temporaryRoot: root)

            XCTAssertEqual(payload.url.lastPathComponent, "Clipboard.txt")
            XCTAssertEqual(try Data(contentsOf: payload.url), literal)
            XCTAssertNotNil(payload.temporaryDirectory)
        }
    }

    func testRichTextWithoutPlainTextPreservesOriginalFormat() throws {
        try withTemporaryRoot { root in
            let fixtures: [(NSPasteboard.PasteboardType, String, Data)] = [
                (.rtf, "rtf", Data("{\\rtf1\\ansi Fixture \\b text\\b0}".utf8)),
                (.html, "html", Data("<p>Fixture <strong>Grüße</strong></p>\n".utf8))
            ]
            for (type, fileExtension, original) in fixtures {
                let payload = try ClipboardAirDropPayload.prepare(kind: .text, representations: [
                    representation(type, original)
                ], temporaryRoot: root)

                XCTAssertEqual(payload.url.lastPathComponent, "Clipboard.\(fileExtension)")
                XCTAssertEqual(try Data(contentsOf: payload.url), original)
            }
        }
    }

    func testImageExportUsesOriginalPNGAndFullDimensionsWhenTIFFAlsoExists() throws {
        try withTemporaryRoot { root in
            let bitmap = try imageFixture()
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let tiff = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
            let payload = try ClipboardAirDropPayload.prepare(kind: .image, representations: [
                representation(.tiff, tiff), representation(.png, png)
            ], temporaryRoot: root)

            XCTAssertEqual(payload.url.lastPathComponent, "Clipboard.png")
            let exported = try Data(contentsOf: payload.url)
            XCTAssertEqual(exported, png, "Sharing must preserve the original image rather than the preview.")
            let image = try XCTUnwrap(NSBitmapImageRep(data: exported))
            XCTAssertEqual(image.pixelsWide, 64)
            XCTAssertEqual(image.pixelsHigh, 48)
        }
    }

    func testImageExportFallsBackToOriginalTIFFIfPNGIsInvalid() throws {
        try withTemporaryRoot { root in
            let bitmap = try imageFixture()
            let tiff = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
            let payload = try ClipboardAirDropPayload.prepare(kind: .image, representations: [
                representation(.png, Data("not a PNG image".utf8)), representation(.tiff, tiff)
            ], temporaryRoot: root)

            XCTAssertEqual(payload.url.lastPathComponent, "Clipboard.tiff")
            let exported = try Data(contentsOf: payload.url)
            XCTAssertEqual(exported, tiff)
            let image = try XCTUnwrap(NSBitmapImageRep(data: exported))
            XCTAssertEqual(image.pixelsWide, 64)
            XCTAssertEqual(image.pixelsHigh, 48)
        }
    }

    func testRejectsEmptyUnsupportedAndCorruptPayloadsWithoutExporting() throws {
        try withTemporaryRoot { root in
            let cases: [(ClipboardKind, [ClipboardRepresentation])] = [
                (.text, []),
                (.text, [representation(.string, Data())]),
                (.text, [ClipboardRepresentation(type: "com.example.unsupported", data: Data("fixture".utf8))]),
                (.image, [representation(.png, Data("corrupt image".utf8))]),
                (.image, [representation(.png, Data()), representation(.tiff, Data("corrupt TIFF".utf8))])
            ]
            for (kind, representations) in cases {
                XCTAssertThrowsError(try ClipboardAirDropPayload.prepare(kind: kind, representations: representations,
                                                                       temporaryRoot: root))
            }
            if FileManager.default.fileExists(atPath: root.path) {
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                              "Rejected payloads must not leave shareable exports behind.")
            }
        }
    }

    func testExportsArePrivateAndCleanupOnlyRemovesItsOwnRequest() throws {
        try withTemporaryRoot { root in
            let first = try ClipboardAirDropPayload.prepare(kind: .text, representations: [
                representation(.string, Data("First fixture".utf8))
            ], temporaryRoot: root)
            let second = try ClipboardAirDropPayload.prepare(kind: .text, representations: [
                representation(.string, Data("Second fixture".utf8))
            ], temporaryRoot: root)
            let firstDirectory = try XCTUnwrap(first.temporaryDirectory)
            let secondDirectory = try XCTUnwrap(second.temporaryDirectory)

            XCTAssertNotEqual(firstDirectory, secondDirectory)
            XCTAssertNotNil(UUID(uuidString: firstDirectory.lastPathComponent))
            XCTAssertEqual(try permissions(root), 0o700)
            XCTAssertEqual(try permissions(firstDirectory), 0o700)
            XCTAssertEqual(try permissions(first.url), 0o600)

            try first.removeTemporaryFiles()

            XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory.path))
            XCTAssertEqual(try Data(contentsOf: second.url), Data("Second fixture".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testStaleCleanupKeepsRecentActiveUnrelatedAndSymlinkedItems() throws {
        try withTemporaryRoot { root in
            let manager = FileManager.default
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let old = now.addingTimeInterval(-25 * 60 * 60)
            let recent = now.addingTimeInterval(-23 * 60 * 60)
            let stale = try directoryFixture(in: root, name: UUID().uuidString, modifiedAt: old)
            let active = try directoryFixture(in: root, name: UUID().uuidString, modifiedAt: old)
            let fresh = try directoryFixture(in: root, name: UUID().uuidString, modifiedAt: recent)
            let unrelated = try directoryFixture(in: root, name: "unrelated", modifiedAt: old)
            let ordinaryFile = root.appendingPathComponent(UUID().uuidString)
            try Data("Unrelated file fixture".utf8).write(to: ordinaryFile)
            try manager.setAttributes([.modificationDate: old], ofItemAtPath: ordinaryFile.path)
            let outside = try directoryFixture(in: root.deletingLastPathComponent(), name: "outside", modifiedAt: old)
            let symlink = root.appendingPathComponent(UUID().uuidString)
            try manager.createSymbolicLink(at: symlink, withDestinationURL: outside)

            ClipboardAirDropPayload.removeStaleExports(in: root, now: now, excluding: active)

            XCTAssertFalse(manager.fileExists(atPath: stale.path))
            for retained in [active, fresh, unrelated, ordinaryFile, outside] {
                XCTAssertTrue(manager.fileExists(atPath: retained.path), "Cleanup must preserve \(retained.lastPathComponent).")
            }
            XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: symlink.path), outside.path)
            XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("fixture.txt")), Data("Fixture export".utf8))
        }
    }

    private func representation(_ type: NSPasteboard.PasteboardType, _ data: Data) -> ClipboardRepresentation {
        ClipboardRepresentation(type: type.rawValue, data: data)
    }

    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("JutilitiesAirDropTests-\(UUID().uuidString)",
                                                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try body(container.appendingPathComponent("exports", isDirectory: true))
    }

    private func imageFixture() throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<64 {
            for y in 0..<48 {
                let level = CGFloat((x + y) % 2)
                bitmap.setColor(NSColor(deviceRed: level, green: level, blue: level, alpha: 1), atX: x, y: y)
            }
        }
        return bitmap
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try XCTUnwrap(value as? NSNumber).intValue
    }

    private func directoryFixture(in parent: URL, name: String, modifiedAt: Date) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Fixture export".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: directory.path)
        return directory
    }
}
