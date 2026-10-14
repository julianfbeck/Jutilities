import AppKit
import Combine
import ImageIO
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import JutilitiesCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = ClipboardViewModel()
    private let menuState = UtilityMenuState()
    private let monitor = PasteboardMonitor()
    private let hotKey = GlobalHotKey()
    private let airDrop = ClipboardAirDrop()
    private let dataQueue = DispatchQueue(label: "sh.juli.Jutilities.storage", qos: .userInitiated)
    private var store: ClipboardStore?
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var previewMenuPanel: NSPanel?
    private var popover: NSPopover?
    private var menuResize: DispatchWorkItem?
    private var maintenanceTimer: Timer?
    private var previousApplication: NSRunningApplication?
    private var searchGeneration = 0
    private var pasteGeneration = 0
    private var subscriptions = Set<AnyCancellable>()
    private let isPreview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-menu")
    private lazy var power = PowerManager(isPreview: isPreview)
    private var backupURL: URL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = BrandIcon.image(size: 256)
        model.globalShortcutDescription = "⌥V"
        wireCallbacks()
        installMenuBar()
        do {
            let directory: URL
            if isPreview {
                directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Jutilities-Preview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            } else {
                directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                        in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("Jutilities", isDirectory: true)
            }
            backupURL = directory.appendingPathComponent("Backups/clipboard-backup.sqlite")
            store = try ClipboardStore(databaseURL: directory.appendingPathComponent("clipboard.sqlite"))
            if isPreview { try seedPreview() }
            reload()
            if !isPreview {
                if CommandLine.arguments.contains("--enable-login") {
                    do { try SMAppService.mainApp.register() }
                    catch { model.statusMessage = "Enable Open Jutilities at login from the JU menu: \(error.localizedDescription)" }
                }
                monitor.start()
                maintenance()
                maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.maintenance() }
                }
                if !hotKey.register(action: { [weak self] in self?.showClipboard() }) {
                    model.errorMessage = "⌥V is already in use. Open Clipboard History from the JU menu bar icon."
                }
            }
            // The first launch shows the empty panel and documents the shortcut.
            if isPreview || !UserDefaults.standard.bool(forKey: "hasLaunched") {
                if CommandLine.arguments.contains("--preview-menu") { togglePopover() }
                else { showClipboard() }
                if !isPreview { UserDefaults.standard.set(true, forKey: "hasLaunched") }
            }
            if !isPreview, !AXIsProcessTrusted(),
               !UserDefaults.standard.bool(forKey: "hasOfferedAutomaticPaste") {
                UserDefaults.standard.set(true, forKey: "hasOfferedAutomaticPaste")
                DispatchQueue.main.async { [weak self] in self?.showAccessibilityHelp() }
            }
        } catch {
            model.errorMessage = error.localizedDescription
            showClipboard()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        hotKey.unregister()
        maintenanceTimer?.invalidate()
        power.stop()
        airDrop.stop()
        if let store, let backupURL, !isPreview {
            dataQueue.sync { try? store.backup(to: backupURL) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showClipboard()
        return true
    }

    private func wireCallbacks() {
        model.onSearch = { [weak self] _, _ in self?.reload() }
        model.onSelection = { [weak self] entry in self?.loadPreview(entry) }
        model.onDismiss = { [weak self] in self?.panel?.orderOut(nil) }
        model.onCopy = { [weak self] entry, autoPaste in self?.copy(entry, autoPaste: autoPaste) }
        model.onAirDrop = { [weak self] entry in self?.shareViaAirDrop(entry) }
        model.onPin = { [weak self] entry in
            self?.mutate { try $0.setPinned(id: entry.id, pinned: !entry.isPinned) }
        }
        model.onDelete = { [weak self] entry in self?.mutate { try $0.delete(id: entry.id) } }
        model.onClear = { [weak self] in self?.mutate { try $0.clear() } }
        model.onBackup = { [weak self] in self?.exportBackup() }
        model.onTogglePause = { [weak self] value in self?.monitor.isPaused = value }
        monitor.onCapture = { [weak self] capture in
            guard let self, let store = self.store else { return }
            dataQueue.async { [weak self] in
                do {
                    _ = try store.insert(capture)
                    Task { @MainActor [weak self] in self?.reload() }
                } catch { Task { @MainActor [weak self] in self?.model.errorMessage = error.localizedDescription } }
            }
        }
        monitor.onError = { [weak self] text in self?.model.statusMessage = text }
    }

    private func installMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "Jutilities · Clipboard and power controls"
        statusItem = item
        power.$isKeepingAwake.sink { [weak self] active in
            guard let button = self?.statusItem?.button else { return }
            button.image = BrandIcon.menuBarImage(keepingAwake: active)
            let description = "Jutilities · Clipboard and power controls · Keep awake \(active ? "on" : "off")"
            button.toolTip = description
            button.setAccessibilityLabel(description)
        }.store(in: &subscriptions)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown { popover.performClose(nil); return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            previousApplication = front
        }
        if !power.hasPendingChanges { power.refreshSettings() }
        let popup = NSPopover()
        let screen = button.window?.screen ?? NSScreen.main
        let maximumHeight = min(JutilitiesLayout.menuMaximumHeight,
                                max(0, (screen?.visibleFrame.height ?? JutilitiesLayout.menuMaximumHeight) - 24))
        let view = UtilityMenuView(model: model, power: power, menuState: menuState, isPreview: isPreview,
                                   maximumHeight: maximumHeight,
                                   resize: { [weak self, weak popup] size in
                                       guard let popup else { return }
                                       self?.resizeUtilityMenu(popup, to: size)
                                   },
                                   openClipboard: { [weak self] in self?.showClipboard() },
                                   restoreBackup: { [weak self] in self?.restoreBackup() },
                                   openStorage: { [weak self] in
                                       self?.dismissUtilityMenu()
                                       guard let url = self?.store?.databaseURL.deletingLastPathComponent() else { return }
                                       NSWorkspace.shared.open(url)
                                   },
                                   dismiss: { [weak self] in self?.dismissUtilityMenu() },
                                   quit: { NSApp.terminate(nil) })
        popup.appearance = NSAppearance(named: .darkAqua)
        popup.behavior = .transient
        popup.contentViewController = NSHostingController(rootView: view)
        let initialSize = NSSize(width: JutilitiesLayout.menuWidth, height: min(440, maximumHeight))
        popup.contentSize = initialSize
        menuResize?.cancel()
        popover = popup
        if CommandLine.arguments.contains("--preview-menu") {
            // Preview the same menu content in a regular window so it remains
            // inspectable when this fixture app is not the active menu-bar owner.
            let window = LauncherPanel(contentRect: NSRect(origin: .zero, size: initialSize),
                                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Jutilities — Utilities Preview"
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentViewController = popup.contentViewController
            window.isReleasedWhenClosed = false
            window.center()
            previewMenuPanel = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        popup.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popup.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizeUtilityMenu(_ popup: NSPopover, to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let size = NSSize(width: ceil(size.width), height: ceil(size.height))
        menuResize?.cancel()
        // Defer AppKit changes until SwiftUI finishes layout and coalesce its measurements.
        let work = DispatchWorkItem { [weak self, weak popup] in
            guard let self, let popup, self.popover === popup else { return }
            if let window = self.previewMenuPanel,
               window.contentViewController === popup.contentViewController {
                guard window.contentLayoutRect.size != size else { return }
                var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
                if let screen = window.screen { frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY) }
                window.setFrame(frame, display: true)
            } else if popup.contentSize != size {
                popup.contentSize = size
            }
        }
        menuResize = work
        DispatchQueue.main.async(execute: work)
    }

    private func dismissUtilityMenu() {
        popover?.performClose(nil)
        previewMenuPanel?.orderOut(nil)
    }

    private func showClipboard() {
        popover?.performClose(nil)
        previewMenuPanel?.orderOut(nil)
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            previousApplication = front
        }
        if panel == nil {
            let window = LauncherPanel(contentRect: NSRect(origin: .zero, size: JutilitiesLayout.clipboardSize),
                                       styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            window.title = "Jutilities — Clipboard History"
            window.appearance = NSAppearance(named: .darkAqua)
            window.identifier = NSUserInterfaceItemIdentifier("JutilitiesClipboard")
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = false
            window.minSize = JutilitiesLayout.clipboardMinimumSize
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: ClipboardHistoryView(model: model)
                .clipShape(RoundedRectangle(cornerRadius: JutilitiesLayout.cornerRadius)))
            window.center()
            panel = window
        }
        reload()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Save panels and native confirmation dialogs temporarily take focus.
        // Keep the history visible so those operations return to a usable panel.
    }

    private func reload() {
        guard let store else { return }
        searchGeneration += 1
        let generation = searchGeneration
        let query = model.query
        let filter = model.filter
        dataQueue.async { [weak self] in
            do {
                let entries = try store.entries(search: query, kind: filter, limit: 300)
                Task { @MainActor [weak self] in
                    guard let self, self.searchGeneration == generation else { return }
                    self.model.entries = entries
                }
            } catch { Task { @MainActor [weak self] in self?.model.errorMessage = error.localizedDescription } }
        }
    }

    private func loadPreview(_ entry: ClipboardEntry?) {
        guard let entry, let store else { return }
        dataQueue.async { [weak self] in
            do {
                let representations = try store.representations(for: entry.id)
                Task { @MainActor [weak self] in
                    guard let self, self.model.selectedID == entry.id else { return }
                    if entry.kind == .image {
                        let data = representations.first { $0.type == NSPasteboard.PasteboardType.png.rawValue }
                            ?? representations.first { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }
                        self.model.selectedImage = data.flatMap { Self.previewImage($0.data) }
                    } else {
                        self.model.selectedText = representations.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }
                            .flatMap { String(data: $0.data, encoding: .utf8) } ?? entry.previewText
                    }
                }
            } catch { Task { @MainActor [weak self] in self?.model.errorMessage = error.localizedDescription } }
        }
    }

    private static func previewImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private func copy(_ entry: ClipboardEntry, autoPaste: Bool) {
        guard let store else { return }
        if isPreview { model.statusMessage = "Preview mode: clipboard and power settings are unchanged."; return }
        pasteGeneration += 1
        let generation = pasteGeneration
        dataQueue.async { [weak self] in
            do {
                let representations = try store.representations(for: entry.id)
                Task { @MainActor [weak self] in
                    guard let self, self.pasteGeneration == generation else { return }
                    let item = NSPasteboardItem()
                    for representation in representations {
                        item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                    }
                    let board = NSPasteboard.general
                    board.clearContents()
                    guard board.writeObjects([item]) else { self.model.errorMessage = "Could not restore this clipboard item."; return }
                    let clipboardGeneration = board.changeCount
                    self.monitor.markOwnWrite()
                    self.mutate { try $0.recordCopy(id: entry.id) }
                    self.model.statusMessage = "Copied to clipboard"
                    guard autoPaste else { return }
                    guard AXIsProcessTrusted() else {
                        self.model.statusMessage = "Copied. Press ⌘V to paste, or enable Jutilities in Accessibility for automatic paste."
                        self.showAccessibilityHelp()
                        return
                    }
                    let target = self.previousApplication
                    self.panel?.orderOut(nil)
                    guard let target, !target.isTerminated else {
                        self.model.statusMessage = "Copied. Switch to the destination app and press ⌘V."
                        return
                    }
                    target.activate(options: [])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                        // A newer copy, another restore, or changed focus cancels this paste.
                        guard let self, self.pasteGeneration == generation,
                              board.changeCount == clipboardGeneration,
                              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
                        let source = CGEventSource(stateID: .combinedSessionState)
                        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
                        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
                        down?.flags = .maskCommand
                        up?.flags = .maskCommand
                        down?.post(tap: .cghidEventTap)
                        up?.post(tap: .cghidEventTap)
                    }
                }
            } catch { Task { @MainActor [weak self] in self?.model.errorMessage = error.localizedDescription } }
        }
    }

    private func showAccessibilityHelp() {
        let alert = NSAlert()
        alert.messageText = "Set up Jutilities automatic paste"
        alert.informativeText = "Jutilities needs Accessibility permission to paste selected history into your previous app. Choose Enable, then allow Jutilities in macOS Accessibility settings. You can also use copy-only mode and paste yourself with ⌘V."
        alert.addButton(withTitle: "Enable Automatic Paste")
        alert.addButton(withTitle: "Use Copy-Only")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            NSWorkspace.shared.open(url)
        }
    }

    private func shareViaAirDrop(_ entry: ClipboardEntry) {
        guard !model.isSharingViaAirDrop, let store else { return }
        if isPreview {
            model.statusMessage = "Preview mode: AirDrop sharing is not started."
            return
        }
        model.isSharingViaAirDrop = true
        model.errorMessage = nil
        model.statusMessage = "Opening AirDrop…"
        // Snapshot the requested entry's original formats, independent of later selection changes.
        dataQueue.async { [weak self] in
            do {
                let payload = try ClipboardAirDropPayload.prepare(kind: entry.kind,
                    representations: store.representations(for: entry.id))
                Task { @MainActor [weak self] in
                    guard let self else { try? payload.removeTemporaryFiles(); return }
                    do {
                        try self.airDrop.share(payload, from: self.panel) { [weak self] outcome in
                            guard let self else { return }
                            self.model.isSharingViaAirDrop = false
                            switch outcome {
                            case .shared: self.model.statusMessage = "Shared via AirDrop."
                            case .cancelled: self.model.statusMessage = nil
                            case .failed:
                                self.model.statusMessage = nil
                                self.model.errorMessage = "AirDrop could not share this item. Check that the receiving device is nearby and discoverable, then try again."
                            }
                        }
                    } catch {
                        self.model.isSharingViaAirDrop = false
                        self.model.statusMessage = nil
                        self.model.errorMessage = "AirDrop is unavailable. Check Wi-Fi and Bluetooth, then try again."
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.model.isSharingViaAirDrop = false
                    self?.model.statusMessage = nil
                    self?.model.errorMessage = "Could not prepare this item for AirDrop. Try another clipboard item."
                }
            }
        }
    }

    private func mutate(_ operation: @escaping (ClipboardStore) throws -> Void) {
        guard let store else { return }
        let backup = backupURL
        dataQueue.async { [weak self] in
            do {
                try operation(store)
                if let backup { try store.backup(to: backup) }
                Task { @MainActor [weak self] in self?.reload() }
            } catch { Task { @MainActor [weak self] in self?.model.errorMessage = error.localizedDescription } }
        }
    }

    private func maintenance() {
        guard let store, let backupURL else { return }
        let activeExport = airDrop.temporaryDirectory
        dataQueue.async { [weak self] in
            ClipboardAirDropPayload.removeStaleExports(excluding: activeExport)
            do {
                _ = try store.purgeExpired()
                try store.backup(to: backupURL)
                Task { @MainActor [weak self] in self?.reload() }
            } catch { Task { @MainActor [weak self] in self?.model.errorMessage = error.localizedDescription } }
        }
    }

    private func exportBackup() {
        dismissUtilityMenu()
        guard let store else { return }
        let save = NSSavePanel()
        save.title = "Back Up Clipboard History"
        save.nameFieldStringValue = "Jutilities-clipboard.sqlite"
        save.allowedContentTypes = [.database]
        guard save.runModal() == .OK, let destination = save.url else { return }
        dataQueue.async { [weak self] in
            do {
                _ = try store.purgeExpired()
                try store.backup(to: destination)
                Task { @MainActor [weak self] in self?.model.statusMessage = "Backup saved. Exported backups are kept until you delete them." }
            } catch { Task { @MainActor [weak self] in self?.model.errorMessage = error.localizedDescription } }
        }
    }

    private func restoreBackup() {
        dismissUtilityMenu()
        guard store != nil else { return }
        let open = NSOpenPanel()
        open.title = "Restore Jutilities Clipboard Backup"
        open.allowedContentTypes = [.database]
        open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let source = open.url else { return }
        let alert = NSAlert()
        alert.messageText = "Replace current clipboard history?"
        alert.informativeText = "This restores the selected backup. Items older than 60 days are removed immediately. Export your current history first if you want to keep it."
        alert.addButton(withTitle: "Restore Backup")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mutate { try $0.restore(from: source) }
    }

    private func seedPreview() throws {
        guard let store else { return }
        let captures: [(String, ClipboardKind, String, TimeInterval)] = [
            ("Release notes for Jutilities", .text, "Jutilities brings your clipboard and power controls together.\n\nSearch what you copied, preview screenshots, and keep your Mac awake for focused work. Everything stays on this Mac.", 120),
            ("https://developer.apple.com/swift/", .link, "https://developer.apple.com/swift/", 800),
            ("Build and run", .text, "// Ready for another focused session\nlet utilities = Jutilities()\nutilities.clipboard.search(\"release notes\")\nutilities.power.keepAwake(for: .minutes(30))", 1700),
            ("A few things to remember", .text, "Review the release notes\nShare the latest screenshots\nFinish the final build", 95000)
        ]
        for (title, kind, text, ago) in captures {
            let entry = try store.insert(ClipboardCapture(kind: kind, title: title, text: text,
                sourceApp: kind == .link ? "Safari" : "Notes", sourceBundleID: nil,
                representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]),
                now: Date().addingTimeInterval(-ago))
            if title == "Release notes for Jutilities" { try store.setPinned(id: entry.id, pinned: true) }
        }
        let image = BrandIcon.image(size: 640)
        if let data = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            _ = try store.insert(ClipboardCapture(kind: .image, title: "Jutilities · 640 × 640", text: nil,
                sourceApp: "Preview", sourceBundleID: nil,
                representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, data: png)],
                thumbnail: png, imageWidth: 640, imageHeight: 640), now: Date().addingTimeInterval(-300))
        }
    }
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
