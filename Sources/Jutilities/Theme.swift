import AppKit
import SwiftUI

enum JutilitiesLayout {
    static let clipboardSize = NSSize(width: 760, height: 500)
    static let clipboardMinimumSize = NSSize(width: 700, height: 440)
    static let historyWidth: CGFloat = 292
    static let menuWidth: CGFloat = 350
    static let menuMaximumHeight: CGFloat = 640
    static let cornerRadius: CGFloat = 12
}

enum JutilitiesTheme {
    static let background = Color(red: 0.095, green: 0.100, blue: 0.112)
    static let surface = Color.white.opacity(0.025)
    static let separator = Color.white.opacity(0.065)
    static let muted = Color.white.opacity(0.56)
    static let accent = Color(red: 0.76, green: 0.80, blue: 0.93)
    static let selection = Color(red: 0.76, green: 0.80, blue: 0.93).opacity(0.09)
}

/// Native backdrop blur keeps the desktop visible without fading the controls.
struct TranslucentBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                JutilitiesTheme.background
            } else {
                BackdropMaterial()
                    .overlay(JutilitiesTheme.background.opacity(0.40))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BackdropMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ShortcutKey: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.65))
            .padding(.horizontal, 5)
            .frame(minWidth: 17, minHeight: 18)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.06)))
            .accessibilityHidden(true)
    }
}
