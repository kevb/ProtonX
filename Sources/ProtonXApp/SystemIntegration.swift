import SwiftUI
import AppKit
import Carbon
import ProtonXCore

extension Notification.Name {
    static let protonXNewEvent = Notification.Name("ProtonX.newEvent")
    static let protonXFocusCalendarSearch = Notification.Name("ProtonX.focusCalendarSearch")
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
    var openHome: (() -> Void)?
    var openPassForSearch: (() -> Void)?
    var openPass: (() -> Void)? = { ProductWindows.shared.open(.pass) }
    var openMail: (() -> Void)? = { ProductWindows.shared.open(.mail) }
    var openContacts: (() -> Void)? = { ProductWindows.shared.open(.contacts) }
    var openCalendar: (() -> Void)? = { ProductWindows.shared.open(.calendar) }
    var openSettings: (() -> Void)?
    var lockSuite: (() -> Void)?
    var lockSuiteAutomatically: (() -> Void)?
    var suspendAuthentication: ((Bool) -> Void)?
    enum SystemLockReason: CaseIterable { case sleep, displaySleep, sessionInactive, screenLocked }
    private var systemLocks: Set<SystemLockReason> = []
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
        let workspaceEvents: [(Notification.Name, SystemLockReason, Bool)] = [
            (NSWorkspace.willSleepNotification, .sleep, true),
            (NSWorkspace.didWakeNotification, .sleep, false),
            (NSWorkspace.screensDidSleepNotification, .displaySleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false)
        ]
        for (name, reason, locked) in workspaceEvents {
            monitors.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSystemLock(reason, locked: locked) }
            })
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            monitors.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSystemLock(.screenLocked, locked: locked) }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = UserDefaults.standard.integer(forKey: "autoLockSeconds")
                self.checkInactivity(at: ProcessInfo.processInfo.systemUptime, timeout: Double(seconds == 0 ? 300 : seconds))
            }
        }
    }
    func updateSystemLock(_ reason: SystemLockReason, locked: Bool) {
        if locked {
            guard systemLocks.insert(reason).inserted else { return }
            // Block evaluation before clearing stores/arming their next attempt.
            suspendAuthentication?(true)
            (lockSuiteAutomatically ?? lockSuite)?()
        } else {
            guard systemLocks.remove(reason) != nil, systemLocks.isEmpty else { return }
            // Wake, screen unlock and session activation can arrive independently.
            // Resume only after every observed lock reason has cleared.
            suspendAuthentication?(false)
        }
    }
    func checkInactivity(at uptime: TimeInterval, timeout: TimeInterval) {
        guard uptime - lastActivity >= timeout else { return }
        (lockSuiteAutomatically ?? lockSuite)?()
        lastActivity = uptime
    }
    func updateMenuBar() {
        guard Bundle.main.bundleIdentifier != "org.kevb.ProtonX.Preview" else { return }
        let enabled = UserDefaults.standard.object(forKey: "menuBarEnabled") as? Bool ?? true
        if !enabled { if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil; return }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "ProtonX")
        item.button?.toolTip = "ProtonX · Pass, Mail, Calendar and Contacts"
        let menu = NSMenu()
        menu.addItem(actionItem("Open ProtonX", #selector(showHome)))
        menu.addItem(actionItem("Open Pass", #selector(showPass)))
        menu.addItem(actionItem("Open Mail", #selector(showMail)))
        menu.addItem(actionItem("Open Calendar", #selector(showCalendar)))
        menu.addItem(actionItem("Open Contacts", #selector(showContacts)))
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
    @objc private func showHome() { openHome?(); lastActivity = ProcessInfo.processInfo.systemUptime }
    @objc private func showMail() { openMail?(); lastActivity = ProcessInfo.processInfo.systemUptime }
    @objc private func showContacts() { openContacts?(); lastActivity = ProcessInfo.processInfo.systemUptime }
    @objc private func showCalendar() { openCalendar?(); lastActivity = ProcessInfo.processInfo.systemUptime }
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
                    SystemIntegration.shared.openPassForSearch?()
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
    private var duplicateInstance = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let existing = ProductionInstance.existingPrimary() {
                duplicateInstance = true
                existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                NSApp.terminate(nil)
                return
            }
            NativeNotifications.shared.install()
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !duplicateInstance else { NSApp.terminate(nil); return }
        ProductWindows.shared.didFinishLaunching()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !duplicateInstance else { return }
        ProductWindows.shared.open(urls: urls)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { ProductWindows.shared.showSuite() }
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SystemIntegration.shared.lockSuite?() }
    }
}
