import AppKit
import JutilitiesCore
import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardViewModel
    @FocusState private var isSearchFocused: Bool
    @State private var showsActions = false
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if let error = model.errorMessage {
                errorBanner(error)
            }
            Divider().overlay(JutilitiesTheme.separator)
            HStack(spacing: 0) {
                historyList
                    .frame(width: JutilitiesLayout.historyWidth)
                Divider().overlay(JutilitiesTheme.separator)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().overlay(JutilitiesTheme.separator)
            actionBar
        }
        .background {
            TranslucentBackground()
        }
        .overlay {
            RoundedRectangle(cornerRadius: JutilitiesLayout.cornerRadius)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: JutilitiesLayout.clipboardMinimumSize.width,
               minHeight: JutilitiesLayout.clipboardMinimumSize.height)
        .background {
            ClipboardKeyboardMonitor { event in handleKey(event) }
                .frame(width: 0, height: 0)
        }
        .onAppear { isSearchFocused = true }
        .confirmationDialog("Clear clipboard history?", isPresented: $showsClearConfirmation) {
            Button("Clear History", role: .destructive) { model.onClear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all saved text, links, and images, including pinned items. Your current clipboard is kept.")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(JutilitiesTheme.muted)
            TextField("Search your clipboard…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isSearchFocused)
                .accessibilityLabel("Search clipboard history")
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(JutilitiesTheme.muted)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
            contentTypeMenu
            Divider().frame(height: 18)
            Menu {
                Button(model.isPaused ? "Resume Clipboard Capture" : "Pause Clipboard Capture") {
                    model.togglePause()
                }
                Button("Back Up History…") { model.onBackup() }
                Divider()
                Button("Clear History…", role: .destructive) { showsClearConfirmation = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("History settings")
            .accessibilityLabel("History settings")
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(JutilitiesTheme.surface)
    }

    private var contentTypeMenu: some View {
        Menu {
            filterButton("Everything", kind: nil, symbol: "square.stack")
            filterButton("Text", kind: .text, symbol: "text.alignleft")
            filterButton("Links", kind: .link, symbol: "link")
            filterButton("Images", kind: .image, symbol: "photo")
        } label: {
            HStack(spacing: 7) {
                Text(model.filter.map(kindTitle) ?? "Everything")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filter content type")
        .accessibilityValue(model.filter.map(kindTitle) ?? "Everything")
    }

    private func filterButton(_ title: String, kind: ClipboardKind?, symbol: String) -> some View {
        Button {
            model.filter = kind
        } label: {
            Label(model.filter == kind ? "✓ \(title)" : title, systemImage: symbol)
        }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            if model.isPaused {
                HStack(spacing: 7) {
                    Image(systemName: "pause.circle")
                    Text("Clipboard capture paused")
                    Spacer()
                    Button("Resume") { model.togglePause() }
                        .buttonStyle(.plain)
                        .foregroundStyle(JutilitiesTheme.accent)
                }
                .font(.system(size: 11))
                .foregroundStyle(JutilitiesTheme.muted)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(.white.opacity(0.025))
            }

            if model.entries.isEmpty {
                emptyHistory
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(sections) { section in
                                Text(section.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(JutilitiesTheme.muted)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 12)
                                    .padding(.bottom, 5)
                                    .accessibilityAddTraits(.isHeader)

                                ForEach(section.entries) { entry in
                                    ClipboardHistoryRow(entry: entry, isSelected: entry.id == model.selectedID) {
                                        model.select(entry)
                                    }
                                    .id(entry.id)
                                    .contextMenu {
                                        Button("Paste") { model.onCopy(entry, true) }
                                        Button("Copy") { model.onCopy(entry, false) }
                                        Divider()
                                        Button(entry.isPinned ? "Unpin" : "Pin") { model.onPin(entry) }
                                        Button("Delete", role: .destructive) { model.onDelete(entry) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyHistory: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: model.query.isEmpty && model.filter == nil ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 29, weight: .light))
                .foregroundStyle(JutilitiesTheme.muted)
                .padding(.bottom, 3)
            Text(model.query.isEmpty && model.filter == nil ? "Your clipboard, remembered." : "No matching items")
                .font(.system(size: 14, weight: .medium))
            Text(model.query.isEmpty && model.filter == nil
                 ? "Copy text, links, or images\nto find them here."
                 : "Try another search or content type.")
                .font(.system(size: 12))
                .foregroundStyle(JutilitiesTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            if !model.query.isEmpty || model.filter != nil {
                Button("Clear Filters") {
                    model.query = ""
                    model.filter = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(JutilitiesTheme.accent)
                .padding(.top, 5)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let entry = model.selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: kindSymbol(entry.kind))
                    Text(kindTitle(entry.kind))
                    Spacer()
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                        Text("Pinned")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(JutilitiesTheme.muted)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

                if entry.kind == .image {
                    imagePreview(entry)
                } else {
                    ScrollView {
                        Text(model.selectedText ?? entry.previewText ?? entry.title)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.89))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                metadata(entry)
            }
        } else {
            VStack(spacing: 11) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 37, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.16))
                Text("Everything stays on your Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(JutilitiesTheme.muted)
                Text("Select an item to see its full contents.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func imagePreview(_ entry: ClipboardEntry) -> some View {
        if let image = model.selectedImage ?? entry.thumbnail.flatMap(NSImage.init(data:)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Preview of \(entry.title)")
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading image…")
                    .font(.system(size: 12))
                    .foregroundStyle(JutilitiesTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metadata(_ entry: ClipboardEntry) -> some View {
        VStack(spacing: 8) {
            metadataRow("Copied from", value: entry.sourceApp.isEmpty ? "Unknown app" : entry.sourceApp, symbol: "app")
            metadataRow("Last copied", value: entry.lastCopiedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()), symbol: "clock")
            if entry.kind == .image, let width = entry.imageWidth, let height = entry.imageHeight {
                metadataRow("Dimensions", value: "\(width) × \(height)", symbol: "arrow.up.left.and.arrow.down.right")
            } else if let text = model.selectedText {
                metadataRow("Length", value: "\(text.count.formatted()) characters", symbol: "textformat.abc")
            }
            metadataRow("Size", value: ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file), symbol: "doc")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(JutilitiesTheme.surface)
        .overlay(alignment: .top) { Rectangle().fill(JutilitiesTheme.separator).frame(height: 1) }
    }

    private func metadataRow(_ label: String, value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(JutilitiesTheme.muted)
            Spacer(minLength: 15)
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(JutilitiesTheme.muted)
                .accessibilityHidden(true)
            Text(value)
                .foregroundStyle(Color.white.opacity(0.74))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Text("JU")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel("Jutilities")
            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(JutilitiesTheme.accent)
                    .lineLimit(1)
            } else {
                Text("Saved locally · Cleared after 60 days")
                    .font(.system(size: 10))
                    .foregroundStyle(JutilitiesTheme.muted)
                    .help("All clipboard entries, including pinned items, are automatically deleted after 60 days.")
            }
            Spacer(minLength: 15)
            Button {
                model.copySelection(autoPaste: true)
            } label: {
                HStack(spacing: 7) {
                    Text("Paste")
                        .font(.system(size: 11, weight: .medium))
                    ShortcutKey(label: "↵")
                }
            }
            .buttonStyle(.plain)
            .disabled(model.selectedEntry == nil)
            .help("Paste into the previous app")

            Divider().frame(height: 17).padding(.horizontal, 7)

            Button { showsActions.toggle() } label: {
                HStack(spacing: 7) {
                    Text("Actions")
                        .font(.system(size: 11, weight: .medium))
                    ShortcutKey(label: "⌘ K")
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsActions, arrowEdge: .bottom) { actionsPopover }
            .accessibilityLabel("Clipboard actions")
        }
        .foregroundStyle(Color.white.opacity(0.72))
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(JutilitiesTheme.surface)
    }

    private var actionsPopover: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("CLIPBOARD ACTIONS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(JutilitiesTheme.muted)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            action("Paste", symbol: "doc.on.clipboard", shortcut: "↵", enabled: model.selectedEntry != nil) {
                model.copySelection(autoPaste: true)
            }
            action("Copy", symbol: "doc.on.doc", shortcut: "⌘ ↵", enabled: model.selectedEntry != nil) {
                model.copySelection(autoPaste: false)
            }
            action(model.selectedEntry?.isPinned == true ? "Unpin Item" : "Pin Item", symbol: "pin", shortcut: "⌘ P", enabled: model.selectedEntry != nil) {
                model.pinSelection()
            }
            action("Delete Item", symbol: "trash", shortcut: "⌘ ⌫", enabled: model.selectedEntry != nil) {
                model.deleteSelection()
            }
            Divider().padding(.vertical, 5)
            action(model.isPaused ? "Resume Capture" : "Pause Capture", symbol: model.isPaused ? "play.circle" : "pause.circle") {
                model.togglePause()
            }
            action("Back Up History…", symbol: "externaldrive") { model.onBackup() }
            action("Clear History…", symbol: "trash") { showsClearConfirmation = true }
        }
        .padding(6)
        .frame(width: 260)
        .preferredColorScheme(.dark)
    }

    private func action(_ title: String, symbol: String, shortcut: String? = nil, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        Button {
            showsActions = false
            perform()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 17)
                    .foregroundStyle(JutilitiesTheme.muted)
                Text(title).font(.system(size: 12))
                Spacer()
                if let shortcut { ShortcutKey(label: shortcut) }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .frame(height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text(error)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(red: 1.0, green: 0.67, blue: 0.6))
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(Color.red.opacity(0.06))
    }

    private var sections: [ClipboardHistorySection] {
        let calendar = Calendar.current
        let items = model.orderedEntries
        let unpinned = items.filter { !$0.isPinned }
        return [
            ClipboardHistorySection(title: "Pinned", entries: items.filter(\.isPinned)),
            ClipboardHistorySection(title: "Today", entries: unpinned.filter { calendar.isDateInToday($0.lastCopiedAt) }),
            ClipboardHistorySection(title: "Yesterday", entries: unpinned.filter { calendar.isDateInYesterday($0.lastCopiedAt) }),
            ClipboardHistorySection(title: "Earlier", entries: unpinned.filter { !calendar.isDateInToday($0.lastCopiedAt) && !calendar.isDateInYesterday($0.lastCopiedAt) })
        ].filter { !$0.entries.isEmpty }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 125: model.moveSelection(1)
            case 126: model.moveSelection(-1)
            case 36, 76: model.copySelection(autoPaste: true)
            case 53:
                if showsActions { showsActions = false } else { model.onDismiss() }
            default: return false
            }
            return true
        }
        guard modifiers == .command else { return false }
        switch event.keyCode {
        case 36, 76: model.copySelection(autoPaste: false)
        case 35: model.pinSelection()
        case 40: showsActions.toggle()
        case 51: model.deleteSelection()
        default: return false
        }
        return true
    }
}

private struct ClipboardHistorySection: Identifiable {
    var id: String { title }
    let title: String
    let entries: [ClipboardEntry]
}

private struct ClipboardHistoryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                rowIcon
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(isSelected ? 0.95 : 0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(sourceAndTime)
                        .font(.system(size: 10))
                        .foregroundStyle(JutilitiesTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(JutilitiesTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? JutilitiesTheme.selection : (isHovered ? .white.opacity(0.035) : .clear), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? .white.opacity(0.045) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(kindTitle(entry.kind)): \(entry.title)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var rowIcon: some View {
        if entry.kind == .image, let thumbnail = entry.thumbnail, let image = NSImage(data: thumbnail) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.09)))
        } else {
            Image(systemName: kindSymbol(entry.kind))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(entry.kind == .link ? JutilitiesTheme.accent.opacity(0.8) : Color.white.opacity(0.56))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var sourceAndTime: String {
        let source = entry.sourceApp.isEmpty ? kindTitle(entry.kind) : entry.sourceApp
        let time = entry.lastCopiedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "\(source) · \(time)"
    }
}

private func kindTitle(_ kind: ClipboardKind) -> String {
    switch kind {
    case .text: "Text"
    case .link: "Links"
    case .image: "Images"
    }
}

private func kindSymbol(_ kind: ClipboardKind) -> String {
    switch kind {
    case .text: "text.alignleft"
    case .link: "link"
    case .image: "photo"
    }
}
