import AppKit
import ServiceManagement

@main
struct JutilitiesApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--version") {
            print("Jutilities \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")")
            return
        }
        if CommandLine.arguments.contains("--automation-status") {
            let status = PastePermissionStatus.current()
            let report: [String: Any] = [
                "accessibilityTrusted": status.accessibilityTrusted,
                "canPostEvents": status.canPostEvents,
                "automaticPasteAvailable": status.allowsAutomaticPaste
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        if CommandLine.arguments.contains("--login-status") {
            switch SMAppService.mainApp.status {
            case .enabled: print("enabled")
            case .requiresApproval: print("requires-approval")
            case .notRegistered: print("not-registered")
            case .notFound: print("not-found")
            @unknown default: print("unknown")
            }
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
                for active in [false, true] {
                    for scale in [1, 2] {
                        let size = CGFloat(18 * scale)
                        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                            NSColor.white.setFill()
                            rect.fill()
                            BrandIcon.menuBarImage(keepingAwake: active).draw(in: rect)
                            return true
                        }
                        guard let tiff = image.tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: tiff),
                              let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                        let name = "menubar_\(active ? "awake" : "idle")_preview\(scale == 2 ? "@2x" : "").png"
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
