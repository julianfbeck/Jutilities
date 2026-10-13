import AppKit

enum BrandIcon {
    /// A simplified vector mark for the menu bar, tinted by macOS in either appearance.
    static func menuBarImage(keepingAwake: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()

            let monogram = NSBezierPath()
            monogram.lineWidth = 2
            monogram.lineCapStyle = .round
            monogram.lineJoinStyle = .round
            monogram.move(to: NSPoint(x: 12.6, y: 15))
            monogram.line(to: NSPoint(x: 12.6, y: 7.8))
            monogram.curve(to: NSPoint(x: 8.7, y: 3.9),
                           controlPoint1: NSPoint(x: 12.6, y: 5.65),
                           controlPoint2: NSPoint(x: 10.85, y: 3.9))
            monogram.curve(to: NSPoint(x: 4.8, y: 7.8),
                           controlPoint1: NSPoint(x: 6.55, y: 3.9),
                           controlPoint2: NSPoint(x: 4.8, y: 5.65))
            monogram.line(to: NSPoint(x: 4.8, y: 9.7))
            monogram.stroke()

            let card = NSBezierPath(roundedRect: NSRect(x: 7, y: 7.8, width: 3.4, height: 4.9),
                                    xRadius: 0.65, yRadius: 0.65)
            card.fill()

            if keepingAwake {
                NSBezierPath(ovalIn: NSRect(x: 14.8, y: 13.8, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Jutilities"
        return image
    }

    static func image(size: CGFloat) -> NSImage {
        let dimensions = NSSize(width: size, height: size)
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let source = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Jutilities")
                ?? NSImage(size: dimensions)
        }
        let image = NSImage(size: dimensions)
        image.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: dimensions),
                    from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }
}
