// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import UserNotifications
import ProtonXCore

enum NotificationPermission: Equatable, Sendable { case unknown, notDetermined, denied, authorized, unavailable }
struct MailNotificationOptions: Equatable {
    var enabled = false
    var sound = true
    var badge = true
    var previews = false
}
struct DesktopNotice: Equatable {
    let id: String
    let title: String
    let body: String
    let sound: Bool
}
@MainActor protocol DesktopNotifying: AnyObject {
    func permission() async -> NotificationPermission
    func authorize() async throws -> Bool
    func add(_ notice: DesktopNotice) async throws
    func remove(_ ids: [String])
    func clear()
    func badge(_ count: UInt64?)
}

/// OS integration contains opaque, in-memory routing tickets, never account IDs,
/// server IDs, session keys or message bodies. Only explicit previews disclose metadata.
@MainActor final class NativeNotifications: ObservableObject {
    static let shared = NativeNotifications(backend: MacNotificationBackend())
    @Published private(set) var permission: NotificationPermission = .unknown
    @Published private(set) var options: MailNotificationOptions
    @Published private(set) var working = false
    @Published private(set) var status: String?
    var configurationChanged: (() -> Void)?
    var openMail: (((folder: UInt64, item: UInt64)?) -> Void)?
    private let backend: any DesktopNotifying
    private let defaults: UserDefaults
    private var session: UUID?
    private var routes: [String: (session: UUID, folder: UInt64, item: UInt64)] = [:]
    private var order: [String] = []
    private var delivered: Set<UInt64> = []
    private var generation: UInt64 = 0

    init(backend: any DesktopNotifying, defaults: UserDefaults = .standard) {
        self.backend = backend; self.defaults = defaults
        options = MailNotificationOptions(enabled: defaults.bool(forKey: "mailNotificationsEnabled"),
            sound: defaults.object(forKey: "mailNotificationSound") as? Bool ?? true,
            badge: defaults.object(forKey: "mailNotificationBadge") as? Bool ?? true,
            previews: defaults.bool(forKey: "mailNotificationPreviews"))
    }
    var active: Bool { options.enabled && permission == .authorized }
    func install() {
        clearMail()
        (backend as? MacNotificationBackend)?.install { [weak self] id in self?.clicked(id) }
        Task { await refreshPermission() }
    }
    func refreshPermission() async {
        let next = await backend.permission()
        guard next != permission else { return }
        permission = next
        if !active { clearMail() }
        configurationChanged?()
    }
    func enable() async {
        guard !working else { return }; working = true; status = nil
        defer { working = false }
        do {
            let allowed = try await backend.authorize()
            await refreshPermission()
            if allowed { update { $0.enabled = true } }
            else { status = "Notifications are off in macOS. You can enable them in System Settings." }
        } catch { status = "macOS could not enable notifications. Try again in System Settings." }
    }
    func update(_ change: (inout MailNotificationOptions) -> Void) {
        var next = options; change(&next)
        guard next != options else { return }
        options = next
        defaults.set(next.enabled, forKey: "mailNotificationsEnabled")
        defaults.set(next.sound, forKey: "mailNotificationSound")
        defaults.set(next.badge, forKey: "mailNotificationBadge")
        defaults.set(next.previews, forKey: "mailNotificationPreviews")
        // Remove previously disclosed previews as soon as their policy changes.
        clearMail(); configurationChanged?()
    }
    func beginMail() { clearMail(); session = UUID() }
    func clearMail() {
        generation &+= 1; session = nil; routes = [:]; order = []; delivered = []
        backend.clear(); backend.badge(nil)
    }
    func monitorUnavailable() {
        clearMail(); status = "Mail alerts are paused. Unlock Mail again or toggle notifications to retry."
    }
    func receive(_ batch: [NativeMailNotification], unread: UInt64) async {
        guard active, let captured = session, batch.count <= 64, (try? batch.forEach { try $0.validate() }) != nil else { return }
        let version = generation
        backend.badge(options.badge && unread > 0 ? unread : nil)
        let fresh = batch.filter { delivered.insert($0.id).inserted }
        // Dedupe state is bounded; SDK separately bounds CREATE-event replay.
        if delivered.count > 4096 { delivered = Set(fresh.map(\.id)) }
        guard !fresh.isEmpty else { return }
        let grouped = fresh.count > 3
        let notices = grouped ? [fresh[0]] : fresh
        for message in notices {
            guard active, generation == version, session == captured, !Task.isCancelled else { return }
            let id = UUID().uuidString
            routes[id] = (captured, message.folder, message.id); order.append(id)
            if order.count > 64 { let expired = order.removeFirst(); routes[expired] = nil; backend.remove([expired]) }
            let notice = DesktopNotice(id: id, title: grouped ? "New emails received" : "New email received",
                body: grouped ? "\(fresh.count) new messages in Mail." : (options.previews ? "From: \(message.sender) — \(message.subject)" : "Open ProtonX Mail to read your message."), sound: options.sound)
            do { try await backend.add(notice) }
            catch { routes[id] = nil; status = "An alert could not be delivered. Check macOS notification settings." }
            // A late OS completion must not resurrect a preview after locking.
            if generation != version || session != captured || Task.isCancelled { backend.remove([id]) }
        }
    }
    func clicked(_ id: String) {
        let route = routes[id]
        backend.remove([id]); routes[id] = nil; order.removeAll { $0 == id }
        guard let route, session == route.session, active else { openMail?(nil); return }
        openMail?((route.folder, route.item))
    }
    func testAlert() async {
        guard active, !working else { return }; working = true; status = nil
        let version = generation, id = UUID().uuidString
        defer { working = false }
        do {
            try await backend.add(DesktopNotice(id: id, title: "ProtonX notifications", body: "You’re ready. New Mail alerts will appear here.", sound: options.sound))
            if generation != version { backend.remove([id]) }
            else { status = "Test alert sent. Its appearance follows your macOS settings and Focus mode." }
        } catch { status = "The test alert could not be delivered. Check macOS notification settings." }
    }
    func openSystemSettings() {
        guard Bundle.main.bundleIdentifier != "org.kevb.ProtonX.Preview" else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
}

@MainActor private final class MacNotificationBackend: DesktopNotifying {
    // UNUserNotificationCenter requires a real application bundle, not swift test.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == "org.kevb.ProtonX" ? .current() : nil
    }
    private var delegate: MacNotificationDelegate?
    func install(_ clicked: @escaping @MainActor (String) -> Void) {
        guard let center else { return }
        let delegate = MacNotificationDelegate(clicked: clicked); self.delegate = delegate; center.delegate = delegate
    }
    func permission() async -> NotificationPermission {
        guard let center else { return .unavailable }
        // Project the callback to a value instead of transferring the SDK's
        // non-Sendable settings object into the main actor on older toolchains.
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let permission: NotificationPermission
                switch settings.authorizationStatus {
                case .notDetermined: permission = .notDetermined
                case .denied: permission = .denied
                case .authorized, .provisional, .ephemeral: permission = .authorized
                @unknown default: permission = .denied
                }
                continuation.resume(returning: permission)
            }
        }
    }
    func authorize() async throws -> Bool {
        guard let center else { return false }
        return try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }
    func add(_ notice: DesktopNotice) async throws {
        guard let center else { throw CancellationError() }
        let content = UNMutableNotificationContent()
        content.title = notice.title; content.body = notice.body
        content.userInfo = ["ticket": notice.id]
        if notice.sound { content.sound = .default }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func remove(_ ids: [String]) { center?.removePendingNotificationRequests(withIdentifiers: ids); center?.removeDeliveredNotifications(withIdentifiers: ids) }
    func clear() { center?.removeAllPendingNotificationRequests(); center?.removeAllDeliveredNotifications() }
    func badge(_ count: UInt64?) {
        guard center != nil else { return }
        NSApp.dockTile.badgeLabel = count.map { $0 > 999 ? "999+" : String($0) }
    }
}
private final class MacNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    let clicked: @MainActor @Sendable (String) -> Void
    init(clicked: @escaping @MainActor @Sendable (String) -> Void) { self.clicked = clicked }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["ticket"] as? String
        if let id { Task { @MainActor [clicked] in clicked(id) } }
        completionHandler()
    }
}
