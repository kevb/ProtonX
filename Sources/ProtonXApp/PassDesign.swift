import SwiftUI
import AppKit

/// Local native surfaces; no remote favicons, fonts or appearance preferences.
enum PassTheme {
    static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                    green: Double((hex >> 8) & 255) / 255,
                    blue: Double(hex & 255) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            color(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
    static let accent = adaptive("Pass accent", light: 0x6945C4, dark: 0xC0B5FF)
    static let sidebar = adaptive("Pass sidebar", light: 0xF3F1F8, dark: 0x191925)
    static let collection = adaptive("Pass collection", light: 0xFAF9FD, dark: 0x202030)
    static let canvas = adaptive("Pass canvas", light: 0xFFFFFF, dark: 0x1D1D2B)
    static let surface = adaptive("Pass surface", light: 0xFAF9FD, dark: 0x232333)
    static let border = adaptive("Pass border", light: 0xDDD8EA, dark: 0x454256)
    static let primaryText = adaptive("Pass primary button text", light: 0xFFFFFF, dark: 0x201B38)
    static let note = adaptive("Pass note", light: 0x9B652C, dark: 0xE8BE90)
    static let network = adaptive("Pass network", light: 0x2C6B9E, dark: 0x91C5ED)
    static let selectedInk = Color(red: 0.41, green: 0.27, blue: 0.77)
    static func itemColor(_ kind: String) -> Color {
        switch kind { case "note": note; case "wifi": network; default: accent }
    }
}

private struct PassSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.background(PassTheme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(PassTheme.border.opacity(contrast == .increased ? 1 : 0.65), lineWidth: 1).allowsHitTesting(false) }
    }
}
extension View {
    func passSurface(radius: CGFloat = 18) -> some View { modifier(PassSurface(radius: radius)) }
}

struct PassPillStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(primary ? PassTheme.primaryText : PassTheme.accent)
            .background(primary ? PassTheme.accent : PassTheme.accent.opacity(configuration.isPressed ? 0.18 : 0.10), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

struct PassIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .medium))
            .foregroundStyle(PassTheme.accent).frame(width: 34, height: 34)
            .background(PassTheme.accent.opacity(configuration.isPressed ? 0.18 : 0.06), in: Circle())
            .opacity(enabled ? 1 : 0.4).contentShape(Circle())
    }
}

struct PassItemBadge: View {
    let symbol: String
    let kind: String
    var size: CGFloat = 44
    var selected = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(selected ? PassTheme.selectedInk : PassTheme.itemColor(kind)).frame(width: size, height: size)
            .background(selected ? Color.white : PassTheme.itemColor(kind).opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.32))
            .accessibilityHidden(true)
    }
}

struct PassWordmark: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("PX").font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(PassTheme.primaryText).frame(width: 36, height: 36)
                .background(PassTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("ProtonX").font(.caption).foregroundStyle(.secondary)
                Text("Pass").font(.system(size: 18, weight: .semibold))
            }
        }.accessibilityElement(children: .combine)
    }
}
