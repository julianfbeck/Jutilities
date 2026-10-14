import Foundation

public enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case text
    case link
    case image
}

/// One original pasteboard representation. Keeping the type and bytes lets a
/// restored image retain formats such as PNG, TIFF, and its original source UTI.
public struct ClipboardRepresentation: Codable, Sendable, Equatable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public struct ClipboardCapture: Sendable {
    public let kind: ClipboardKind
    public let title: String
    public let text: String?
    public let sourceApp: String
    public let sourceBundleID: String?
    public let representations: [ClipboardRepresentation]
    public let thumbnail: Data?
    public let imageWidth: Int?
    public let imageHeight: Int?

    public init(
        kind: ClipboardKind,
        title: String,
        text: String?,
        sourceApp: String,
        sourceBundleID: String?,
        representations: [ClipboardRepresentation],
        thumbnail: Data? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) {
        self.kind = kind
        self.title = title
        self.text = text
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.representations = representations
        self.thumbnail = thumbnail
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

public struct ClipboardEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: ClipboardKind
    public let title: String
    public let previewText: String?
    public let sourceApp: String
    public let sourceBundleID: String?
    public let createdAt: Date
    public let lastCopiedAt: Date
    public let isPinned: Bool
    public let thumbnail: Data?
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let byteCount: Int
    /// On-device image text. nil is pending; an empty string is a completed
    /// recognition request that found no text. Original image formats stay intact.
    public let recognizedText: String?
}

public enum ClipboardStoreError: Error, LocalizedError, Sendable {
    case invalidLocation
    case invalidCapture(String)
    case database(String)
    case unsupportedSchema(Int)
    case missingEntry

    public var errorDescription: String? {
        switch self {
        case .invalidLocation:
            return "Clipboard storage requires a local file URL."
        case .invalidCapture(let reason):
            return "This clipboard item could not be stored: \(reason)"
        case .database(let message):
            return "Clipboard storage error: \(message)"
        case .unsupportedSchema(let version):
            return "This clipboard database uses an unsupported version (\(version))."
        case .missingEntry:
            return "This clipboard item no longer exists."
        }
    }
}
