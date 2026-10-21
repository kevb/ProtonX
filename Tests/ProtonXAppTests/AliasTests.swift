import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private final class AliasStoreRunner: HelperRunning, @unchecked Sendable {
    let lock = NSLock()
    let delay: Bool
    let failWrite: Bool
    let failRefresh: Bool
    private var snapshots = 0
    private var writes = 0
    init(delay: Bool = false, failWrite: Bool = false, failRefresh: Bool = false) { self.delay = delay; self.failWrite = failWrite; self.failRefresh = failRefresh }
    var writeCount: Int { lock.withLock { writes } }
    func cancelAll() {}
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data {
        switch command.arguments.first {
        case "login": return Data()
        case "native-snapshot":
            let count = lock.withLock { snapshots += 1; return snapshots }
            if failRefresh && count > 1 { throw ProtonXError.timeout }
            return Data(#"{"vaults":[{"name":"Synthetic","vault_id":"v","share_id":"s","can_create":true}],"items":[],"trashed_items":[],"capabilities":{"totp_limit":null}}"#.utf8)
        case "native-alias-options":
            if delay { await Task.detached { try? await Task.sleep(for: .milliseconds(80)) }.value }
            return Data(#"{"suffixes":[{"suffix":".demo@example.invalid","signed_suffix":"synthetic"}],"mailboxes":[{"id":1,"email":"alex@example.invalid"}]}"#.utf8)
        case "native-alias-create":
            lock.withLock { writes += 1 }
            if delay { await Task.detached { try? await Task.sleep(for: .milliseconds(80)) }.value }
            if failWrite { throw ProtonXError.timeout }
            return Data(#"{"item_id":"synthetic","alias":"shop.demo@example.invalid"}"#.utf8)
        default: throw ProtonXError.invalidResponse
        }
    }
}
@MainActor private func openAliasStore(_ runner: AliasStoreRunner) async -> PassStore {
    let store = PassStore(service: PassService(runner: runner), sessionDirectory: URL(fileURLWithPath: "/nonexistent/protonx-alias-tests"), previewOnly: false)
    store.login()
    for _ in 0..<2000 { if !store.busy { break }; try? await Task.sleep(for: .milliseconds(1)) }
    return store
}
@MainActor private func aliasDraft() -> PassAliasDraft {
    .init(title: "Synthetic shop", note: "Demo", prefix: "shop", suffix: .init(suffix: ".demo@example.invalid", signedSuffix: "synthetic"), mailbox: .init(id: 1, email: "alex@example.invalid"))
}
@Suite @MainActor struct AliasTests {
    @Test func mailEntryKeepsDraftAndSelectionWhileLazilyOpeningPass() {
        let suite = SuiteWorkspace(defaults: UserDefaults(suiteName: "ProtonXAliasTests." + UUID().uuidString)!, previewOnly: true, initialProduct: .mail)
        let mail = suite.mail!
        #expect(suite.canCreate && suite.pass == nil)
        suite.openAlias(); #expect(!suite.canCreate && !suite.canRefresh)
        suite.closeAlias(); #expect(suite.canCreate)
        mail.compose(); mail.editorState!.text = "SYNTHETIC unsaved reply"; let editor = mail.editorState
        suite.openAlias()
        #expect(suite.showingAlias && suite.selected == .mail && suite.pass != nil)
        #expect(mail.editorState === editor && mail.editorState?.text == "SYNTHETIC unsaved reply")
        suite.closeAlias(); #expect(!suite.showingAlias && suite.selected == .mail)
        suite.openAlias(); suite.lock()
        #expect(!suite.showingAlias && mail.editorState == nil)
    }
    @Test func syntheticAliasCreationDoesNotChangeExistingPassSelection() async throws {
        let pass = PassStore(previewOnly: true); pass.enterDemo()
        let selected = pass.selectedItem
        let vault = try #require(pass.writableVaults.first)
        let options = try await pass.aliasOptions(vaultID: vault.id)
        #expect(options.mailboxes[0].email == "alex@example.invalid")
        let created = try await pass.createAlias(aliasDraft(), vaultID: vault.id)
        #expect(pass.selectedItem == selected)
        let item = try #require(pass.items.first { $0.itemID == created.itemID })
        #expect(item.kind == "alias")
        pass.selectAlias(created, vaultID: vault.id)
        #expect(pass.detail?.fields.first?.value == created.alias)
        pass.lock(); #expect(!pass.canCreateAlias)
    }
    @Test(arguments: [false, true]) func ambiguousWriteBlocksAnotherCreateButAcknowledgementSurvivesRefreshFailure(_ failWrite: Bool) async throws {
        let runner = AliasStoreRunner(failWrite: failWrite, failRefresh: true)
        let pass = await openAliasStore(runner)
        do {
            let created = try await pass.createAlias(aliasDraft(), vaultID: "s")
            #expect(!failWrite && created.alias == "shop.demo@example.invalid")
        } catch { #expect(failWrite) }
        #expect(pass.mustRefreshBeforeWriting && !pass.canCreateAlias && runner.writeCount == 1)
        await #expect(throws: Error.self) { try await pass.createAlias(aliasDraft(), vaultID: "s") }
        #expect(runner.writeCount == 1)
        pass.lock()
    }
    @Test(arguments: [false, true]) func lockRejectsLateOptionsAndCreationResults(_ create: Bool) async throws {
        let pass = await openAliasStore(AliasStoreRunner(delay: true))
        let operation = Task { if create { _ = try await pass.createAlias(aliasDraft(), vaultID: "s") } else { _ = try await pass.aliasOptions(vaultID: "s") } }
        while !pass.busy { await Task.yield() }
        pass.lock()
        await #expect(throws: Error.self) { try await operation.value }
        #expect(pass.items.isEmpty && pass.detail == nil && !pass.busy)
    }
    @Test func sidebarUsesIdentityAndRetainsEveryMailboxExactlyOnce() throws {
        let folders = [NativeMailFolder(id:1,name:"Inbox",kind:.inbox),NativeMailFolder(id:2,name:"Drafts",kind:.drafts),NativeMailFolder(id:3,name:"Starred",kind:.starred),NativeMailFolder(id:4,name:"Inbox",kind:.other,isCustom:true),NativeMailFolder(id:5,name:"Trash",kind:.trash),NativeMailFolder(id:6,name:"Unknown system view",kind:.other)]
        let label = NativeMailFolder(id: 8, name: "Inbox", kind: .other, isLabel: true)
        let sections = MailSidebarSections(folders + [label])
        #expect(sections.primary.map(\.id) == [1,2,3]); #expect(sections.folders.map(\.id) == [4]); #expect(sections.more.map(\.id) == [5,6])
        #expect(sections.labels.map(\.id) == [8])
        #expect(Set((sections.primary + sections.more + sections.folders + sections.labels).map(\.id)) == Set((folders + [label]).map(\.id)))
        let decoded = try JSONDecoder().decode(NativeMailFolder.self, from: Data(#"{"id":4,"name":"Inbox","kind":"other","count":0,"isCustom":true}"#.utf8))
        #expect(decoded.isCustom == true)
    }
}
