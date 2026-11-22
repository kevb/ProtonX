// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ServiceManagement
import SwiftUI

enum LoginItemStatus: Equatable, Sendable {
    case enabled, notRegistered, requiresApproval, unavailable
}

@MainActor protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor private final class MacLoginItemBackend: LoginItemControlling {
    private var available: Bool { Bundle.main.bundleIdentifier == "org.kevb.ProtonX" }
    var status: LoginItemStatus {
        guard available else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .unavailable
        }
    }
    func register() throws {
        guard available else { return }
        try SMAppService.mainApp.register()
    }
    func unregister() throws {
        guard available else { return }
        try SMAppService.mainApp.unregister()
    }
}

@MainActor final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager(backend: MacLoginItemBackend())
    @Published private(set) var status: LoginItemStatus = .unavailable
    @Published private(set) var message: String?
    private let backend: any LoginItemControlling
    private let previewOnly: Bool

    init(backend: any LoginItemControlling, previewOnly: Bool = Bundle.main.bundleIdentifier == "org.kevb.ProtonX.Preview") {
        self.backend = backend
        self.previewOnly = previewOnly
        refresh()
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = previewOnly ? .unavailable : backend.status
        if status == .requiresApproval {
            message = "Approve ProtonX under macOS System Settings → General → Login Items."
        } else if status == .enabled || status == .notRegistered {
            message = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !previewOnly, backend.status != .unavailable else {
            status = .unavailable
            message = "Launch at login is available in the installed ProtonX app."
            return
        }
        message = nil
        do {
            if enabled { try backend.register() } else { try backend.unregister() }
            refresh()
        } catch {
            refresh()
            message = enabled
                ? "macOS could not enable launch at login. Check System Settings → General → Login Items."
                : "macOS could not disable launch at login. Check System Settings → General → Login Items."
        }
    }

    func openSystemLoginItems() {
        guard !previewOnly else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum MenuBarBadgeFormatter {
    static func label(for unread: UInt64?) -> String? {
        guard let unread, unread > 0 else { return nil }
        return unread > 99 ? "99+" : String(unread)
    }
}
