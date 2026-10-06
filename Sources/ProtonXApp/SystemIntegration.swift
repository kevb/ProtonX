import SwiftUI
import AppKit
import Carbon

extension Notification.Name {
    static let protonXNewMessage = Notification.Name("ProtonX.newMessage")
    static let protonXRefreshMail = Notification.Name("ProtonX.refreshMail")
    static let protonXFocusMailSearch = Notification.Name("ProtonX.focusMailSearch")
    static let protonXNewItem = Notification.Name("ProtonX.newItem")
    static let protonXFocusSearch = Notification.Name("ProtonX.focusSearch")
    static let protonXLock = Notification.Name("ProtonX.lock")
}

@MainActor
final class SystemIntegration: NSObject {
    static let shared = SystemIntegration()
    var openPass: (() -> Void)?
    var openMail: (() -> Void)?
    var openSettings: (() -> Void)?
    var lockSuite: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var monitors: [Any] = []
    private var localMonitor: Any?
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var configured = false

    func configure() {
        updateMenuBar()
        updateHotKey()
        guard !configured else { return }; configured = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.lastActivity = ProcessInfo.processInfo.systemUptime }; return event
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            monitors.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockSuite?() }
            })
        }
        monitors.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockSuite?() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = UserDefaults.standard.integer(forKey: "autoLockSeconds")
                if ProcessInfo.processInfo.systemUptime - self.lastActivity >= Double(seconds == 0 ? 300 : seconds) {
                    self.lockSuite?(); self.lastActivity = ProcessInfo.processInfo.systemUptime
                }
            }
        }
    }
    func updateMenuBar() {
        guard Bundle.main.bundleIdentifier != "org.kevb.ProtonX.Preview" else { return }
        let enabled = UserDefaults.standard.object(forKey: "menuBarEnabled") as? Bool ?? true
        if !enabled { if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil; return }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "ProtonX")
        item.button?.toolTip = "ProtonX · Pass and Mail"
        let menu = NSMenu()
        menu.addItem(actionItem("Open Pass", #selector(showPass)))
        menu.addItem(actionItem("Open Mail", #selector(showMail)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Lock ProtonX", #selector(lockNow)))
        menu.addItem(actionItem("Settings…", #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit ProtonX", #selector(quit)))
        item.menu = menu; statusItem = item
    }
    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; return item
    }
    @objc private func showPass() { openPass?(); lastActivity = ProcessInfo.processInfo.systemUptime }
    @objc private func showMail() { openMail?(); lastActivity = ProcessInfo.processInfo.systemUptime }
    @objc private func showSettings() { openSettings?() }
    @objc private func lockNow() { lockSuite?() }
    @objc private func quit() { lockSuite?(); NSApp.terminate(nil) }
    func updateHotKey() {
        guard Bundle.main.bundleIdentifier != "org.kevb.ProtonX.Preview" else { return }
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        guard UserDefaults.standard.bool(forKey: "quickAccessEnabled") else { return }
        if hotKeyHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in
                    SystemIntegration.shared.showPass()
                    NotificationCenter.default.post(name: .protonXFocusSearch, object: nil)
                }; return noErr
            }, 1, &type, nil, &hotKeyHandler)
        }
        let id = EventHotKeyID(signature: 0x50585458, id: 1)
        // Control–Option–P, opt-in and registered only once for the entire suite.
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { UserDefaults.standard.set(false, forKey: "quickAccessEnabled") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SystemIntegration.shared.lockSuite?() }
    }
}
