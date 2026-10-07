// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@MainActor private final class NotificationSink: DesktopNotifying {
    var allowed: NotificationPermission = .authorized
    var notices: [DesktopNotice] = []
    var removed: [String] = []
    var dock: UInt64?
    var authorizationCalls = 0
    var gate: CheckedContinuation<Void, Never>?
    var suspendAdd = false
    var addStarted = false
    func permission() async -> NotificationPermission { allowed }
    func authorize() async throws -> Bool { authorizationCalls += 1; return allowed == .authorized }
    func add(_ notice: DesktopNotice) async throws {
        addStarted = true
        if suspendAdd { await withCheckedContinuation { gate = $0 } }
        notices.append(notice)
    }
    func remove(_ ids: [String]) { removed += ids; notices.removeAll { ids.contains($0.id) } }
    func clear() { notices = [] }
    func badge(_ count: UInt64?) { dock = count }
}
@MainActor private func notificationFixture(_ sink: NotificationSink) async -> NativeNotifications {
    let name = "ProtonX.notification.test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    let controller = NativeNotifications(backend: sink, defaults: defaults)
    await controller.refreshPermission(); controller.update { $0.enabled = true }; controller.beginMail()
    defaults.removePersistentDomain(forName: name)
    return controller
}
@MainActor private func awaitNotification(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw ProtonXError.cancelled }
        try await Task.sleep(for: .milliseconds(2))
    }
}
private let syntheticAlert = NativeMailNotification(id: 11, folder: 1, sender: "Sam Example", subject: "Coffee on Saturday?")

@Test @MainActor func nativeAlertsArePrivateAndUseOpaqueSessionScopedClickTickets() async {
    let sink = NotificationSink(), controller = await notificationFixture(sink)
    var opened: (folder: UInt64, item: UInt64)?
    controller.openMail = { opened = $0 }
    await controller.receive([syntheticAlert], unread: 8)
    #expect(sink.dock == 8); #expect(sink.notices.count == 1)
    let notice = sink.notices[0]
    #expect(UUID(uuidString: notice.id) != nil); #expect(!notice.body.contains("Sam")); #expect(!notice.body.contains("Coffee"))
    controller.clicked(notice.id); #expect(opened?.item == 11); #expect(opened?.folder == 1)
    opened = nil; controller.clicked(notice.id); #expect(opened == nil)
    controller.clearMail(); #expect(sink.dock == nil)
}
@Test @MainActor func notificationPreviewsSoundBadgeAndPermissionRevocation() async {
    let sink = NotificationSink(), controller = await notificationFixture(sink)
    controller.update { $0.previews = true; $0.sound = false; $0.badge = false }; controller.beginMail()
    await controller.receive([syntheticAlert], unread: 2)
    #expect(sink.dock == nil); #expect(sink.notices.first?.sound == false)
    #expect(sink.notices.first?.body.contains("Sam Example") == true)
    sink.allowed = .denied; await controller.refreshPermission()
    #expect(!controller.active); #expect(sink.notices.isEmpty)
    await controller.receive([syntheticAlert], unread: 2); #expect(sink.notices.isEmpty)
}
@Test @MainActor func notificationBatchesDeduplicateGroupAndBoundRouting() async {
    let sink = NotificationSink(), controller = await notificationFixture(sink)
    let alerts = (1...64).map { NativeMailNotification(id: UInt64($0), folder: 1, sender: "Synthetic", subject: "Synthetic") }
    await controller.receive(alerts, unread: 64)
    #expect(sink.notices.count == 1); #expect(sink.notices[0].body == "64 new messages in Mail.")
    await controller.receive(alerts, unread: 64); #expect(sink.notices.count == 1)
    for id in 65...130 { await controller.receive([NativeMailNotification(id: UInt64(id), folder: 1, sender: "Synthetic", subject: "Synthetic")], unread: 0) }
    #expect(sink.notices.count == 64); #expect(sink.dock == nil)
}
@Test @MainActor func notificationLateCompletionCannotRediscloseAfterLockOrSettingsChange() async throws {
    let sink = NotificationSink(), controller = await notificationFixture(sink)
    sink.suspendAdd = true
    let sending = Task { await controller.receive([syntheticAlert], unread: 1) }
    try await awaitNotification { sink.addStarted }
    controller.clearMail(); sink.gate?.resume(); sink.gate = nil
    await sending.value
    #expect(sink.notices.isEmpty); #expect(sink.removed.count == 1); #expect(sink.dock == nil)
    controller.beginMail(); sink.addStarted = false
    let second = Task { await controller.receive([syntheticAlert], unread: 1) }
    try await awaitNotification { sink.addStarted }
    controller.update { $0.previews = true }; sink.gate?.resume(); sink.gate = nil
    await second.value; #expect(sink.notices.isEmpty)
}
@Test @MainActor func notificationEnableIsExplicitAndTestAlertUsesSyntheticText() async {
    let sink = NotificationSink()
    let defaults = UserDefaults(suiteName: "ProtonX.notification.test." + UUID().uuidString)!
    let controller = NativeNotifications(backend: sink, defaults: defaults)
    await controller.refreshPermission(); #expect(sink.authorizationCalls == 0); #expect(!controller.options.enabled)
    await controller.testAlert(); #expect(sink.notices.isEmpty)
    await controller.enable(); #expect(sink.authorizationCalls == 1); #expect(controller.active)
    await controller.testAlert(); #expect(sink.notices.first?.title == "ProtonX notifications")
    controller.update { $0.enabled = false }; #expect(sink.notices.isEmpty)
}

private actor NotificationReplyGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class NotificationMailRunner: NativeMailRunning, @unchecked Sendable {
    let lock = NSLock()
    var methods: [String] = []
    let gate: NotificationReplyGate?
    init(gate: NotificationReplyGate? = nil) { self.gate = gate }
    var calls: [String] { lock.withLock { methods } }
    func cancelAll() {}
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        lock.withLock { methods.append(command.method) }
        switch command.method {
        case "login": return .init(phase: .connected)
        case "snapshot": return .init(folders: [.init(id: 1, name: "Inbox", kind: .inbox)], folder: 1, messages: [.init(id: 11, subject: "Synthetic", sender: "sam@example.com")], loading: false)
        case "notifications_start", "notifications_stop": return .init(notifications: [], unreadCount: 0)
        case "notifications_poll":
            if let gate { await gate.wait() }
            return .init(notifications: [syntheticAlert], unreadCount: 1)
        case "message": return .init(id: 11, body: "Synthetic body")
        default: throw ProtonXError.invalidResponse
        }
    }
}
@Test @MainActor func mailNotificationLoopStopsOnLockAndRejectsLateHelperReply() async throws {
    let gate = NotificationReplyGate(), runner = NotificationMailRunner(gate: gate)
    let sink = NotificationSink(), controller = await notificationFixture(sink)
    let defaults = UserDefaults(suiteName: "ProtonX.notification.mail." + UUID().uuidString)!
    let mail = NativeMailStore(runner: runner, defaults: defaults)
    mail.configureNotifications(controller, interval: .milliseconds(1))
    mail.signIn(username: "alex@example.com", password: "SYNTHETIC")
    try await awaitNotification { await gate.entered }
    mail.lock(); await gate.release()
    for _ in 0..<20 { await Task.yield() }
    #expect(sink.notices.isEmpty); #expect(sink.dock == nil); #expect(mail.messages.isEmpty)
    #expect(runner.calls.filter { $0 == "notifications_poll" }.count == 1)
}
@Test @MainActor func notificationClickSelectsOnlyDisclosedMailAndDoesNotUnlock() async throws {
    let runner = NotificationMailRunner(), mail = NativeMailStore(runner: runner, defaults: UserDefaults(suiteName: "ProtonX.notification.route." + UUID().uuidString)!)
    mail.openNotification(folder: 1, item: 11); #expect(runner.calls.isEmpty)
    mail.signIn(username: "alex@example.com", password: "SYNTHETIC")
    try await awaitNotification { !mail.busy }
    mail.query = "search"; mail.openNotification(folder: 1, item: 11)
    try await awaitNotification { !mail.busy && mail.body != nil }
    #expect(mail.query.isEmpty); #expect(mail.selectedItem == 11)
    mail.openNotification(folder: 1, item: 99)
    try await awaitNotification { !mail.busy }
    #expect(!runner.calls.contains("restore")); #expect(runner.calls.filter { $0 == "message" }.count == 1)
    mail.lock()
}
