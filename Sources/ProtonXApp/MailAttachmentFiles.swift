// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import QuickLookUI
import SwiftUI
import Darwin
import ProtonXCore

/// Plaintext exists only for an explicitly chosen save/open/preview, never to move IPC bytes.
enum MailAttachmentFiles {
    static func readUpload(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw NativeMailFailure.attachmentFailed }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw NativeMailFailure.attachmentFailed }
        guard info.st_size <= MailAttachmentPolicy.maxBytes else { throw NativeMailFailure.attachmentTooLarge }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: MailAttachmentPolicy.maxBytes + 1) ?? Data()
        guard bytes.count <= MailAttachmentPolicy.maxBytes else { throw NativeMailFailure.attachmentTooLarge }
        return bytes
    }
    static func canPreview(_ name: String) -> Bool {
        ["pdf", "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "txt", "csv"].contains((name as NSString).pathExtension.lowercased())
    }
    /// O_EXCL + O_NOFOLLOW prevents a downloaded filename selecting any existing file.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NativeMailFailure.attachmentFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize()
            // Preserve macOS's untrusted-download boundary even for explicitly saved files.
            let value = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));ProtonX;\(UUID().uuidString)"
            let status = value.withCString { pointer in fsetxattr(fd, "com.apple.quarantine", pointer, strlen(pointer), 0, 0) }
            guard status == 0 else { throw NativeMailFailure.attachmentFailed }
            try handle.close()
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: url); throw error }
    }
    static func save(_ data: Data, to destination: URL) throws {
        let access = destination.startAccessingSecurityScopedResource(); defer { if access { destination.stopAccessingSecurityScopedResource() } }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".protonx-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try writePrivate(data, to: staged)
        // Atomic rename replaces the selected directory entry, never follows a symlink.
        guard Darwin.rename(staged.path, destination.path) == 0 else { throw NativeMailFailure.attachmentFailed }
    }
}
@MainActor final class MailAttachmentPreview: Identifiable {
    let id = UUID()
    let url: URL
    private let directory: URL
    init(name: String, bytes: Data) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonX-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent(MailAttachmentPolicy.filename(name))
        do { try MailAttachmentFiles.writePrivate(bytes, to: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
struct MailAttachmentQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false; view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil; view.close() }
}
