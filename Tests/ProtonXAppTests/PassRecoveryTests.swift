import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

/// Scripted responses only: no account transport, Keychain access or real local unlock.
private final class RecoveryRunner: HelperRunning, @unchecked Sendable {
    struct Step: Sendable {
        let method: String
        var response = ""
        var failure: ProtonXError?
        var delay: Duration = .zero
    }
    private let lock = NSLock()
    private var steps: [Step]
    private var methods: [String] = []
    init(_ steps: [Step]) { self.steps = steps }
    var calls: [String] { lock.withLock { methods } }
    func cancelAll() {}
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data {
        let method = command.arguments.prefix(command.arguments.first == "item" ? 2 : 1).joined(separator: " ")
        let step = lock.withLock {
            methods.append(method)
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        guard let step else { Issue.record("Unexpected synthetic command: \(method)"); throw ProtonXError.invalidResponse }
        #expect(method == step.method)
        // Deliberately ignore cancellation to model a late upstream response.
        if step.delay > .zero { await Task.detached { try? await Task.sleep(for: step.delay) }.value }
        if let failure = step.failure { throw failure }
        return Data(step.response.utf8)
    }
}

private func recoverySnapshot(trashed: Bool = false, writable: Bool = true, title: String = "Synthetic note") -> String {
    let item = #"{"id":"i","share_id":"s","title":"TITLE","item_type":"note"}"#.replacingOccurrences(of: "TITLE", with: title)
    return """
    {"vaults":[{"name":"Synthetic","vault_id":"v","share_id":"s","can_create":\(writable),"can_update":\(writable),"can_trash":\(writable)}],"items":[\(trashed ? "" : item)],"trashed_items":[\(trashed ? item : "")],"capabilities":{"totp_limit":\(writable ? "null" : "0"),"custom_fields_allowed":\(writable)}}
    """
}
private let recoveryDetail = #"{"revision":1,"item":{"content":{"title":"Synthetic note","note":"SYNTHETIC ONLY","content":{"Note":{}}}}}"#
private func expiredPassSession() throws -> ProtonXError {
    .helperDiagnostic(try JSONDecoder().decode(HelperDiagnostic.self, from: Data(#"{"failure":"sessionInvalidated"}"#.utf8)))
}
private func syntheticSession() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonXPassRecovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".session"), withIntermediateDirectories: true)
    // A file-presence hint only. It contains no authentic session or encryption key.
    try Data("{\"synthetic\":true}".utf8).write(to: root.appendingPathComponent(".session/session.json"))
    return root
}
@MainActor private func waitForPass(_ condition: () -> Bool) async {
    let start = ContinuousClock.now
    while !condition(), start.duration(to: .now) < .seconds(3) { await Task.yield() }
    #expect(condition())
}
@MainActor private func recoveryStore(_ runner: RecoveryRunner, directory: URL = URL(fileURLWithPath: "/nonexistent/protonx-synthetic-recovery")) -> PassStore {
    PassStore(service: PassService(runner: runner), sessionDirectory: directory, previewOnly: false)
}

@Test @MainActor func passReconnectRetainsLastSuccessAndRefreshesPermissionsAtomically() async {
    let runner = RecoveryRunner([
        .init(method: "login"), .init(method: "native-snapshot", response: recoverySnapshot()),
        .init(method: "native-snapshot", failure: .helperFailed(1)),
        .init(method: "native-snapshot", response: recoverySnapshot(writable: false, title: "Changed elsewhere"))
    ])
    let store = recoveryStore(runner)
    store.login(); await waitForPass { !store.busy }
    let previous = store.lastSyncedAt
    store.refresh(); await waitForPass { !store.busy }
    #expect(store.items.first?.title == "Synthetic note"); #expect(store.lastSyncedAt == previous)
    #expect(store.mustRefreshBeforeWriting); #expect(!store.canCreate); #expect(store.error != nil)
    store.refresh(); await waitForPass { !store.busy }
    #expect(store.phase == .open); #expect(store.items.first?.title == "Changed elsewhere")
    #expect(!store.mustRefreshBeforeWriting); #expect(store.error == nil)
    #expect(!store.canCreate); #expect(!store.customFieldsAllowed); #expect(store.capabilities?.totpLimit == 0)
    #expect(runner.calls.filter { $0 == "login" }.count == 1)
    store.lock()
}

@Test @MainActor func passFailedFirstLoadRecoversWithoutAnotherSignIn() async {
    let runner = RecoveryRunner([
        .init(method: "login"), .init(method: "native-snapshot", failure: .helperFailed(1)),
        .init(method: "native-snapshot", response: recoverySnapshot())
    ])
    let store = recoveryStore(runner)
    store.login(); await waitForPass { !store.busy }
    #expect(store.initialSnapshotFailed); #expect(store.items.isEmpty)
    store.refresh(); await waitForPass { !store.busy }
    #expect(!store.initialSnapshotFailed); #expect(store.canCreate); #expect(store.error == nil)
    #expect(runner.calls == ["login", "native-snapshot", "native-snapshot"])
    store.lock()
}

@Test(arguments: [false, true]) @MainActor func passUnconfirmedTrashOrRestoreCannotRetryBeforeRefresh(_ restore: Bool) async throws {
    let method = restore ? "item untrash" : "item trash"
    let runner = RecoveryRunner([
        .init(method: "login"), .init(method: "native-snapshot", response: recoverySnapshot(trashed: restore)),
        .init(method: "item view", response: recoveryDetail), .init(method: method, failure: .helperFailed(1)),
        // The server may have accepted the write before its acknowledgement was lost.
        .init(method: "native-snapshot", response: recoverySnapshot(trashed: !restore))
    ])
    let store = recoveryStore(runner)
    store.login(); await waitForPass { !store.busy }
    store.showingTrash = restore; store.selectedItem = "s:i"; await waitForPass { store.detail != nil }
    store.trashCurrent(); await waitForPass { !store.busy }
    #expect(store.mustRefreshBeforeWriting); #expect(!store.canTrash)
    #expect(store.error?.contains("Refresh") == true)
    store.trashCurrent()
    #expect(runner.calls.filter { $0 == method }.count == 1)
    store.refresh(); await waitForPass { !store.busy }
    #expect(!store.mustRefreshBeforeWriting); #expect(store.error == nil)
    #expect(store.selectedItem == nil); #expect(store.detail == nil)
    #expect((store.items.count == 1) == restore); #expect((store.trashedItems.count == 1) == !restore)
    #expect(runner.calls.filter { $0 == method }.count == 1)
    store.lock()
}

@Test(arguments: ["snapshot", "detail", "edit", "trash", "restore", "saved-refresh"]) @MainActor func passExpiredSessionClearsWorkspaceForEveryOperation(_ action: String) async throws {
    let root = try syntheticSession(); defer { try? FileManager.default.removeItem(at: root) }
    var steps: [RecoveryRunner.Step] = [
        .init(method: "login"), .init(method: "native-snapshot", response: recoverySnapshot(trashed: action == "restore"))
    ]
    if action == "detail" { steps.append(.init(method: "item view", failure: try expiredPassSession())) }
    else if action == "snapshot" { steps.append(.init(method: "native-snapshot", failure: try expiredPassSession())) }
    else {
        steps.append(.init(method: "item view", response: recoveryDetail))
        if action == "saved-refresh" {
            steps.append(.init(method: "native-edit", response: #"{"updated":true}"#))
            steps.append(.init(method: "native-snapshot", failure: try expiredPassSession()))
        } else {
            steps.append(.init(method: action == "edit" ? "native-edit" : "item \(action == "restore" ? "untrash" : "trash")", failure: try expiredPassSession()))
        }
    }
    let runner = RecoveryRunner(steps), store = recoveryStore(runner, directory: root)
    store.login(); await waitForPass { !store.busy }
    if action == "snapshot" { store.refresh(); await waitForPass { !store.busy } }
    else {
        store.showingTrash = action == "restore"; store.selectedItem = "s:i"
        if action == "detail" { await waitForPass { store.error != nil } }
        else {
            await waitForPass { store.detail != nil }
            if action == "edit" || action == "saved-refresh" {
                var draft = NativeItemDraft(); draft.kind = "note"; draft.title = "Synthetic update"; draft.expectedRevision = 1
                do { try await store.save(draft, item: try #require(store.currentItem), vaultID: "s") }
                catch { #expect(error as? ProtonXError == (try expiredPassSession())) }
            } else { store.trashCurrent(); await waitForPass { !store.busy } }
        }
    }
    #expect(store.phase == .welcome); #expect(store.items.isEmpty); #expect(store.trashedItems.isEmpty)
    #expect(store.detail == nil); #expect(store.capabilities == nil); #expect(!store.busy)
    #expect(store.error?.contains("Sign in again") == true)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".session/session.json").path))
    store.lock(); #expect(store.phase == .welcome)
}

@Test @MainActor func passSavedSessionRequiresLocalUnlockOnEachNewStore() async throws {
    let root = try syntheticSession(); defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecoveryRunner([.init(method: "native-snapshot", response: recoverySnapshot()), .init(method: "native-snapshot", response: recoverySnapshot())])
    var unlocks = 0
    let service = PassService(runner: runner)
    let first = PassStore(service: service, sessionDirectory: root, previewOnly: false, localUnlock: { unlocks += 1; return true })
    #expect(first.phase == .locked); #expect(first.items.isEmpty)
    first.refresh(); #expect(!first.busy); #expect(runner.calls.isEmpty)
    first.unlock(); await waitForPass { !first.busy }
    #expect(first.phase == .open); #expect(first.items.count == 1); #expect(unlocks == 1)
    first.lock(); #expect(first.detail == nil); #expect(first.items.isEmpty)
    let restarted = PassStore(service: service, sessionDirectory: root, previewOnly: false, localUnlock: { unlocks += 1; return true })
    #expect(restarted.phase == .locked); #expect(restarted.lastSyncedAt == nil)
    restarted.unlock(); await waitForPass { !restarted.busy }
    #expect(restarted.phase == .open); #expect(unlocks == 2)
    #expect(runner.calls == ["native-snapshot", "native-snapshot"])
    restarted.lock()
}

@Test @MainActor func passCancelledLocalUnlockNeverStartsHelper() async throws {
    let root = try syntheticSession(); defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecoveryRunner([])
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false, localUnlock: { false })
    store.unlock(); await waitForPass { !store.busy }
    #expect(store.phase == .locked); #expect(store.items.isEmpty); #expect(runner.calls.isEmpty)
    #expect(store.challenge == nil)
}

@Test @MainActor func passExpiredSavedSessionRequiresSignInAndSuccessfulLoginResetsIt() async throws {
    let root = try syntheticSession(); defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecoveryRunner([
        .init(method: "native-snapshot", failure: try expiredPassSession()),
        .init(method: "login"), .init(method: "native-snapshot", response: recoverySnapshot())
    ])
    var unlocks = 0
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false, localUnlock: { unlocks += 1; return true })
    store.unlock(); await waitForPass { !store.busy }
    #expect(store.phase == .welcome); #expect(store.error?.contains("Sign in again") == true)
    store.unlock(); store.refresh()
    #expect(unlocks == 1); #expect(runner.calls == ["native-snapshot"])
    store.cancelLogin(); #expect(store.phase == .welcome)
    store.login(); await waitForPass { !store.busy }
    #expect(store.phase == .open); #expect(store.error == nil)
    store.lock(); #expect(store.phase == .locked)
}

@Test @MainActor func passDemoAfterSessionExpiryKeepsIndependentLockAndRejectedAccountState() async throws {
    let root = try syntheticSession(); defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecoveryRunner([.init(method: "native-snapshot", failure: try expiredPassSession())])
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false, localUnlock: { true })
    store.unlock(); await waitForPass { !store.busy }
    #expect(store.phase == .welcome)
    store.enterDemo(); store.lock(); #expect(store.phase == .locked)
    store.unlock(); #expect(store.phase == .open); #expect(store.isDemo)
    store.signOut(); #expect(store.phase == .welcome); #expect(!store.isDemo)
    store.unlock(); store.refresh()
    #expect(runner.calls == ["native-snapshot"])
}

@Test(arguments: ["login", "snapshot", "unlock"]) @MainActor func passLateRecoveryCannotReopenLockedWorkspace(_ stage: String) async throws {
    let root = try syntheticSession(); defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecoveryRunner(stage == "unlock" ? [] : [
        .init(method: "login", delay: stage == "login" ? .milliseconds(120) : .zero),
        .init(method: "native-snapshot", response: recoverySnapshot(), delay: .milliseconds(120))
    ])
    var unlockStarted = false
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false, localUnlock: {
        unlockStarted = true
        await Task.detached { try? await Task.sleep(for: .milliseconds(120)) }.value
        return true
    })
    if stage == "unlock" { store.unlock() } else { store.login() }
    await waitForPass { stage == "unlock" ? unlockStarted : runner.calls.contains(stage == "login" ? "login" : "native-snapshot") }
    store.lock()
    try await Task.sleep(for: .milliseconds(200))
    #expect(store.phase == .locked); #expect(!store.busy); #expect(store.error == nil)
    #expect(store.items.isEmpty); #expect(store.detail == nil); #expect(store.challenge == nil)
    #expect(store.lastSyncedAt == nil)
    if stage == "unlock" { #expect(runner.calls.isEmpty) }
    if stage == "login" { #expect(runner.calls == ["login"]) }
}

@Test @MainActor func passAcknowledgedRestoreAndFailedRefreshReconcilesWithoutRepeatingWrite() async {
    let runner = RecoveryRunner([
        .init(method: "login"), .init(method: "native-snapshot", response: recoverySnapshot(trashed: true)),
        .init(method: "item view", response: recoveryDetail), .init(method: "item untrash"),
        .init(method: "native-snapshot", failure: .helperFailed(1)),
        .init(method: "native-snapshot", response: recoverySnapshot())
    ])
    let store = recoveryStore(runner)
    store.login(); await waitForPass { !store.busy }
    store.showingTrash = true; store.selectedItem = "s:i"; await waitForPass { store.detail != nil }
    store.trashCurrent(); await waitForPass { !store.busy }
    #expect(store.error?.contains("Item restored.") == true); #expect(store.mustRefreshBeforeWriting)
    #expect(store.selectedItem == nil); #expect(store.detail == nil)
    store.refresh(); await waitForPass { !store.busy }
    #expect(store.items.count == 1); #expect(store.trashedItems.isEmpty)
    #expect(!store.mustRefreshBeforeWriting); #expect(store.error == nil)
    #expect(runner.calls.filter { $0 == "item untrash" }.count == 1)
    store.lock()
}

@Test(arguments: [false, true]) @MainActor func passConflictingOrUnconfirmedEditIsNotRetriedAndRefreshReopensWorkflow(_ conflict: Bool) async throws {
    let failure: ProtonXError = conflict
        ? .helperDiagnostic(try JSONDecoder().decode(HelperDiagnostic.self, from: Data(#"{"failure":"conflict"}"#.utf8)))
        : .helperFailed(1)
    let runner = RecoveryRunner([
        .init(method: "login"), .init(method: "native-snapshot", response: recoverySnapshot()),
        .init(method: "item view", response: recoveryDetail), .init(method: "native-edit", failure: failure),
        .init(method: "native-snapshot", response: recoverySnapshot(title: "Updated elsewhere")),
        .init(method: "item view", response: recoveryDetail.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":2"))
    ])
    let store = recoveryStore(runner)
    store.login(); await waitForPass { !store.busy }
    store.selectedItem = "s:i"; await waitForPass { store.detail != nil }
    let item = try #require(store.currentItem)
    var draft = NativeItemDraft(); draft.kind = "note"; draft.title = "Synthetic unsaved edit"; draft.expectedRevision = 1
    await #expect(throws: failure) { try await store.save(draft, item: item, vaultID: "s") }
    #expect(store.mustRefreshBeforeWriting); #expect(!store.canEdit); #expect(store.phase == .open)
    await #expect(throws: ProtonXError.self) { try await store.save(draft, item: item, vaultID: "s") }
    #expect(runner.calls.filter { $0 == "native-edit" }.count == 1)
    store.refresh(); await waitForPass { !store.busy && store.detail?.revision == 2 }
    #expect(!store.mustRefreshBeforeWriting); #expect(store.canEdit); #expect(store.error == nil)
    #expect(store.currentItem?.title == "Updated elsewhere")
    #expect(runner.calls.filter { $0 == "native-edit" }.count == 1)
    store.lock()
}

@Test @MainActor func passReadOnlyPermissionsPreventEditAndRestoreHelperCommands() async throws {
    let runner = RecoveryRunner([
        .init(method: "login"), .init(method: "native-snapshot", response: recoverySnapshot(trashed: true, writable: false)),
        .init(method: "item view", response: recoveryDetail)
    ])
    let store = recoveryStore(runner)
    store.login(); await waitForPass { !store.busy }
    store.showingTrash = true; store.selectedItem = "s:i"; await waitForPass { store.detail != nil }
    #expect(!store.canCreate); #expect(!store.canEdit); #expect(!store.canTrash)
    store.trashCurrent()
    var draft = NativeItemDraft(); draft.kind = "note"; draft.title = "Synthetic"; draft.expectedRevision = 1
    await #expect(throws: ProtonXError.self) { try await store.save(draft, item: store.currentItem, vaultID: "s") }
    #expect(runner.calls == ["login", "native-snapshot", "item view"])
    store.lock()
}
