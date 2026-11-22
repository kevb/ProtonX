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
                Button(focusedProduct == .contacts ? "New Contact" : focusedProduct == .calendar ? "New Event" : focusedProduct == .mail ? "New Message" : "New Pass Item") {
                    NotificationCenter.default.post(name: focusedProduct == .calendar ? .protonXNewEvent : focusedProduct == .mail ? .protonXNewMessage : .protonXNewItem, object: nil)
                }.keyboardShortcut("n").disabled(focusedCanCreate != true)
            }
            CommandMenu("Products") {
                Button("Home") { SystemIntegration.shared.openHome?() }.keyboardShortcut("0")
                Button("Open Pass") { SystemIntegration.shared.openPass?() }.keyboardShortcut("1")
                Button("Open Mail") { SystemIntegration.shared.openMail?() }.keyboardShortcut("2")
                Button("Open Contacts") { SystemIntegration.shared.openContacts?() }.keyboardShortcut("4")
                Button("Open Calendar") { SystemIntegration.shared.openCalendar?() }.keyboardShortcut("3")
                Divider()
                Button("Lock ProtonX") { SystemIntegration.shared.lockSuite?() }.keyboardShortcut("l")
                Button("Search " + (focusedProduct?.displayName ?? "ProtonX")) {
                    if focusedProduct == .contacts { NotificationCenter.default.post(name: .protonXFocusContactsSearch, object: nil) }
                    else if focusedProduct == .calendar { NotificationCenter.default.post(name: .protonXFocusCalendarSearch, object: nil) }
                    else if focusedProduct == .mail { NotificationCenter.default.post(name: .protonXFocusMailSearch, object: nil) }
                    else { SystemIntegration.shared.openPass?(); NotificationCenter.default.post(name: .protonXFocusSearch, object: nil) }
                }.keyboardShortcut("f").disabled(workspace.selected == nil ||
                    (workspace.selected == .calendar ? workspace.calendar?.isWorkspaceOpen != true : workspace.selected == .pass ? workspace.pass?.phase != .open : workspace.selected == .contacts ? workspace.mail?.phase != .open : workspace.mail?.phase != .open || workspace.mail?.draft != nil))
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
    @AppStorage(LockSettings.passAutoLockKey) private var passAutoLockSeconds = LockSettings.defaultPassAutoLockSeconds
    @AppStorage(LockSettings.mailAutoLockKey) private var mailAutoLockSeconds = LockSettings.defaultMailAutoLockSeconds
    @AppStorage(LockSettings.lockMailOnScreenLockKey) private var lockMailOnScreenLock = true
    @AppStorage(LockSettings.keepMailOpenOnWindowCloseKey) private var keepMailOpenOnWindowClose = true
    @AppStorage(LockSettings.mailBackgroundSyncWhileLockedKey) private var mailBackgroundSyncWhileLocked = true
    @AppStorage(LockSettings.linkMailCalendarUnlockKey) private var linkMailCalendarUnlock = true
    @AppStorage(LockSettings.passBackgroundCacheSyncKey) private var passBackgroundCacheSync = false
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
                    Text("Pass").tag("pass"); Text("Mail").tag("mail"); Text("Calendar").tag("calendar"); Text("Contacts").tag("contacts")
                }
                Text("Mail, Pass, Calendar and Contacts keep their place in one ProtonX window. Spotlight product launchers go straight to the requested product. Use Quit (⌘Q) to stop ProtonX and all background sync.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Mail, Contacts & Calendar") {
                Picker("Lock after inactivity", selection: $mailAutoLockSeconds) {
                    Text("15 minutes").tag(900)
                    Text("1 hour").tag(3600)
                    Text("8 hours").tag(28_800)
                    Text("24 hours").tag(86_400)
                    Text("Never (manual only)").tag(0)
                }
                Toggle("Unlock Mail, Contacts & Calendar together", isOn: $linkMailCalendarUnlock)
                Toggle("Lock when Mac screen locks or sleeps", isOn: $lockMailOnScreenLock)
                Toggle("Keep open when closing the window", isOn: $keepMailOpenOnWindowClose)
                Toggle("Sync Mail & deliver anonymous alerts while locked", isOn: $mailBackgroundSyncWhileLocked)
                    .onChange(of: mailBackgroundSyncWhileLocked) { _, _ in
                        NotificationCenter.default.post(name: .protonXSettingsChanged, object: nil)
                    }
                Text("Unlocking Mail, Contacts, or Calendar with Touch ID opens the others in this group automatically while keeping Pass separate. Inactivity tracks Mac-wide idle time, so working in other apps won’t lock your inbox. When Mail is locked, background sync keeps mail up to date and delivers private alerts without showing senders or subjects.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Pass security") {
                Picker("Lock Pass after inactivity", selection: $passAutoLockSeconds) {
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                    Text("1 hour").tag(3600)
                    Text("Never (manual only)").tag(0)
                }
                Toggle("Refresh Pass encrypted cache while locked", isOn: $passBackgroundCacheSync)
                    .onChange(of: passBackgroundCacheSync) { _, _ in
                        NotificationCenter.default.post(name: .protonXSettingsChanged, object: nil)
                    }
                Text("Pass always locks on screen lock, sleep, user switch, or window close. Copied secrets expire after 30 seconds. Optional background cache refresh updates only Pass’s encrypted saved database on disk without holding decrypted items in memory.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Open source") {
                Link("Source, license, and notices", destination: URL(string: "https://github.com/kevb/ProtonX")!)
                Text("GPL-3.0-or-later · No warranty · Independent of Proton AG").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(16).frame(maxWidth: .infinity)
            .onAppear {
                if UserDefaults.standard.object(forKey: LockSettings.passAutoLockKey) == nil {
                    passAutoLockSeconds = LockSettings.load().passAutoLockSeconds
                }
            }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            MailTranslationSettingsView().tabItem { Label("Translation", systemImage: "character.bubble") }
            NotificationSettingsView().tabItem { Label("Notifications", systemImage: "bell") }
        }.frame(width: 580, height: 680).tint(PassTheme.accent)
    }
}
