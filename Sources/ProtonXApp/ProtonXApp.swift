import SwiftUI
import ProtonXCore

@main
struct ProtonXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @FocusedValue(\.protonXProduct) private var focusedProduct
    @FocusedValue(\.protonXCanCreate) private var focusedCanCreate
    @FocusedValue(\.protonXCanRefresh) private var focusedCanRefresh
    @StateObject private var pass = PassStore()
    var body: some Scene {
        Window("ProtonX Pass", id: "pass") {
            PassWindow().environmentObject(pass).tint(PassTheme.accent)
        }.defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) { Button("About ProtonX…") { NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: "ProtonX", .applicationVersion: "0.1.0", .credits: NSAttributedString(string: "Independent native clients for Proton.\nGPL-3.0-or-later. No warranty.\nCopyright © 2026 ProtonX contributors.\nIncludes Proton Pass and Mail © Proton AG.\nMail helper: AGPL-3.0-only.\nSource and license: github.com/kevb/ProtonX\nNot affiliated with Proton AG.")]) } }
            CommandGroup(replacing: .newItem) {
                Button(focusedProduct == .mail ? "New Message" : "New Pass Item") {
                    NotificationCenter.default.post(name: focusedProduct == .mail ? .protonXNewMessage : .protonXNewItem, object: nil)
                }.keyboardShortcut("n").disabled(focusedCanCreate != true)
            }
            CommandMenu("Products") {
                Button("Open Pass") { SystemIntegration.shared.openPass?() }.keyboardShortcut("1")
                Button("Open Mail") { SystemIntegration.shared.openMail?() }.keyboardShortcut("2")
                Divider()
                Button("Lock ProtonX") { SystemIntegration.shared.lockSuite?() }.keyboardShortcut("l")
                Button(focusedProduct == .mail ? "Search Mail" : "Search Pass") {
                    if focusedProduct == .mail { NotificationCenter.default.post(name: .protonXFocusMailSearch, object: nil) }
                    else { SystemIntegration.shared.openPass?(); NotificationCenter.default.post(name: .protonXFocusSearch, object: nil) }
                }.keyboardShortcut("f")
                Button(focusedProduct == .mail ? "Refresh Mail" : "Refresh Pass") {
                    if focusedProduct == .mail { NotificationCenter.default.post(name: .protonXRefreshMail, object: nil) } else { pass.refresh() }
                }.keyboardShortcut("r").disabled(focusedCanRefresh != true)
            }
            CommandGroup(replacing: .help) {
                Link("ProtonX Documentation", destination: URL(string: "https://github.com/kevb/ProtonX#readme")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/kevb/ProtonX/issues")!)
            }
        }
        Window("ProtonX Mail", id: "mail") {
            MailWindow(previewOnly: pass.previewOnly).tint(MailTheme.accent)
        }.defaultSize(width: 1240, height: 800)
        Settings { SettingsView() }
    }
}

struct SettingsView: View {
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("quickAccessEnabled") private var quickAccessEnabled = false
    @AppStorage("autoLockSeconds") private var autoLockSeconds = 300
    var body: some View {
        Form {
            Section("Mac integration") {
                Toggle("Show one ProtonX menu-bar icon", isOn: $menuBarEnabled)
                    .onChange(of: menuBarEnabled) { _, _ in SystemIntegration.shared.updateMenuBar() }
                Toggle("Quick access with ⌃⌥P", isOn: $quickAccessEnabled)
                    .onChange(of: quickAccessEnabled) { _, _ in SystemIntegration.shared.updateHotKey() }
                Text("Mail and Pass keep separate windows. Closing a window keeps ProtonX available; use Quit to stop it.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Security") {
                Picker("Lock after inactivity", selection: $autoLockSeconds) {
                    Text("1 minute").tag(60); Text("5 minutes").tag(300); Text("15 minutes").tag(900)
                }
                Text("ProtonX always locks when the screen locks, the display sleeps, or you switch users. Secrets copied from Pass expire after 30 seconds. Session encryption uses Proton’s client and your login Keychain.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Open source") {
                Link("Source, license, and notices", destination: URL(string: "https://github.com/kevb/ProtonX")!)
                Text("GPL-3.0-or-later · No warranty · Independent of Proton AG").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(16).frame(width: 530)
    }
}
