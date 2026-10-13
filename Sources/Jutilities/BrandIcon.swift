import AppKit

enum BrandIcon {
    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: size * 0.045, dy: size * 0.045),
                                 xRadius: size * 0.2, yRadius: size * 0.2)
        NSGradient(colors: [NSColor(calibratedRed: 0.19, green: 0.2, blue: 0.24, alpha: 1),
                            NSColor(calibratedRed: 0.065, green: 0.075, blue: 0.095, alpha: 1)])?
            .draw(in: shape, angle: -75)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.44, weight: .heavy),
            .foregroundColor: NSColor(calibratedRed: 1, green: 0.34, blue: 0.34, alpha: 1),
            .paragraphStyle: paragraph
        ]
        NSString(string: "JU").draw(in: NSRect(x: 0, y: size * 0.24, width: size, height: size * 0.54), withAttributes: attributes)
        image.unlockFocus()
        return image
    }
}
