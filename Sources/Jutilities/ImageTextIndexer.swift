import Foundation
import JutilitiesCore

/// Recognize one image at a time without blocking clipboard capture or searches.
@MainActor
final class ImageTextIndexer {
    var onChange: () -> Void = {}
    private let store: ClipboardStore
    private let storageQueue: DispatchQueue
    private let recognitionQueue = DispatchQueue(label: "sh.juli.Jutilities.ocr", qos: .utility)
    private let recognize: ([ClipboardRepresentation]) throws -> String
    private var generation = 0
    private var isRunning = false
    private var needsAnotherPass = false
    private var failures: [String: String] = [:]
    private var preparationError: String?

    init(store: ClipboardStore, storageQueue: DispatchQueue,
         recognize: @escaping ([ClipboardRepresentation]) throws -> String = ImageTextRecognition.recognize) {
        self.store = store
        self.storageQueue = storageQueue
        self.recognize = recognize
    }

    func error(for id: String) -> String? { failures[id] ?? preparationError }

    func start() {
        guard !isRunning else { needsAnotherPass = true; return }
        isRunning = true
        needsAnotherPass = false
        preparationError = nil
        let token = generation
        let excluded = Set(failures.keys)
        let store = store
        storageQueue.async { [weak self] in
            let result = Result { () -> (ClipboardEntry, [ClipboardRepresentation])? in
                guard let entry = try store.imagesNeedingRecognition(limit: 1, excludingIDs: excluded).first else { return nil }
                return (entry, try store.representations(for: entry.id))
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let item):
                    guard let (entry, representations) = item else {
                        self.isRunning = false
                        if self.needsAnotherPass { self.start() }
                        return
                    }
                    self.process(entry, representations: representations, token: token)
                case .failure:
                    self.isRunning = false
                    self.preparationError = "Could not read images for text recognition. Try again."
                    self.onChange()
                }
            }
        }
    }

    func retry(id: String) {
        failures.removeValue(forKey: id)
        preparationError = nil
        onChange()
        start()
    }

    /// In-flight results from the previous history must not write into a restore.
    func invalidate() {
        generation += 1
        isRunning = false
        needsAnotherPass = false
        failures.removeAll()
        preparationError = nil
    }

    private func process(_ entry: ClipboardEntry, representations: [ClipboardRepresentation], token: Int) {
        let recognize = recognize
        recognitionQueue.async { [weak self] in
            let result = autoreleasepool { Result { try recognize(representations) } }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let text): self.save(text, for: entry.id, token: token)
                case .failure:
                    self.failures[entry.id] = "Could not recognize text in this image. Try again."
                    self.finished(token: token)
                }
            }
        }
    }

    private func save(_ text: String, for id: String, token: Int) {
        let store = store
        storageQueue.async { [weak self] in
            let result = Result { try store.setRecognizedText(text, for: id) }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if case .failure = result {
                    self.failures[id] = "Could not save recognized text. Try again."
                }
                self.finished(token: token)
            }
        }
    }

    private func finished(token: Int) {
        guard generation == token else { return }
        isRunning = false
        onChange()
        start()
    }
}
