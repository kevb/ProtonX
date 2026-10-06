import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private final class NoAccountRunner: HelperRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data {
        lock.withLock { count += 1 }
        throw ProtonXError.invalidInput("Synthetic test forbids account access.")
    }
    func cancelAll() {}
    var calls: Int { lock.withLock { count } }
}

@MainActor private func demoStore(_ runner: NoAccountRunner = NoAccountRunner()) -> PassStore {
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: URL(fileURLWithPath: "/nonexistent/protonx-synthetic-tests"), previewOnly: true)
    store.enterDemo()
    return store
}

private final class DelayedSnapshotRunner: HelperRunning, @unchecked Sendable {
    let fail: Bool
    init(fail: Bool) { self.fail = fail }
    func cancelAll() {}
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data {
        if command.arguments.first == "login" { return Data() }
        // Keep the synthetic first list pending even if the store is locked.
        await Task.detached { try? await Task.sleep(for: .milliseconds(120)) }.value
        if fail { throw ProtonXError.invalidInput("Synthetic unavailable network") }
        return Data(#"{"vaults":[],"items":[],"trashed_items":[],"capabilities":{"totp_limit":null,"custom_fields_allowed":true}}"#.utf8)
    }
}

@Test(arguments: [false, true]) @MainActor func passInitialSnapshotDistinguishesLoadingFailureAndConfirmedEmpty(_ fail: Bool) async {
    let store = PassStore(service: PassService(runner: DelayedSnapshotRunner(fail: fail)), sessionDirectory: URL(fileURLWithPath: "/nonexistent/protonx-synthetic-tests"), previewOnly: false)
    store.login()
    let start = ContinuousClock.now
    while store.phase != .open && start.duration(to: .now) < .seconds(2) { await Task.yield() }
    #expect(store.isLoadingInitialSnapshot); #expect(!store.initialSnapshotFailed)
    while store.busy && start.duration(to: .now) < .seconds(2) { await Task.yield() }
    #expect(!store.isLoadingInitialSnapshot); #expect(store.initialSnapshotFailed == fail)
    #expect((store.lastSyncedAt != nil) == !fail)
    store.lock(); #expect(!store.initialSnapshotFailed); #expect(!store.isLoadingInitialSnapshot)
}

@Test @MainActor func filtersImmediatelyClearStaleDetailWithoutWaitingForView() throws {
    let store = demoStore()
    #expect(store.currentItem?.kind == "login"); #expect(store.detail != nil)
    store.kind = "note"
    #expect(store.selectedItem == nil); #expect(store.currentItem == nil); #expect(store.detail == nil)
    store.selectedItem = try #require(store.filteredItems.first).id
    #expect(store.detail != nil)
    store.query = "does not match"
    #expect(store.detail == nil); #expect(store.currentItem == nil)
    store.query = ""; store.selectedItem = store.filteredItems.first?.id
    store.selectedVault = "demo-work"
    #expect(store.detail == nil)
}

@Test @MainActor func syntheticCreateEditTrashRestoreAndLock() async throws {
    let runner = NoAccountRunner(), store = demoStore(runner)
    var draft = NativeItemDraft(); draft.title = "Synthetic created login"; draft.note = "A login note"
    draft.username = "alex"; draft.password = "DEMO-ONLY"; draft.urls = ["https://example.com", "https://example.org"]
    draft.customFields = [CustomFieldDraft(name: "Recovery", value: "SYNTHETIC", concealed: true)]
    try await store.save(draft, item: nil, vaultID: "demo-personal")
    let item = try #require(store.currentItem)
    #expect(store.detail?.note == "A login note"); #expect(store.detail?.urls.count == 2)
    var edit = draft; edit.title = "Synthetic edited login"; edit.urls = nil
    edit.customFields = try #require(store.detail).editableCustomFields
    edit.customFields[0].value = "CHANGED-SYNTHETIC"
    try await store.save(edit, item: item, vaultID: item.shareID)
    #expect(store.detail?.urls.count == 2); #expect(store.detail?.editableCustomFields.first?.value == "CHANGED-SYNTHETIC")
    store.trashCurrent()
    while store.busy { await Task.yield() }
    #expect(!store.items.contains(where: { $0.id == item.id })); #expect(store.trashedItems.contains(where: { $0.id == item.id }))
    store.showingTrash = true; store.selectedItem = item.id
    #expect(store.detail?.title == "Synthetic edited login"); #expect(!store.canEdit)
    store.trashCurrent()
    while store.busy { await Task.yield() }
    #expect(store.trashedItems.isEmpty); #expect(store.items.contains(where: { $0.id == item.id }))
    store.lock()
    #expect(store.items.isEmpty); #expect(store.trashedItems.isEmpty); #expect(store.detail == nil)
    #expect(runner.calls == 0)
}

@Test @MainActor func previewCannotSignIntoAccount() {
    let runner = NoAccountRunner(), store = demoStore(runner)
    store.signOut(); store.login(interactive: true)
    #expect(!store.busy); #expect(runner.calls == 0)
}

private final class SnapshotRunner: HelperRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var refreshes = 0
    private var writes = 0
    var writeCount: Int { lock.withLock { writes } }
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data {
        switch command.arguments.first {
        case "login": return Data()
        case "native-snapshot":
            let first = lock.withLock { refreshes += 1; return refreshes == 1 }
            if !first { throw ProtonXError.helperFailed(1) }
            return Data(#"{"vaults":[{"name":"Synthetic","vault_id":"v","share_id":"s","can_create":true,"can_update":true,"can_trash":true}],"items":[{"id":"existing","share_id":"s","title":"Synthetic existing note","item_type":"note"}],"trashed_items":[],"capabilities":{"totp_limit":null,"custom_fields_allowed":true}}"#.utf8)
        case "native-create":
            lock.withLock { writes += 1 }
            return Data(#"{"item_id":"synthetic-created"}"#.utf8)
        case "native-edit":
            lock.withLock { writes += 1 }
            return Data(#"{"updated":true}"#.utf8)
        case "item":
            if command.arguments.dropFirst().first == "trash" {
                lock.withLock { writes += 1 }
                return Data()
            }
            return Data(#"{"revision":1,"item":{"content":{"title":"Synthetic existing note","note":"Demo","content":{"Note":{}}}}}"#.utf8)
        default: throw ProtonXError.invalidInput("Unexpected synthetic command")
        }
    }
    func cancelAll() {}
}
@Test(arguments: ["create", "edit", "trash"]) @MainActor func acknowledgedWriteKeepsSyncWarningAcrossNavigation(_ action: String) async throws {
    let runner = SnapshotRunner()
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: URL(fileURLWithPath: "/nonexistent/protonx-synthetic-tests"), previewOnly: false)
    store.login()
    while store.busy { await Task.yield() }
    #expect(store.phase == .open)
    let item = try #require(store.items.first)
    store.selectedItem = item.id
    while store.detail == nil && store.error == nil { await Task.yield() }
    #expect(store.detail != nil)
    var draft = NativeItemDraft(); draft.kind = "note"; draft.title = "Synthetic acknowledged save"; draft.note = "Demo"
    draft.expectedRevision = 1
    if action == "trash" {
        store.trashCurrent()
        while store.busy { await Task.yield() }
    } else { try await store.save(draft, item: action == "edit" ? item : nil, vaultID: "s") }
    let warning = try #require(store.error)
    #expect(runner.writeCount == 1); #expect(warning.contains("Refresh failed"))
    #expect(store.currentItem == nil); #expect(!store.busy); #expect(!store.canCreate); #expect(store.mustRefreshBeforeWriting)
    store.selectedItem = item.id
    store.kind = "login"
    #expect(store.selectedItem == nil); #expect(store.error == warning)
}
