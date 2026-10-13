import AppKit
import SwiftUI

/// A window-scoped monitor keeps search focused while arrow keys select history.
struct ClipboardKeyboardMonitor: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ClipboardKeyEventView {
        let view = ClipboardKeyEventView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: ClipboardKeyEventView, context: Context) {
        nsView.onKey = onKey
    }

    static func dismantleNSView(_ nsView: ClipboardKeyEventView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

final class ClipboardKeyEventView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  window.isKeyWindow, event.window === window else { return event }
            // Modal sheets and native menus keep their own keyboard behavior.
            guard window.attachedSheet == nil else { return event }
            return self.onKey?(event) == true ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
