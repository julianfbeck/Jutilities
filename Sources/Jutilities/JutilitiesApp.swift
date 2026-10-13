import AppKit

@main
struct JutilitiesApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--version") {
            print("Jutilities 0.1.0")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--export-icons"),
           CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for size in [16, 32, 128, 256, 512] {
                    for scale in [1, 2] {
                        let pixels = size * scale
                        guard let tiff = BrandIcon.image(size: CGFloat(pixels)).tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: tiff),
                              let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                        try data.write(to: directory.appendingPathComponent(name))
                    }
                }
            } catch { fputs("Icon export failed.\n", stderr) }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
