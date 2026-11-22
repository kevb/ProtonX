// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private final class ForwardStarMailRunner: NativeMailRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [NativeMailCommand] = []
    var starred = false
    var commands: [NativeMailCommand] { lock.withLock { recorded } }
    func cancelAll() {}
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        lock.withLock { recorded.append(command) }
        switch command.method {
        case "login", "restore":
            return .init(phase: .connected)
        case "snapshot":
            let isStarred = lock.withLock { starred }
            return NativeMailResult(
                folders: [.init(id: 1, name: "Inbox", count: 1, kind: .inbox)],
                folder: 1,
                messages: [
                    .init(id: 11, subject: "Newsletter", sender: "news@example.com", unread: false, starred: isStarred, canReply: false, conversationID: 700),
                    .init(id: 12, subject: "Draft note", sender: "alex@example.com", unread: false, starred: false, isDraft: true, canReply: false, conversationID: 701)
                ],
                loading: false,
                email: "alex@example.com"
            )
        case "thread":
            let isStarred = lock.withLock { starred }
            let id = command.item ?? 11
            let conv: UInt64 = id == 11 ? 700 : 701
            let msg = NativeMailMessage(id: id, subject: id == 11 ? "Newsletter" : "Draft note", sender: "news@example.com", unread: false, starred: isStarred, isDraft: id == 12, canReply: false, conversationID: conv)
            return .init(thread: .init(anchor: id, conversationID: conv, messages: [msg]))
        case "message":
            let isStarred = lock.withLock { starred }
            return .init(id: command.item ?? 11, body: "Synthetic newsletter body", actions: [.unread, isStarred ? .unstar : .star, .archive, .trash])
        case "compose":
            guard command.mode == "forward" else { throw ProtonXError.invalidResponse }
            return .init(draft: .init(token: 99, sender: "alex@example.com", senders: ["alex@example.com"], to: [], subject: "Fwd: Newsletter", quote: "---------- Forwarded message ----------", state: .editing))
        case "message_action":
            lock.withLock {
                if command.action == .star { starred = true }
                if command.action == .unstar { starred = false }
            }
            return .init(id: command.item, queued: true)
        case "conversation_action":
            lock.withLock {
                if command.action == .star { starred = true }
                if command.action == .unstar { starred = false }
            }
            return .init(id: command.item, queued: true, conversationID: command.conversation)
        default:
            throw ProtonXError.invalidResponse
        }
    }
}

@MainActor private func awaitMailCondition(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw ProtonXError.cancelled }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite @MainActor struct MailForwardAndStarTests {
    @Test func forwardAllowsNonReplyableMessagesRefusesDraftsAndUsesSDKForwardMode() async throws {
        let runner = ForwardStarMailRunner()
        let defaults = UserDefaults(suiteName: "ProtonXForwardStar." + UUID().uuidString)!
        let store = NativeMailStore(runner: runner, defaults: defaults)
        defer { store.lock() }

        store.signIn(username: "alex@example.com", password: "SYNTHETIC")
        try await awaitMailCondition { store.phase == .open && !store.busy }

        // Draft message cannot be forwarded.
        store.selectedItem = 12; store.select()
        try await awaitMailCondition { store.body != nil }
        store.compose("forward")
        #expect(store.draft == nil)

        // Non-replyable message CAN be forwarded.
        store.selectedItem = 11; store.select()
        try await awaitMailCondition { store.selectedMessage?.id == 11 && store.body != nil }
        store.compose("forward")
        try await awaitMailCondition { store.draft != nil && !store.busy }
        #expect(store.draft?.subject == "Fwd: Newsletter")
        #expect(store.draft?.to.isEmpty == true)
        let composeCmd = try #require(runner.commands.last { $0.method == "compose" })
        #expect(composeCmd.mode == "forward" && composeCmd.item == 11 && composeCmd.folder == 1)
    }

    @Test func starAndUnstarWorkInBothReaderAndConversationList() async throws {
        let runner = ForwardStarMailRunner()
        let defaults = UserDefaults(suiteName: "ProtonXForwardStar." + UUID().uuidString)!
        let store = NativeMailStore(runner: runner, defaults: defaults)
        defer { store.lock() }

        store.signIn(username: "alex@example.com", password: "SYNTHETIC")
        try await awaitMailCondition { store.phase == .open && !store.busy }
        store.selectedItem = 11; store.select()
        try await awaitMailCondition { store.body != nil && store.canPerform(.star) }

        // Star from reader.
        store.actOnMessage(.star)
        try await awaitMailCondition { !store.busy && store.visibleConversations.first(where: { $0.id == 11 })?.starred == true }
        #expect(store.listActions(for: 11).contains(.unstar))

        // Unstar whole conversation from list context action.
        let unstarIntent = try #require(store.listActionIntent(for: 11, action: .unstar))
        store.actFromList(unstarIntent)
        try await awaitMailCondition { !store.busy && store.visibleConversations.first(where: { $0.id == 11 })?.starred == false }
        #expect(store.listActions(for: 11).contains(.star))
    }

    @Test func demoForwardAndStarUpdateSyntheticState() {
        let store = NativeMailStore(previewOnly: true)
        #expect(store.visibleConversations.first(where: { $0.id == 11 })?.starred == false)
        store.actOnMessage(.star)
        #expect(store.visibleConversations.first(where: { $0.id == 11 })?.starred == true)
        store.actOnMessage(.unstar)
        #expect(store.visibleConversations.first(where: { $0.id == 11 })?.starred == false)

        store.compose("forward")
        #expect(store.draft?.subject.hasPrefix("Fwd: ") == true)
        #expect(store.draft?.to.isEmpty == true)
    }
}
