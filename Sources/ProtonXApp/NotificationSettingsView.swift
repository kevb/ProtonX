// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NotificationSettingsView: View {
    @ObservedObject var notifications: NativeNotifications = .shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "bell.badge").font(.system(size: 26)).foregroundStyle(PassTheme.accent)
                        .frame(width: 48, height: 48).background(PassTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Stay in the loop").font(.title3.weight(.semibold))
                        Text("New Mail alerts, delivered by macOS.").foregroundStyle(.secondary)
                        Text(permissionText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.vertical, 6)
                if notifications.permission == .notDetermined || notifications.permission == .unknown {
                    Button("Enable notifications…") { Task { await notifications.enable() } }
                        .disabled(notifications.working).accessibilityIdentifier("enableNotifications")
                } else if notifications.permission != .unavailable {
                    Button("Open macOS notification settings…") { notifications.openSystemSettings() }
                }
            }
            Section("Mail") {
                Toggle("New email notifications", isOn: option(\.enabled))
                    .disabled(notifications.permission != .authorized && !notifications.options.enabled)
                Toggle("Play a sound", isOn: option(\.sound)).disabled(!notifications.active)
                Toggle("Unread count on the Dock icon", isOn: option(\.badge)).disabled(!notifications.active)
                Picker("Notification preview", selection: option(\.previews)) {
                    Text("Private — new mail only").tag(false)
                    Text("Sender and subject").tag(true)
                }.disabled(!notifications.active)
                Text("Alerts follow Proton’s Inbox categories and folder notification settings. Imported messages, read mail and Spam are excluded. Alerts continue while you use another product; Mail must be unlocked and ProtonX running.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Sender and subject previews are shared with macOS Notification Center. Locking Mail clears its alerts and Dock count.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { Task { await notifications.testAlert() } } label: { Label("Send test notification", systemImage: "paperplane") }
                    .disabled(!notifications.active || notifications.working).accessibilityIdentifier("testNotification")
                if let status = notifications.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Pass") {
                Label("Vault changes stay quiet", systemImage: "key")
                Text("Like Proton Pass, creating or syncing a vault item doesn’t produce a desktop alert. Sharing and security notices will appear as those features become available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(16)
            .task { await notifications.refreshPermission() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await notifications.refreshPermission() } } }
    }
    private func option<T>(_ key: WritableKeyPath<MailNotificationOptions, T>) -> Binding<T> {
        Binding(get: { notifications.options[keyPath: key] }, set: { value in notifications.update { $0[keyPath: key] = value } })
    }
    private var permissionText: String {
        switch notifications.permission {
        case .unknown: "Checking macOS permission…"
        case .notDetermined: "Choose when to allow notifications."
        case .denied: "Notifications are off in macOS."
        case .authorized: "Allowed by macOS. Banners and Focus follow System Settings."
        case .unavailable: "Notifications are available in the installed ProtonX app."
        }
    }
}
