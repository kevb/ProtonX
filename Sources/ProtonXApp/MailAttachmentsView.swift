// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ProtonXCore

struct MailAttachmentsView: View {
    @ObservedObject var store: NativeMailStore
    var composing = false
    private var list: [NativeMailAttachment] { composing ? (store.draft?.attachmentList ?? []) : store.attachmentList }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Attachments", systemImage: "paperclip").font(.headline)
                if !list.isEmpty { Text("\(list.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if composing {
                    Button("Attach files…", systemImage: "plus") { chooseFiles() }.buttonStyle(.plain).foregroundStyle(MailTheme.accent).disabled(store.busy || store.attachmentBusy || store.attachmentNeedsRefresh || store.draft?.state != .editing)
                }
            }
            if store.attachmentBusy {
                HStack { ProgressView().controlSize(.small); Text(store.attachmentStatus ?? "Transferring attachment…").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("Cancel") { store.cancelAttachmentTransfer() }.buttonStyle(.plain)
                }
            }
            ForEach(list) { file in
                HStack(spacing: 12) {
                    Image(systemName: symbol(file)).font(.system(size: 21)).foregroundStyle(MailTheme.accent).frame(width: 36, height: 40)
                        .background(MailTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(2).textSelection(.enabled)
                        Text(details(file)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if composing {
                        Button { store.removeDraftAttachment(file.id) } label: { Image(systemName: "xmark").accessibilityLabel("Remove \(file.name)") }
                            .buttonStyle(.plain).disabled(store.busy || store.attachmentBusy || store.attachmentNeedsRefresh || store.draft?.state != .editing)
                    } else {
                        if MailAttachmentFiles.canPreview(file.name) {
                            Button("Preview") { store.downloadAttachment(file, action: .preview) }.buttonStyle(.plain).foregroundStyle(MailTheme.accent)
                        }
                        Button { save(file) } label: { Image(systemName: "arrow.down.to.line").accessibilityLabel("Save \(file.name)…") }.buttonStyle(.plain).foregroundStyle(MailTheme.accent)
                    }
                }.padding(12).background(MailTheme.collection, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(!composing && (store.busy || store.attachmentBusy || file.size > MailAttachmentPolicy.maxBytes))
                    .help(file.size > MailAttachmentPolicy.maxBytes ? "This file exceeds ProtonX’s current 25 MB limit." : file.name)
            }
            if let error = store.attachmentError {
                HStack(alignment: .top) { Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer(); Button("Refresh list") { composing ? store.refreshDraftAttachments() : store.refreshAttachments() }.buttonStyle(.plain).disabled(store.busy || store.attachmentBusy)
                }
            }
            if composing && list.isEmpty { Text("Choose files or drop them here. Proton’s message and account limits apply.").font(.caption).foregroundStyle(.secondary) }
        }.padding(18)
            .background(composing ? MailTheme.collection.opacity(0.5) : MailTheme.canvas, in: RoundedRectangle(cornerRadius: 14))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard composing, !store.busy, !store.attachmentBusy, store.draft?.state == .editing else { return false }
                // Decode paths only from a user drop; never pass paths into the helper.
                store.acceptDroppedFiles(providers); return true
            }
    }
    private func symbol(_ file: NativeMailAttachment) -> String {
        if file.mime == "application/pdf" { return "doc.richtext" }
        if file.mime.hasPrefix("image/") { return "photo" }
        return "doc"
    }
    private func details(_ file: NativeMailAttachment) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)
        switch file.state { case .available, .uploaded: return size; case .uploading, .pending: return size + " · Uploading…"; case .offline: return size + " · Waiting for connection"; case .failed: return size + " · Upload failed" }
    }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; panel.prompt = "Attach"
        let session = store.filePanelContext, token = store.draft?.token
        panel.begin { result in if result == .OK, store.filePanelContext == session, store.draft?.token == token { store.addDraftAttachments(panel.urls) } }
    }
    private func save(_ file: NativeMailAttachment) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name; panel.title = "Save attachment"; panel.prompt = "Save"
        // Capture the selection now: if it changes while the panel is open, refuse the old action.
        let item = store.selectedMessage?.id, folder = store.selectedFolder, session = store.filePanelContext
        panel.begin { result in
            if result == .OK, let url = panel.url, store.selectedMessage?.id == item, store.selectedFolder == folder, store.filePanelContext == session { store.downloadAttachment(file, action: .save(url)) }
        }
    }
}
struct MailAttachmentPreviewSheet: View {
    let preview: MailAttachmentPreview
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "paperclip").foregroundStyle(MailTheme.accent); Text(preview.url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer(); Button("Open in app") { NSWorkspace.shared.open(preview.url) }.help("Opens a temporary copy in the default app. That app may keep its own copy.")
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider(); MailAttachmentQuickLook(url: preview.url)
        }.frame(minWidth: 640, minHeight: 500)
    }
}
