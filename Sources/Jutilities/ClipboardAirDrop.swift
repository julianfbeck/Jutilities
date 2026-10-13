import AppKit
import ImageIO
import UniformTypeIdentifiers
import JutilitiesCore

struct ClipboardAirDropPayload {
    let url: URL
    let temporaryDirectory: URL?

    static var defaultExportRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Jutilities-AirDrop", isDirectory: true)
    }

    static func prepare(kind: ClipboardKind, representations: [ClipboardRepresentation],
                        temporaryRoot: URL = defaultExportRoot) throws -> Self {
        if kind == .link {
            for type in [NSPasteboard.PasteboardType.URL, .string] {
                guard let data = representations.first(where: { $0.type == type.rawValue })?.data,
                      let text = String(data: data, encoding: .utf8),
                      let url = URL(string: text),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host, !host.isEmpty else { continue }
                return Self(url: url, temporaryDirectory: nil)
            }
        }

        let data: Data
        let fileExtension: String
        if kind == .image {
            guard let image = [NSPasteboard.PasteboardType.png, .tiff].compactMap({ type -> (Data, String)? in
                guard let data = representations.first(where: { $0.type == type.rawValue })?.data,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) > 0,
                      CGImageSourceGetStatus(source) == .statusComplete,
                      let actualType = CGImageSourceGetType(source),
                      actualType as String == (type == .png ? UTType.png.identifier : UTType.tiff.identifier)
                else { return nil }
                return (data, type == .png ? "png" : "tiff")
            }).first else { throw ClipboardAirDropError.unsupportedItem }
            (data, fileExtension) = image
        } else {
            // A literal file:// string must never become a URL to someone else's file.
            let plain = [NSPasteboard.PasteboardType.string, .URL].compactMap { type -> Data? in
                guard let data = representations.first(where: { $0.type == type.rawValue })?.data,
                      !data.isEmpty, String(data: data, encoding: .utf8) != nil else { return nil }
                return data
            }.first
            if let plain {
                (data, fileExtension) = (plain, "txt")
            } else if let rich = [NSPasteboard.PasteboardType.rtf, .html].compactMap({ type -> (Data, String)? in
                guard let data = representations.first(where: { $0.type == type.rawValue })?.data,
                      !data.isEmpty else { return nil }
                return (data, type == .rtf ? "rtf" : "html")
            }).first {
                (data, fileExtension) = rich
            } else {
                throw ClipboardAirDropError.unsupportedItem
            }
        }

        let manager = FileManager.default
        try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let rootValues = try temporaryRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ClipboardAirDropError.unavailable
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryRoot.path)
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        do {
            let url = directory.appendingPathComponent("Clipboard.\(fileExtension)")
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return Self(url: url, temporaryDirectory: directory)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    func removeTemporaryFiles() throws {
        if let temporaryDirectory, FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    static func removeStaleExports(in root: URL = defaultExportRoot, now: Date = Date(), excluding: URL? = nil) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let values = try? root.resourceValues(forKeys: keys),
              values.isDirectory == true, values.isSymbolicLink != true,
              let items = try? FileManager.default.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: Array(keys)) else { return }
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for item in items {
            guard item.standardizedFileURL != excluding?.standardizedFileURL,
                  UUID(uuidString: item.lastPathComponent) != nil,
                  let values = try? item.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }
}

enum ClipboardAirDropError: Error {
    case unsupportedItem, unavailable
}

@MainActor
final class ClipboardAirDrop: NSObject, NSSharingServiceDelegate {
    enum Outcome { case shared, cancelled, failed }

    private var service: NSSharingService?
    private var payload: ClipboardAirDropPayload?
    private weak var sourceWindow: NSWindow?
    private var completion: ((Outcome) -> Void)?

    var temporaryDirectory: URL? { payload?.temporaryDirectory }

    func share(_ payload: ClipboardAirDropPayload, from window: NSWindow?, completion: @escaping (Outcome) -> Void) throws {
        guard service == nil,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [payload.url]) else {
            try? payload.removeTemporaryFiles()
            throw ClipboardAirDropError.unavailable
        }
        self.service = service
        self.payload = payload
        self.sourceWindow = window
        self.completion = completion
        service.delegate = self
        service.perform(withItems: [payload.url])
    }

    func stop() {
        service?.delegate = nil
        service = nil
        try? payload?.removeTemporaryFiles()
        payload = nil
        sourceWindow = nil
        completion = nil
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(sharingService, outcome: .shared)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let error = error as NSError
        let cancelled = error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
        finish(sharingService, outcome: cancelled ? .cancelled : .failed)
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        sharingContentScope.pointee = .item
        return sourceWindow
    }

    private func finish(_ sharingService: NSSharingService, outcome: Outcome) {
        guard service === sharingService else { return }
        let callback = completion
        stop()
        callback?(outcome)
    }
}
