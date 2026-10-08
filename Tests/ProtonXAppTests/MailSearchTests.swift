// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp
private actor SearchRunner: NativeMailRunning {
    private(set) var calls: [NativeMailCommand] = []
    var held = false
    var failure: NativeMailFailure?
    private var pending: CheckedContinuation<Void, Never>?
    func configure(hold: Bool = false, failure: NativeMailFailure? = nil) { held = hold; self.failure = failure }
    func release() { pending?.resume(); pending = nil }
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        calls.append(command)
        if command.keywords != nil {
            if held { held = false; await withCheckedContinuation { pending = $0 } }
            if let failure { throw failure }
            // The match is in recipient metadata, not in the visible subject/sender.
            return .init(folder: 9, messages: [.init(id: 700, subject: "Archived workshop notes", sender: "sam@example.com", recipient: "design@example.com", date: 1)], email: "alex@example.com", searchQuery: command.keywords, hasMore: false)
        }
        switch command.method {
        case "login": return .init(phase: .connected)
        case "snapshot": return .init(folders: [.init(id: 1, name: "Inbox"), .init(id: 9, name: "All mail")], folder: command.folder ?? 1, messages: [.init(id: 10, subject: "Recent message", sender: "jamie@example.com")], loading: false)
        case "compose": return .init(draft: .init(token: 70, sender: "alex@example.com", senders: ["alex@example.com"], state: .editing))
        default: throw ProtonXError.invalidResponse
        }
    }
    nonisolated func cancelAll() {}
}
@Suite @MainActor struct MailSearchTests {
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await condition())
    }
    private func open(_ runner: SearchRunner) async throws -> NativeMailStore {
        let store = NativeMailStore(runner: runner, defaults: UserDefaults(suiteName: UUID().uuidString)!, localUnlock: { true })
        store.signIn(username: "alex@example.com", password: "SYNTHETIC")
        try await wait { store.phase == .open && !store.busy }; return store
    }
    @Test func globalSearchFindsOlderRecipientMatchesAndReturnsToOriginalFolder() async throws {
        let runner = SearchRunner(), store = try await open(runner)
        store.query = "design"; #expect(store.visibleMessages.isEmpty)
        store.searchAllMail(); try await wait { !store.busy }
        #expect(store.visibleMessages.map(\.id) == [700] && store.visibleConversations.count == 1)
        #expect(store.selectedFolder == 9 && store.searchQuery == "design" && !store.searchHasMore)
        #expect(store.listActions(for: 700).isEmpty)
        #expect(await runner.calls.last?.keywords == "design")
        store.query = ""; store.searchTextChanged(); try await wait { !store.busy }
        #expect(store.searchQuery == nil && store.selectedFolder == 1 && store.messages.map(\.id) == [10])
    }
    @Test func oldSearchReplyCannotReopenLockedWorkspace() async throws {
        let runner = SearchRunner(), store = try await open(runner)
        await runner.configure(hold: true); store.query = "design"; store.searchAllMail()
        try await wait { await runner.calls.contains { $0.keywords != nil } }
        store.lock(); await runner.release(); for _ in 0..<30 { await Task.yield() }
        #expect(store.phase == .locked && store.searchQuery == nil && store.messages.isEmpty && store.body == nil)
    }
    @Test func malformedSearchDoesNotReachHelperAndFailedSearchRetainsDraft() async throws {
        let runner = SearchRunner(), store = try await open(runner)
        store.query = String(repeating: "x", count: 257); store.searchAllMail()
        #expect(await !runner.calls.contains { $0.keywords != nil })
        store.compose(); try await wait { !store.busy }; store.editorState?.text = "Synthetic retained draft"
        await runner.configure(failure: .searchFailed); store.query = "design"; store.searchAllMail(); try await wait { !store.busy }
        #expect(store.error != nil && store.editorState?.text == "Synthetic retained draft")
        await runner.configure(failure: .sessionExpired); store.refresh(); try await wait { store.phase == .welcome }
        #expect(store.searchQuery == nil && store.messages.isEmpty)
    }
    @Test func editingSearchOrChoosingFolderEndsGlobalScope() async throws {
        let runner = SearchRunner(), store = try await open(runner)
        store.query = "design"; store.searchAllMail(); try await wait { !store.busy }
        store.query = "sam"; store.searchTextChanged(); try await wait { !store.busy }
        #expect(store.searchQuery == nil && store.selectedFolder == 1 && store.query == "sam")
        store.searchAllMail(); try await wait { !store.busy }; store.selectedFolder = 1; store.changeFolder(); try await wait { !store.busy }
        #expect(store.searchQuery == nil && store.query.isEmpty && store.messages.map(\.id) == [10])
    }
    @Test func previewSearchIncludesSentMatchesWithoutStartingAccountHelper() async throws {
        let runner = SearchRunner()
        let store = NativeMailStore(runner: runner, defaults: UserDefaults(suiteName: UUID().uuidString)!, previewOnly: true)
        store.query = "sam@example.com"; store.searchAllMail()
        #expect(store.visibleMessages.map(\.id).sorted() == [12, 13, 14])
        #expect(await runner.calls.isEmpty)
        store.query = ""; store.searchTextChanged()
        #expect(store.selectedFolder == 1 && store.messages.map(\.id) == [11, 12])
    }
}
