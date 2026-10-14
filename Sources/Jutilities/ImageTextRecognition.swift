import Foundation
import ImageIO
import JutilitiesCore
import UniformTypeIdentifiers
import Vision

/// Recognizes supplied image bytes locally. The original representations are
/// never rewritten, and file URL representations are never followed.
enum ImageTextRecognition {
    static func recognize(_ representations: [ClipboardRepresentation]) throws -> String {
        try autoreleasepool {
            let image = try decodedImage(from: representations)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let supportedLanguages = try request.supportedRecognitionLanguages()
            let preferredLanguages = ["de-DE", "en-US"].filter { supportedLanguages.contains($0) }
            if !preferredLanguages.isEmpty {
                request.recognitionLanguages = preferredLanguages
            }

            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return boundedText((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
        }
    }

    /// Keep SQLite/search input bounded without splitting a Unicode character.
    /// Empty lines and NULs are omitted because OCR output is plain text.
    static func boundedText(_ lines: [String]) -> String {
        let maximumBytes = 256 * 1024
        var text = ""
        var byteCount = 0
        for line in lines {
            let cleanLine = line.replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanLine.isEmpty else { continue }
            if !text.isEmpty {
                guard byteCount < maximumBytes else { return text }
                text.append("\n")
                byteCount += 1
            }
            for character in cleanLine {
                let size = character.utf8.count
                guard size <= maximumBytes - byteCount else {
                    return text.trimmingCharacters(in: .newlines)
                }
                text.append(character)
                byteCount += size
            }
        }
        return text
    }

    private static func decodedImage(from representations: [ClipboardRepresentation]) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary

        for type in [UTType.png, .tiff] {
            for representation in representations where representation.type == type.identifier {
                guard !representation.data.isEmpty,
                      let source = CGImageSourceCreateWithData(representation.data as CFData, sourceOptions),
                      CGImageSourceGetStatus(source) == .statusComplete,
                      CGImageSourceGetCount(source) > 0,
                      let actualType = CGImageSourceGetType(source), actualType as String == type.identifier,
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
                      image.width > 0, image.height > 0,
                      image.width <= 4096, image.height <= 4096 else { continue }
                return image
            }
        }
        throw ImageTextRecognitionError.invalidImage
    }
}

enum ImageTextRecognitionError: Error, LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "Text could not be recognized because the original image could not be opened."
    }
}
