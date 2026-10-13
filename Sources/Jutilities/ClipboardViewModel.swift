import AppKit
import Combine
import Foundation
import JutilitiesCore

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var entries: [ClipboardEntry] = [] {
        didSet { reconcileSelection() }
    }
    @Published var query = "" {
        didSet { if query != oldValue { onSearch(query, filter) } }
    }
    @Published var filter: ClipboardKind? {
        didSet { if filter != oldValue { onSearch(query, filter) } }
    }
    @Published var selectedID: String?
    @Published var selectedImage: NSImage?
    @Published var selectedText: String?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isPaused = false
    @Published var isSharingViaAirDrop = false
    @Published var databaseSizeDescription: String?
    var globalShortcutDescription = "⌥V"

    var onSearch: (String, ClipboardKind?) -> Void = { _, _ in }
    var onCopy: (ClipboardEntry, Bool) -> Void = { _, _ in }
    var onAirDrop: (ClipboardEntry) -> Void = { _ in }
    var onPin: (ClipboardEntry) -> Void = { _ in }
    var onDelete: (ClipboardEntry) -> Void = { _ in }
    var onBackup: () -> Void = {}
    var onClear: () -> Void = {}
    var onTogglePause: (Bool) -> Void = { _ in }
    var onSelection: (ClipboardEntry?) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    var selectedEntry: ClipboardEntry? {
        entries.first { $0.id == selectedID }
    }

    var orderedEntries: [ClipboardEntry] {
        entries.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.lastCopiedAt > $1.lastCopiedAt
        }
    }

    func select(_ entry: ClipboardEntry?) {
        guard selectedID != entry?.id else { return }
        selectedID = entry?.id
        selectedImage = nil
        selectedText = nil
        onSelection(entry)
    }

    func refreshSelection() {
        onSelection(selectedEntry)
    }

    func moveSelection(_ direction: Int) {
        let items = orderedEntries
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID }
        let next: Int
        if let current {
            next = min(max(current + direction, 0), items.count - 1)
        } else {
            next = direction < 0 ? items.count - 1 : 0
        }
        select(items[next])
    }

    func copySelection(autoPaste: Bool) {
        guard let entry = selectedEntry else { return }
        onCopy(entry, autoPaste)
    }

    func pinSelection() {
        guard let entry = selectedEntry else { return }
        onPin(entry)
    }

    func airDropSelection() {
        guard let entry = selectedEntry, !isSharingViaAirDrop else { return }
        onAirDrop(entry)
    }

    func deleteSelection() {
        guard let entry = selectedEntry else { return }
        onDelete(entry)
    }

    func togglePause() {
        isPaused.toggle()
        onTogglePause(isPaused)
    }

    private func reconcileSelection() {
        if let selectedID, entries.contains(where: { $0.id == selectedID }) { return }
        select(orderedEntries.first)
    }
}
