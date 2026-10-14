import AppKit
import JutilitiesCore
import XCTest

final class ImageTextRecognitionTests: XCTestCase {
    @MainActor
    func testRecognizesImageTextWithoutChangingOriginalFormats() throws {
        let bitmap = try imageFixture(text: "Jutilities OCR Fixture 4729")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let tiff = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        let representations = [representation(.tiff, tiff), representation(.png, png)]
        let originals = representations

        let text = try ImageTextRecognition.recognize(representations)

        XCTAssertTrue(text.localizedCaseInsensitiveContains("Jutilities"), "Text was: \(text)")
        XCTAssertTrue(text.contains("4729"), "Text was: \(text)")
        XCTAssertEqual(representations, originals, "OCR must leave every original image representation intact.")
    }

    @MainActor
    func testUsesPNGBeforeTIFFWhenBothContainDifferentText() throws {
        let png = try XCTUnwrap(imageFixture(text: "Preferred PNG 5831")
            .representation(using: .png, properties: [:]))
        let tiff = try XCTUnwrap(imageFixture(text: "Alternate TIFF 7902")
            .representation(using: .tiff, properties: [:]))

        let text = try ImageTextRecognition.recognize([
            representation(.tiff, tiff), representation(.png, png)
        ])

        XCTAssertTrue(text.contains("5831"), "Text was: \(text)")
        XCTAssertFalse(text.contains("7902"))
    }

    @MainActor
    func testFallsBackToTIFFWhenPNGIsCorrupt() throws {
        let tiff = try XCTUnwrap(imageFixture(text: "TIFF Fallback 6824")
            .representation(using: .tiff, properties: [:]))

        let text = try ImageTextRecognition.recognize([
            representation(.png, Data("corrupt PNG fixture".utf8)), representation(.tiff, tiff)
        ])

        XCTAssertTrue(text.localizedCaseInsensitiveContains("Fallback"), "Text was: \(text)")
        XCTAssertTrue(text.contains("6824"), "Text was: \(text)")
    }

    @MainActor
    func testImageWithoutTextReturnsCompletedEmptyResult() throws {
        let png = try XCTUnwrap(imageFixture(text: nil).representation(using: .png, properties: [:]))

        XCTAssertEqual(try ImageTextRecognition.recognize([representation(.png, png)]), "")
    }

    func testRejectsMissingInvalidAndURLRepresentations() {
        let cases: [[ClipboardRepresentation]] = [
            [],
            [representation(.png, Data())],
            [representation(.png, Data("invalid PNG".utf8)), representation(.tiff, Data("invalid TIFF".utf8))],
            [representation(.fileURL, Data("file:///not-an-image-file.png".utf8))],
            [representation(.URL, Data("https://example.com/image.png".utf8))]
        ]
        for representations in cases {
            XCTAssertThrowsError(try ImageTextRecognition.recognize(representations)) { error in
                XCTAssertTrue(error is ImageTextRecognitionError)
            }
        }
    }

    func testRecognizedTextRemovesNULAndFitsStorageLimitAtUnicodeBoundaries() {
        let character = "👩🏽‍💻"
        let text = ImageTextRecognition.boundedText([
            " \0Fixture\0 text\n ",
            String(repeating: character, count: 30_000),
            "This part must not fit"
        ])

        XCTAssertTrue(text.hasPrefix("Fixture text\n"))
        XCTAssertFalse(text.contains("\0"))
        XCTAssertLessThanOrEqual(text.utf8.count, 256 * 1024)
        XCTAssertFalse(text.contains("This part must not fit"))
        XCTAssertEqual(text.last.map(String.init), character, "Truncation must preserve a complete composed character.")
        XCTAssertEqual(String(data: Data(text.utf8), encoding: .utf8), text)
    }

    private func representation(_ type: NSPasteboard.PasteboardType, _ data: Data) -> ClipboardRepresentation {
        ClipboardRepresentation(type: type.rawValue, data: data)
    }

    @MainActor
    private func imageFixture(text: String?) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1400, height: 240).fill()
        if let text {
            (text as NSString).draw(at: NSPoint(x: 45, y: 90), withAttributes: [
                .font: NSFont.systemFont(ofSize: 64, weight: .medium),
                .foregroundColor: NSColor.black
            ])
        }
        context.flushGraphics()
        return bitmap
    }
}
