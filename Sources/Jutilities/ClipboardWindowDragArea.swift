import AppKit
import SwiftUI

struct ClipboardWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAreaView {
        let view = DragAreaView()
        view.toolTip = "Drag to move clipboard history"
        return view
    }

    func updateNSView(_ nsView: DragAreaView, context: Context) {}

    final class DragAreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
