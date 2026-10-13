import AppKit

enum BrandIcon {
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
