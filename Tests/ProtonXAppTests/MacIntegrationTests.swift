// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@MainActor private final class SyntheticLoginItemBackend: LoginItemControlling {
    var status: LoginItemStatus = .notRegistered
    var shouldThrow = false
    var nextStatusOnRegister: LoginItemStatus = .enabled
    var registerCalls = 0
    var unregisterCalls = 0
    func register() throws {
        registerCalls += 1
        if shouldThrow { throw ProtonXError.invalidResponse }
        status = nextStatusOnRegister
    }
    func unregister() throws {
        unregisterCalls += 1
        if shouldThrow { throw ProtonXError.invalidResponse }
        status = .notRegistered
    }
}

@MainActor private final class MenuBarNotificationSink: DesktopNotifying {
    func permission() async -> NotificationPermission { .authorized }
    func authorize() async throws -> Bool { true }
    func add(_ notice: DesktopNotice) async throws {}
    func remove(_ ids: [String]) {}
    func clear() {}
    func badge(_ count: UInt64?) {}
}

@Suite @MainActor struct MacIntegrationTests {
    @Test func loginItemRegistersUnregistersHandlesApprovalAndFailures() {
        let backend = SyntheticLoginItemBackend()
        let manager = LoginItemManager(backend: backend, previewOnly: false)
        #expect(manager.status == .notRegistered && !manager.isEnabled && manager.message == nil)

        manager.setEnabled(true)
        #expect(backend.registerCalls == 1 && manager.status == .enabled && manager.isEnabled && manager.message == nil)

        manager.setEnabled(false)
        #expect(backend.unregisterCalls == 1 && manager.status == .notRegistered && !manager.isEnabled)

        backend.nextStatusOnRegister = .requiresApproval
        manager.setEnabled(true)
        #expect(manager.status == .requiresApproval && manager.isEnabled)
        #expect(manager.message?.contains("Login Items") == true)

        backend.shouldThrow = true
        manager.setEnabled(false)
        #expect(manager.message?.contains("could not disable") == true)
    }

    @Test func loginItemPreviewNeverRegistersWithMacOS() {
        let backend = SyntheticLoginItemBackend()
        let preview = LoginItemManager(backend: backend, previewOnly: true)
        #expect(preview.status == .unavailable && !preview.isEnabled)
        preview.setEnabled(true)
        #expect(backend.registerCalls == 0 && preview.status == .unavailable)
    }

    @Test func menuBarBadgeFormatterBoundsLargeUnreadCounts() {
        #expect(MenuBarBadgeFormatter.label(for: nil) == nil)
        #expect(MenuBarBadgeFormatter.label(for: 0) == nil)
        #expect(MenuBarBadgeFormatter.label(for: 1) == "1")
        #expect(MenuBarBadgeFormatter.label(for: 99) == "99")
        #expect(MenuBarBadgeFormatter.label(for: 100) == "99+")
        #expect(MenuBarBadgeFormatter.label(for: 4096) == "99+")
    }

    @Test func notificationsReportUnreadChangesForMenuBarAndClearOnReset() async {
        let defaults = UserDefaults(suiteName: "ProtonXMacIntegrationTests." + UUID().uuidString)!
        let notifications = NativeNotifications(backend: MenuBarNotificationSink(), defaults: defaults)
        var observed: [UInt64?] = []
        notifications.unreadCountChanged = { observed.append($0) }

        await notifications.refreshPermission()
        notifications.update { $0.enabled = true }
        notifications.beginMail()
        observed.removeAll()

        await notifications.receive([NativeMailNotification(id: 1, folder: 1, sender: "Sam", subject: "Synthetic")], unread: 4)
        #expect(observed == [4])

        await notifications.receive([], unread: 0)
        #expect(observed == [4, nil])

        notifications.clearMail()
        #expect(observed == [4, nil, nil])
    }
}
