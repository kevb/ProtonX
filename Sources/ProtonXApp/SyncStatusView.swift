// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum SyncTimeFormatter {
    static func label(for date: Date, now: Date = Date(), prefix: String = "Updated") -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 45 { return "\(prefix) just now" }
        if elapsed < 3600 {
            let minutes = max(1, Int(elapsed / 60))
            return "\(prefix) \(minutes)m ago"
        }
        if elapsed < 86_400 {
            let hours = max(1, Int(elapsed / 3600))
            return "\(prefix) \(hours)h ago"
        }
        return "\(prefix) \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct ToolbarSyncPill: View {
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toolbarSyncStatus")
    }
}

struct SyncStatusIndicator: View {
    let isSyncing: Bool
    let syncingLabel: String
    let lastSynced: Date?
    let warning: String?
    let savedOnly: Bool
    var prefix: String = "Updated"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                if isSyncing {
                    ProgressView().controlSize(.mini)
                    Text(syncingLabel).foregroundStyle(.secondary)
                } else if let warning {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(warning).foregroundStyle(.orange)
                } else if savedOnly {
                    Image(systemName: "internaldrive").foregroundStyle(PassTheme.accent)
                    if let lastSynced {
                        Text("Saved · \(SyncTimeFormatter.label(for: lastSynced, now: context.date, prefix: prefix))").foregroundStyle(.secondary)
                    } else {
                        Text("Saved on this Mac").foregroundStyle(.secondary)
                    }
                } else if let lastSynced {
                    Circle().fill(Color.green).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(SyncTimeFormatter.label(for: lastSynced, now: context.date, prefix: prefix)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }
}
