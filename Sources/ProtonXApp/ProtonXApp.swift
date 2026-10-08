import SwiftUI
import ProtonXCore

@main
struct ProtonXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @FocusedValue(\.protonXProduct) private var focusedProduct
    @FocusedValue(\.protonXCanCreate) private var focusedCanCreate
    @FocusedValue(\.protonXCanRefresh) private var focusedCanRefresh
    @StateObject private var workspace = SuiteWorkspace(initialProduct: ProductWindows.shared.pending)
    var body: some Scene {
        Window("ProtonX", id: "suite") {
            SuiteWindow(workspace: workspace).tint(PassTheme.accent)
        }.defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) { Button("About ProtonX…") { NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: "ProtonX", .applicationVersion: "0.1.0", .credits: NSAttributedString(string: "Independent native clients for Proton.\nGPL-3.0-or-later. No warranty.\nCopyright © 2026 ProtonX contributors.\nIncludes Proton Pass and Mail © Proton AG.\nMail helper: AGPL-3.0-only.\nSource and license: github.com/kevb/ProtonX\nNot affiliated with Proton AG.")]) } }
            CommandGroup(replacing: .newItem) {
                Button(focusedProduct == .calendar ? "New Event" : focusedProduct == .mail ? "New Message" : "New Pass Item") {
                    NotificationCenter.default.post(name: focusedProduct == .calendar ? .protonXNewEvent : focusedProduct == .mail ? .protonXNewMessage : .protonXNewItem, object: nil)
                }.keyboardShortcut("n").disabled(focusedCanCreate != true)
            }
            CommandMenu("Products") {
                Button("Home") { SystemIntegration.shared.openHome?() }.keyboardShortcut("0")
                Button("Open Pass") { SystemIntegration.shared.openPass?() }.keyboardShortcut("1")
                Button("Open Mail") { SystemIntegration.shared.openMail?() }.keyboardShortcut("2")
                Button("Open Calendar") { SystemIntegration.shared.openCalendar?() }.keyboardShortcut("3")
                Divider()
                Button("Lock ProtonX") { SystemIntegration.shared.lockSuite?() }.keyboardShortcut("l")
                Button("Search " + (focusedProduct?.displayName ?? "ProtonX")) {
                    if focusedProduct == .calendar { NotificationCenter.default.post(name: .protonXFocusCalendarSearch, object: nil) }
                    else if focusedProduct == .mail { NotificationCenter.default.post(name: .protonXFocusMailSearch, object: nil) }
                    else { SystemIntegration.shared.openPass?(); NotificationCenter.default.post(name: .protonXFocusSearch, object: nil) }
                }.keyboardShortcut("f").disabled(workspace.selected == nil ||
                    (workspace.selected == .calendar ? workspace.calendar?.isWorkspaceOpen != true : workspace.selected == .pass ? workspace.pass?.phase != .open : workspace.mail?.phase != .open || workspace.mail?.draft != nil))
                Button("Refresh " + (focusedProduct?.displayName ?? "ProtonX")) {
                    workspace.refresh()
                }.keyboardShortcut("r").disabled(focusedCanRefresh != true)
            }
            CommandGroup(replacing: .help) {
                Link("ProtonX Documentation", destination: URL(string: "https://github.com/kevb/ProtonX#readme")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/kevb/ProtonX/issues")!)
            }
        }
        Settings { SettingsView() }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("quickAccessEnabled") private var quickAccessEnabled = false
    @AppStorage("autoLockSeconds") private var autoLockSeconds = 300
    @AppStorage("suiteStartup") private var suiteStartup = "last"
    var body: some View {
        Form {
            Section("Mac integration") {
                Toggle("Show one ProtonX menu-bar icon", isOn: $menuBarEnabled)
                    .onChange(of: menuBarEnabled) { _, _ in SystemIntegration.shared.updateMenuBar() }
                Toggle("Quick access with ⌃⌥P", isOn: $quickAccessEnabled)
                    .onChange(of: quickAccessEnabled) { _, _ in SystemIntegration.shared.updateHotKey() }
                Picker("On launch", selection: $suiteStartup) {
                    Text("Last product").tag("last"); Text("Home").tag("home")
                    Text("Pass").tag("pass"); Text("Mail").tag("mail"); Text("Calendar").tag("calendar")
                }
                Text("Mail, Pass and Calendar keep their place in one ProtonX window. Spotlight product launchers go straight to the requested product. Closing the window locks every product; use Quit to stop ProtonX.").font(.caption).foregroundStyle(.secondary)
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
        }.formStyle(.grouped).padding(16).frame(maxWidth: .infinity)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettingsView().tabItem { Label("Notifications", systemImage: "bell") }
        }.frame(width: 580, height: 620).tint(PassTheme.accent)
    }
}
