// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@Suite("MailEncryptedStorageTests")
@MainActor
struct MailEncryptedStorageTests {
    @Test func storageUpgradeRequiredSurfacesResetAndClearsLegacyCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonX-MailUpgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cache/attachments/1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyDB = root.appendingPathComponent("sessions/account.db")
        let legacyAttachment = root.appendingPathComponent("cache/attachments/1/file.txt")
        try Data("SQLite format 3\0SYNTHETIC".utf8).write(to: legacyDB)
        try Data("SYNTHETIC-ATTACHMENT".utf8).write(to: legacyAttachment)

        let defaults = UserDefaults(suiteName: "ProtonX.MailUpgrade.\(UUID().uuidString)")!
        defaults.set(true, forKey: "nativeMailConnected")
        let runner = UpgradeRequiredRunner()
        let store = NativeMailStore(runner: runner, defaults: defaults, storageDirectory: root, localUnlock: { true })
        #expect(store.phase == .locked)

        store.unlock()
        try await waitFor { !store.busy }
        #expect(store.storageUpgradeRequired)
        #expect(store.error == NativeMailFailure.storageUpgradeRequired.localizedDescription)
        // Legacy files are retained until the user confirms reset.
        #expect(FileManager.default.fileExists(atPath: legacyDB.path))

        store.resetLocalStorageForEncryptedUpgrade()
        #expect(!store.storageUpgradeRequired)
        #expect(store.phase == .welcome)
        #expect(store.error == nil)
        #expect(store.notice?.contains("encrypted storage") == true)
        #expect(!defaults.bool(forKey: "nativeMailConnected"))
        #expect(!FileManager.default.fileExists(atPath: legacyDB.path))
        #expect(!FileManager.default.fileExists(atPath: legacyAttachment.path))
    }

    @Test func resetRefusesSymlinkedStorageDirectoryWithoutDeletingTarget() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonX-MailSymlink-\(UUID().uuidString)")
        let target = base.appendingPathComponent("real-target")
        let link = base.appendingPathComponent("mail-link")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let canary = target.appendingPathComponent("sessions/canary.db")
        try Data("KEEP".utf8).write(to: canary)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }

        let defaults = UserDefaults(suiteName: "ProtonX.MailSymlink.\(UUID().uuidString)")!
        defaults.set(true, forKey: "nativeMailConnected")
        let store = NativeMailStore(runner: UpgradeRequiredRunner(), defaults: defaults, storageDirectory: link, localUnlock: { true })
        store.unlock()
        try await waitFor { !store.busy }
        #expect(store.storageUpgradeRequired)

        store.resetLocalStorageForEncryptedUpgrade()
        #expect(FileManager.default.fileExists(atPath: canary.path))
        #expect(store.error == NativeMailFailure.storageUnavailable.localizedDescription)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        Issue.record("Condition timed out")
    }
}

private final class UpgradeRequiredRunner: NativeMailRunning, @unchecked Sendable {
    func cancelAll() {}
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        throw NativeMailFailure.storageUpgradeRequired
    }
}
