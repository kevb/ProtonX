import SwiftUI
import AppKit

/// Mail chrome follows system appearance; message paper deliberately stays light.
/// Avatars are generated locally, without contacting sender domains.
enum MailTheme {
    static let sidebar = PassTheme.adaptive("Mail sidebar", light: 0xF1EFF6, dark: 0x343435)
    static let collection = PassTheme.adaptive("Mail collection", light: 0xFFFFFF, dark: 0x211E29)
    static let canvas = PassTheme.adaptive("Mail canvas", light: 0xF8F7FB, dark: 0x17141D)
    static let border = PassTheme.adaptive("Mail border", light: 0xE3DFEB, dark: 0x3B3747)
    static let accent = PassTheme.adaptive("Mail accent", light: 0x6844D9, dark: 0xB59AFF)
    static let action = Color(red: 0.42, green: 0.28, blue: 1)
    static let paper = Color.white
    static let ink = Color(red: 0.09, green: 0.08, blue: 0.11)

    static func symbol(for folder: String) -> String {
        switch folder.lowercased() {
        case "inbox": "tray"
        case "drafts": "doc"
        case "sent": "paperplane"
        case "starred": "star"
        case "archive", "all mail": "archivebox"
        case "trash": "trash"
        case "spam": "exclamationmark.shield"
        default: "folder"
        }
    }
}

struct MailActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, primary ? 15 : 9)
            .foregroundStyle(primary ? Color.white : MailTheme.accent)
            .background(primary ? MailTheme.action : MailTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MailSenderAvatar: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).font(.system(size: 15, weight: .medium))
            .foregroundStyle(MailTheme.accent).frame(width: 34, height: 34)
            .background(MailTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

struct MailMessagePaper: View {
    let text: String
    var body: some View {
        Text(verbatim: text).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
            .foregroundStyle(MailTheme.ink).frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
            .padding(28).background(MailTheme.paper)
            .environment(\.colorScheme, .light)
            .accessibilityIdentifier("mailMessagePaper")
    }
}
