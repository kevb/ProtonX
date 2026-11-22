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
struct CalendarReminderOptions: Equatable {
    static let allowedLeadMinutes = [0, 5, 10, 15, 30]
    var enabled = false
    var leadMinutes = 15
    var sound = true
    var previews = false
}
struct DesktopNotice: Equatable {
    let id: String
    let title: String
    let body: String
    let sound: Bool
    let deliverAt: Date?
    init(id: String, title: String, body: String, sound: Bool, deliverAt: Date? = nil) {
        self.id = id; self.title = title; self.body = body; self.sound = sound; self.deliverAt = deliverAt
    }
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
    @Published private(set) var calendarOptions: CalendarReminderOptions
    @Published private(set) var working = false
    @Published private(set) var status: String?
    var configurationChanged: (() -> Void)?
    var calendarConfigurationChanged: (() -> Void)?
    var openMail: (((folder: UInt64, item: UInt64)?) -> Void)?
    var openCalendar: ((String?) -> Void)?
    private let backend: any DesktopNotifying
    private let defaults: UserDefaults
    private var session: UUID?
    private var routes: [String: (session: UUID, folder: UInt64, item: UInt64)] = [:]
    private var order: [String] = []
    private var delivered: Set<UInt64> = []
    private var generation: UInt64 = 0
    private var calendarSession: UUID?
    private var calendarRoutes: [String: (session: UUID, eventID: String)] = [:]
    private var calendarOrder: [String] = []
    private var calendarDelivered: Set<String> = []
    private var calendarGeneration: UInt64 = 0

    init(backend: any DesktopNotifying, defaults: UserDefaults = .standard) {
        self.backend = backend; self.defaults = defaults
        options = MailNotificationOptions(enabled: defaults.bool(forKey: "mailNotificationsEnabled"),
            sound: defaults.object(forKey: "mailNotificationSound") as? Bool ?? true,
            badge: defaults.object(forKey: "mailNotificationBadge") as? Bool ?? true,
            previews: defaults.bool(forKey: "mailNotificationPreviews"))
        let savedLead = defaults.object(forKey: "calendarReminderLeadMinutes") as? Int ?? 15
        calendarOptions = CalendarReminderOptions(
            enabled: defaults.bool(forKey: "calendarRemindersEnabled"),
            leadMinutes: CalendarReminderOptions.allowedLeadMinutes.contains(savedLead) ? savedLead : 15,
            sound: defaults.object(forKey: "calendarReminderSound") as? Bool ?? true,
            previews: defaults.bool(forKey: "calendarReminderPreviews")
        )
    }
    var active: Bool { options.enabled && permission == .authorized }
    var calendarActive: Bool { calendarOptions.enabled && permission == .authorized }
    func install() {
        clearMail()
        clearCalendar()
        (backend as? MacNotificationBackend)?.install { [weak self] id in self?.clicked(id) }
        Task { await refreshPermission() }
    }
    func refreshPermission() async {
        let next = await backend.permission()
        guard next != permission else { return }
        permission = next
        if !active { clearMail() }
        if !calendarActive { clearCalendar() }
        configurationChanged?()
        calendarConfigurationChanged?()
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
    func updateCalendar(_ change: (inout CalendarReminderOptions) -> Void) {
        var next = calendarOptions; change(&next)
        if !CalendarReminderOptions.allowedLeadMinutes.contains(next.leadMinutes) { next.leadMinutes = 15 }
        guard next != calendarOptions else { return }
        calendarOptions = next
        defaults.set(next.enabled, forKey: "calendarRemindersEnabled")
        defaults.set(next.leadMinutes, forKey: "calendarReminderLeadMinutes")
        defaults.set(next.sound, forKey: "calendarReminderSound")
        defaults.set(next.previews, forKey: "calendarReminderPreviews")
        removePendingCalendarReminders()
        calendarConfigurationChanged?()
    }
    func beginCalendar() {
        clearCalendar()
        calendarSession = UUID()
    }
    func clearCalendar() {
        calendarGeneration &+= 1
        calendarSession = nil
        calendarDelivered = []
        removePendingCalendarReminders()
    }
    private func removePendingCalendarReminders() {
        let ids = calendarOrder
        calendarRoutes = [:]; calendarOrder = []
        if !ids.isEmpty { backend.remove(ids) }
    }
    private static func sanitizeReminderText(_ text: String, maxLength: Int) -> String {
        let cleaned = String(text.unicodeScalars.filter { $0.properties.generalCategory != .control })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength - 1)) + "…"
    }
    func syncCalendarReminders(_ events: [CalendarEventRecord], now: Date = Date()) async {
        calendarGeneration &+= 1
        removePendingCalendarReminders()
        guard calendarActive, let captured = calendarSession else { return }
        let version = calendarGeneration
        let horizon = now.addingTimeInterval(48 * 3600)
        let leadSeconds = TimeInterval(calendarOptions.leadMinutes * 60)
        let upcoming: [(event: CalendarEventRecord, start: Date)] = events.compactMap { event in
            guard case .timed(let start, _, _) = event.time, start >= now, start <= horizon else { return nil }
            return (event, start)
        }.sorted { ($0.start, $0.event.id) < ($1.start, $1.event.id) }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        for entry in upcoming.prefix(32) {
            guard calendarActive, calendarGeneration == version, calendarSession == captured, !Task.isCancelled else { return }
            let fireDate = entry.start.addingTimeInterval(-leadSeconds)
            let deliveryKey = "\(entry.event.id)@\(Int64(entry.start.timeIntervalSince1970))"
            let deliverAt: Date?
            if fireDate <= now {
                guard calendarDelivered.insert(deliveryKey).inserted else { continue }
                deliverAt = nil
            } else {
                deliverAt = fireDate
            }
            if calendarDelivered.count > 1024 { calendarDelivered = [deliveryKey] }
            let id = "cal-" + UUID().uuidString
            calendarRoutes[id] = (captured, entry.event.id)
            calendarOrder.append(id)
            let title: String
            let body: String
            if calendarOptions.previews {
                let safeTitle = Self.sanitizeReminderText(entry.event.title, maxLength: 160)
                title = safeTitle.isEmpty ? "Upcoming Calendar event" : safeTitle
                let when = formatter.string(from: entry.start)
                let location = Self.sanitizeReminderText(entry.event.location, maxLength: 120)
                if calendarOptions.leadMinutes == 0 {
                    body = location.isEmpty ? "Starts at \(when)" : "Starts at \(when) · \(location)"
                } else {
                    body = location.isEmpty ? "Starts at \(when) (in \(calendarOptions.leadMinutes) min)" : "Starts at \(when) · \(location)"
                }
            } else {
                title = "Upcoming Calendar event"
                body = calendarOptions.leadMinutes == 0
                    ? "An event is starting now. Open ProtonX Calendar to view."
                    : "An event starts in \(calendarOptions.leadMinutes) minutes. Open ProtonX Calendar to view."
            }
            let notice = DesktopNotice(id: id, title: title, body: body, sound: calendarOptions.sound, deliverAt: deliverAt)
            do { try await backend.add(notice) }
            catch { calendarRoutes[id] = nil; calendarOrder.removeAll { $0 == id } }
            if calendarGeneration != version || calendarSession != captured || Task.isCancelled {
                backend.remove([id]); calendarRoutes[id] = nil; calendarOrder.removeAll { $0 == id }
            }
        }
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
        if id.hasPrefix("cal-") || calendarRoutes[id] != nil {
            let route = calendarRoutes[id]
            backend.remove([id]); calendarRoutes[id] = nil; calendarOrder.removeAll { $0 == id }
            guard let route, calendarSession == route.session, calendarActive else { openCalendar?(nil); return }
            openCalendar?(route.eventID)
            return
        }
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
        let trigger: UNNotificationTrigger?
        if let deliverAt = notice.deliverAt {
            let interval = deliverAt.timeIntervalSinceNow
            trigger = interval > 1 ? UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false) : nil
        } else {
            trigger = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger)) { error in
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
