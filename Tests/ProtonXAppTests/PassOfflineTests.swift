import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private let offlineNow = Date(timeIntervalSince1970: 1_800_000_100)
private let offlineGeneration = "00000000-0000-4000-8000-000000000001"
private let savedItemDetail = #"{"revision":7,"offline_attachments_unavailable":true,"item":{"content":{"title":"Synthetic saved login","note":"Synthetic note","content":{"Login":{"username":"alex","password":"SYNTHETIC-ONLY","urls":["https://example.com"]}}}}}"#
private func offlineMetadata(title: String = "Synthetic saved login", writable: Bool = true) -> String {
    """
    {"vaults":[{"name":"Synthetic","vault_id":"v","share_id":"s","can_create":\(writable),"can_update":\(writable),"can_trash":\(writable)}],"items":[{"id":"i","share_id":"s","title":"\(title)","item_type":"login","has_totp":true}],"trashed_items":[],"capabilities":{"totp_limit":null,"custom_fields_allowed":true},"cache_status":"ready"}
    """
}
private func savedMetadata(expires: Int = 1_800_086_400) -> String {
    """
    {"snapshot":\(offlineMetadata()),"saved_at":1800000000,"expires_at":\(expires),"generation":"\(offlineGeneration)"}
    """
}
private func offlineError(_ failure: String) throws -> ProtonXError {
    .helperDiagnostic(try JSONDecoder().decode(HelperDiagnostic.self, from: Data("{\"failure\":\"\(failure)\"}".utf8)))
}

/// Synthetic responses only. Separate cache/online paths expose race conditions.
private final class OfflineResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if released { return true }
                continuations.append(continuation); return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func release() {
        let waiting = lock.withLock {
            released = true
            let waiting = continuations; continuations.removeAll(); return waiting
        }
        waiting.forEach { $0.resume() }
    }
}

private final class OfflineRunner: HelperRunning, @unchecked Sendable {
    struct Response: Sendable { var value = ""; var failure: ProtonXError?; var delay: Duration = .zero; var gate: OfflineResponseGate? }
    private let lock = NSLock()
    private var recorded: [HelperCommand] = []
    private var online: [Response]
    let cache: Response
    let detail: Response
    init(cache: Response = .init(value: savedMetadata()), detail: Response = .init(value: savedItemDetail), online: [Response]) {
        self.cache = cache; self.detail = detail; self.online = online
    }
    var calls: [HelperCommand] { lock.withLock { recorded } }
    func cancelAll() {}
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data {
        let response = lock.withLock { () -> Response in
            recorded.append(command)
            switch command.arguments.first {
            case "native-cache-snapshot": return cache
            case "native-cache-detail": return detail
            case "native-snapshot": return online.isEmpty ? .init(failure: .invalidResponse) : online.removeFirst()
            case "item": return .init(value: savedItemDetail)
            default: Issue.record("Unexpected command in read-only offline test"); return .init(failure: .invalidResponse)
            }
        }
        if let gate = response.gate { await gate.wait() }
        if response.delay > .zero { await Task.detached { try? await Task.sleep(for: response.delay) }.value }
        if let failure = response.failure { throw failure }
        return Data(response.value.utf8)
    }
}
private func offlineSession() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonXOfflineTest-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".session"), withIntermediateDirectories: true)
    try Data("Synthetic file-presence hint; not a real session".utf8).write(to: root.appendingPathComponent(".session/session.json"))
    return root
}
@MainActor private func awaitOffline(_ predicate: @MainActor () -> Bool) async {
    let start = ContinuousClock.now
    while !predicate(), start.duration(to: .now) < .seconds(3) { try? await Task.sleep(for: .milliseconds(4)) }
    #expect(predicate())
}

@Test @MainActor func savedPassMetadataAndSelectedDetailAppearBeforeSlowOnlineRefresh() async throws {
    let root = try offlineSession(); defer { try? FileManager.default.removeItem(at: root) }
    let onlineGate = OfflineResponseGate(); defer { onlineGate.release() }
    let runner = OfflineRunner(online: [.init(value: offlineMetadata(title: "Updated online"), gate: onlineGate)])
    var unlocks = 0
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false,
        localUnlock: { unlocks += 1; return true }, now: { offlineNow })
    defer { store.lock() }
    #expect(store.phase == .locked); #expect(runner.calls.isEmpty)
    store.unlock(); await awaitOffline { store.isUsingSavedVault }
    #expect(unlocks == 1); #expect(store.busy); #expect(store.lastSyncedAt == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(!store.canCreate); #expect(!store.canTrash); #expect(store.mustRefreshBeforeWriting)
    store.selectedItem = "s:i"; await awaitOffline { store.detail != nil }
    #expect(store.busy); #expect(store.detail?.fields.first { $0.label == "Password" }?.value == "SYNTHETIC-ONLY")
    #expect(store.detail?.offlineAttachmentsUnavailable == true); #expect(!store.canEdit); #expect(!store.canCopyTOTP)
    let command = try #require(runner.calls.first { $0.arguments.first == "native-cache-detail" })
    #expect(command.arguments == ["native-cache-detail", "--generation", offlineGeneration, "--share-id", "s", "--item-id", "i"])
    onlineGate.release()
    await awaitOffline { !store.busy }
    #expect(!store.isUsingSavedVault); #expect(!store.mustRefreshBeforeWriting); #expect(store.items.first?.title == "Updated online")
    #expect(store.lastSyncedAt == offlineNow); #expect(store.offlineCacheStatus == "ready")
}

@Test @MainActor func offlinePassNeverQueuesWritesAndReconnectUsesAuthoritativePermissions() async throws {
    let root = try offlineSession(); defer { try? FileManager.default.removeItem(at: root) }
    let runner = OfflineRunner(online: [.init(failure: try offlineError("network")), .init(value: offlineMetadata(writable: false))])
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false,
        localUnlock: { true }, now: { offlineNow }); defer { store.lock() }
    store.unlock(); await awaitOffline { !store.busy }
    #expect(store.isUsingSavedVault); #expect(store.error?.contains("saved vault") == true)
    store.selectedItem = "s:i"; await awaitOffline { store.detail != nil }
    #expect(!store.canEdit); #expect(!store.canCopyTOTP)
    var draft = NativeItemDraft(); draft.title = "Synthetic attempted edit"; draft.expectedRevision = 7
    await #expect(throws: ProtonXError.self) { try await store.save(draft, item: store.currentItem, vaultID: "s") }
    store.trashCurrent(); store.copyTOTP()
    #expect(!runner.calls.contains { ["native-create", "native-edit", "native-totp"].contains($0.arguments.first ?? "") })
    #expect(!runner.calls.contains { $0.arguments.starts(with: ["item", "trash"]) })
    store.refresh(); await awaitOffline { !store.busy }
    #expect(!store.isUsingSavedVault); #expect(store.error == nil); #expect(!store.canCreate); #expect(!store.canEdit)
}

@Test(arguments: ["tls", "authentication", "sessionInvalidated", "operation"]) @MainActor
func offlinePassDoesNotFallbackAfterSecurityOrSessionFailure(_ failure: String) async throws {
    let root = try offlineSession(); defer { try? FileManager.default.removeItem(at: root) }
    let runner = OfflineRunner(online: [.init(failure: try offlineError(failure))])
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false,
        localUnlock: { true }, now: { offlineNow }); defer { store.lock() }
    store.unlock(); await awaitOffline { !store.busy }
    #expect(store.items.isEmpty); #expect(store.detail == nil); #expect(!store.isUsingSavedVault); #expect(!store.canCreate)
    if failure == "sessionInvalidated" { #expect(store.phase == .welcome) }
    #expect(store.error != nil)
}

@Test(arguments: ["missing", "expired", "corrupt"]) @MainActor
func unavailableSavedPassCacheFallsBackToOnlineWithoutDeletingSession(_ kind: String) async throws {
    let root = try offlineSession(); defer { try? FileManager.default.removeItem(at: root) }
    let value = kind == "missing" ? "null" : (kind == "corrupt" ? "{broken" : savedMetadata(expires: 1_800_000_050))
    let runner = OfflineRunner(cache: .init(value: value), online: [.init(value: offlineMetadata())])
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false,
        localUnlock: { true }, now: { offlineNow }); defer { store.lock() }
    store.unlock(); await awaitOffline { !store.busy }
    #expect(!store.isUsingSavedVault); #expect(store.canCreate); #expect(store.error == nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".session/session.json").path))
}

@Test @MainActor func savedPassExpiryAndClockRollbackClearVisibleSecrets() async throws {
    let root = try offlineSession(); defer { try? FileManager.default.removeItem(at: root) }
    for date in [Date(timeIntervalSince1970: 1_800_086_400), Date(timeIntervalSince1970: 1_799_999_999)] {
        var now = offlineNow
        let runner = OfflineRunner(online: [.init(failure: try offlineError("network"))])
        let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false,
            localUnlock: { true }, now: { now })
        store.unlock(); await awaitOffline { !store.busy }
        store.selectedItem = "s:i"; await awaitOffline { store.detail != nil }
        now = date
        #expect(!store.canUseVisibleDetail()); #expect(store.detail == nil); #expect(store.items.isEmpty)
        #expect(!store.canCreate); #expect(store.error?.contains("expired") == true)
        store.lock()
    }
}

@Test @MainActor func corruptSavedPassDetailClearsWorkspaceAndLateDetailCannotSurviveLock() async throws {
    let root = try offlineSession(); defer { try? FileManager.default.removeItem(at: root) }
    for late in [false, true] {
        let runner = OfflineRunner(detail: late ? .init(value: savedItemDetail, delay: .milliseconds(80)) : .init(failure: try offlineError("cacheUnavailable")),
            online: [.init(failure: try offlineError("network"))])
        let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false,
            localUnlock: { true }, now: { offlineNow })
        store.unlock(); await awaitOffline { !store.busy }
        store.selectedItem = "s:i"; await awaitOffline { runner.calls.contains { $0.arguments.first == "native-cache-detail" } }
        if late { store.lock(); try? await Task.sleep(for: .milliseconds(120)); #expect(store.phase == .locked) }
        else { await awaitOffline { store.items.isEmpty }; #expect(store.error?.contains("expired or changed") == true) }
        #expect(store.detail == nil); #expect(store.items.isEmpty); store.lock()
    }
}

@Test @MainActor func savedPassLeaseExpiryTimerClearsIdleWorkspace() async throws {
    let root = try offlineSession(); defer { try? FileManager.default.removeItem(at: root) }
    let runner = OfflineRunner(cache: .init(value: savedMetadata(expires: 1_800_000_101)), online: [.init(failure: try offlineError("network"))])
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false,
        localUnlock: { true }, now: { Date(timeIntervalSince1970: 1_800_000_100.9) }); defer { store.lock() }
    store.unlock(); await awaitOffline { !store.busy }; #expect(store.isUsingSavedVault)
    await awaitOffline { store.items.isEmpty }; #expect(store.error?.contains("expired") == true)
}

@Test @MainActor func lateSavedPassDetailFailureCannotDiscardReconnectedWorkspace() async throws {
    let root = try offlineSession(); defer { try? FileManager.default.removeItem(at: root) }
    let onlineGate = OfflineResponseGate(); defer { onlineGate.release() }
    let detailGate = OfflineResponseGate(); defer { detailGate.release() }
    let runner = OfflineRunner(detail: .init(failure: try offlineError("cacheUnavailable"), gate: detailGate),
        online: [.init(value: offlineMetadata(title: "Reconnected"), gate: onlineGate)])
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false,
        localUnlock: { true }, now: { offlineNow }); defer { store.lock() }
    store.unlock(); await awaitOffline { store.isUsingSavedVault }
    store.selectedItem = "s:i"; await awaitOffline { runner.calls.contains { $0.arguments.first == "native-cache-detail" } }
    onlineGate.release()
    await awaitOffline { !store.busy }
    #expect(store.items.first?.title == "Reconnected")
    detailGate.release()
    try? await Task.sleep(for: .milliseconds(220))
    #expect(!store.isUsingSavedVault); #expect(store.items.first?.title == "Reconnected")
    #expect(store.error == nil); #expect(store.detail != nil); #expect(!store.mustRefreshBeforeWriting)
}

@Test @MainActor func savedPassRemainsReadOnlyAfterOnlineHelperDeadline() async throws {
    let root = try offlineSession(); defer { try? FileManager.default.removeItem(at: root) }
    let runner = OfflineRunner(online: [.init(failure: .timeout)])
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: root, previewOnly: false,
        localUnlock: { true }, now: { offlineNow }); defer { store.lock() }
    store.unlock(); await awaitOffline { !store.busy }
    #expect(store.isUsingSavedVault); #expect(!store.canCreate); #expect(store.mustRefreshBeforeWriting)
    store.selectedItem = "s:i"; await awaitOffline { store.detail != nil }
    #expect(store.error?.contains("saved vault") == true)
}
