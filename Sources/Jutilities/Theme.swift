import SwiftUI

enum JutilitiesTheme {
    static let background = Color(red: 0.085, green: 0.090, blue: 0.102)
    static let surface = Color(red: 0.114, green: 0.119, blue: 0.134)
    static let separator = Color.white.opacity(0.09)
    static let muted = Color.white.opacity(0.48)
    static let accent = Color(red: 0.67, green: 0.74, blue: 1.0)
    static let selection = Color.white.opacity(0.08)
}

struct ShortcutKey: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.65))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 20)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.08)))
            .accessibilityHidden(true)
    }
}
