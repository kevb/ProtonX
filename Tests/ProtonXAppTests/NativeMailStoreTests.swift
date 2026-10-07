import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private final class SyntheticMailRunner: NativeMailRunning, @unchecked Sendable {
    struct Step: Sendable {
        let method: String
        let result: NativeMailResult
        var failure: NativeMailFailure?
        var delay: Duration = .zero
        var gate: MailReplyGate?
    }
    private let lock = NSLock()
    private var steps: [Step]
    private var methods: [String] = []
    private var commands: [NativeMailCommand] = []
    init(_ steps: [Step]) { self.steps = steps }
    var calls: [String] { lock.withLock { methods } }
    var payloads: [NativeMailCommand] { lock.withLock { commands } }
    func cancelAll() {}
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        let step: Step? = lock.withLock { methods.append(command.method); commands.append(command); return steps.isEmpty ? nil : steps.removeFirst() }
        guard let step else { throw ProtonXError.invalidResponse }
        #expect(command.method == step.method)
        // Simulate a network reply arriving after the caller has cancelled/locked.
        if step.delay > .zero { await Task.detached { try? await Task.sleep(for: step.delay) }.value }
        if let gate = step.gate { await gate.wait() }
        if let failure = step.failure { throw failure }
        return step.result
    }
}
private actor MailReplyGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private let mailSnapshot = NativeMailResult(folders: [NativeMailFolder(id: 1, name: "Inbox"), NativeMailFolder(id: 2, name: "Sent")], folder: 1,
    messages: [NativeMailMessage(id: 11, subject: "Synthetic message", sender: "demo@example.com")], loading: false, email: "alex@example.com")
@MainActor private func waitForMail(_ condition: () -> Bool) async {
    let start = ContinuousClock.now
    while !condition(), start.duration(to: .now) < .seconds(3) { await Task.yield() }
    #expect(condition())
}
@MainActor private func mailStore(_ runner: SyntheticMailRunner, saved: Bool = false, preview: Bool = false, unlock: @escaping @MainActor @Sendable () async throws -> Bool = { true }) -> NativeMailStore {
    let name = "ProtonXMailTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.set(saved, forKey: "nativeMailConnected")
    let store = NativeMailStore(runner: runner, defaults: defaults, previewOnly: preview, localUnlock: unlock)
    defaults.removePersistentDomain(forName: name)
    return store
}

@Test @MainActor func nativeMailChallengesLeadToInboxAndSelectedDecryption() async {
    let runner = SyntheticMailRunner([
        .init(method: "login", result: .init(phase: .totp)),
        .init(method: "totp", result: .init(), failure: .incorrectCode),
        .init(method: "totp", result: .init(phase: .mailboxPassword)),
        .init(method: "mailbox_password", result: .init(phase: .connected)),
        .init(method: "snapshot", result: mailSnapshot),
        .init(method: "message", result: .init(id: 11, body: "SYNTHETIC body"))
    ])
    let store = mailStore(runner)
    store.signIn(username: "demo@example.com", password: "SYNTHETIC")
    await waitForMail { !store.busy }; #expect(store.phase == .totp)
    store.submitChallenge("000000"); await waitForMail { !store.busy }
    #expect(store.phase == .totp); #expect(store.error == NativeMailFailure.incorrectCode.localizedDescription)
    store.submitChallenge("123456"); await waitForMail { !store.busy }; #expect(store.phase == .mailboxPassword)
    store.submitChallenge("SYNTHETIC-second-password"); await waitForMail { !store.busy }
    #expect(store.phase == .open); #expect(store.messages.count == 1); #expect(store.body == nil)
    store.selectedItem = 11; store.select(); await waitForMail { store.body != nil }
    #expect(store.body == "SYNTHETIC body")
    store.query = "absent"; store.reconcileSelection(); #expect(store.body == nil); #expect(store.selectedItem == nil)
    store.lock(); #expect(store.phase == .locked); #expect(store.messages.isEmpty); #expect(store.email.isEmpty)
}

@Test @MainActor func mailLockRejectsLateLoginAndLateMessage() async {
    let login = SyntheticMailRunner([.init(method: "login", result: .init(phase: .connected), delay: .milliseconds(80))])
    let first = mailStore(login)
    first.signIn(username: "demo@example.com", password: "SYNTHETIC")
    await waitForMail { login.calls.count == 1 }; first.lock()
    try? await Task.sleep(for: .milliseconds(150))
    #expect(first.phase == .welcome); #expect(first.messages.isEmpty); #expect(login.calls == ["login"])

    let message = SyntheticMailRunner([.init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot), .init(method: "message", result: .init(id: 11, body: "SYNTHETIC late body"), delay: .milliseconds(80))])
    let second = mailStore(message, saved: true)
    second.unlock(); await waitForMail { !second.busy }
    second.selectedItem = 11; second.select(); await waitForMail { message.calls.count == 3 }
    second.lock(); try? await Task.sleep(for: .milliseconds(150))
    #expect(second.phase == .locked); #expect(second.body == nil); #expect(second.messages.isEmpty)
}

@Test @MainActor func mailLocalUnlockCancellationDoesNotStartHelper() async {
    let runner = SyntheticMailRunner([])
    let store = mailStore(runner, saved: true, unlock: { false })
    store.unlock(); await waitForMail { !store.busy }
    #expect(store.phase == .locked); #expect(runner.calls.isEmpty); #expect(store.error == nil)
}

@Test @MainActor func mailInitialLoadAndFailureAreNotPresentedAsEmptyFolders() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)),
        .init(method: "snapshot", result: .init(), failure: .snapshotFailed, delay: .milliseconds(120)),
        .init(method: "snapshot", result: mailSnapshot)
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { runner.calls.count == 2 }
    #expect(store.phase == .open); #expect(store.messages.isEmpty)
    #expect(store.isLoadingList); #expect(!store.initialListFailed)
    await waitForMail { !store.busy }
    #expect(!store.isLoadingList); #expect(store.initialListFailed)
    store.refresh(); await waitForMail { !store.busy }
    #expect(store.messages.count == 1); #expect(!store.initialListFailed)
    store.lock(); #expect(!store.isLoadingList); #expect(!store.initialListFailed)
}

@Test @MainActor func mailLockDuringInitialListCannotRevealLateContent() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)),
        .init(method: "snapshot", result: mailSnapshot, delay: .milliseconds(120))
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { runner.calls.count == 2 }
    #expect(store.isLoadingList)
    store.lock(); try? await Task.sleep(for: .milliseconds(180))
    #expect(store.phase == .locked); #expect(store.messages.isEmpty)
    #expect(!store.isLoadingList); #expect(!store.initialListFailed)
}

@Test @MainActor func mailFailedSignOutRetainsSessionUntilAcknowledged() async {
    let runner = SyntheticMailRunner([.init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot), .init(method: "sign_out", result: .init(), failure: .signOutFailed), .init(method: "sign_out", result: .init(phase: .welcome))])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.signOut(); await waitForMail { !store.busy }
    #expect(store.phase == .open); #expect(store.messages.count == 1)
    store.signOut(); await waitForMail { !store.busy }
    #expect(store.phase == .welcome); #expect(store.messages.isEmpty)
}

@Test @MainActor func expiredMailSessionClearsContentAndRequiresSignIn() async {
    let runner = SyntheticMailRunner([.init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot), .init(method: "snapshot", result: .init(), failure: .sessionExpired)])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.refresh(); await waitForMail { !store.busy }
    #expect(store.phase == .welcome); #expect(store.messages.isEmpty); #expect(store.email.isEmpty)
    #expect(store.error == NativeMailFailure.sessionExpired.localizedDescription)
}

@Test @MainActor func mailPreviewNeverStartsHelperAndDemoFoldersAreReversible() async {
    let runner = SyntheticMailRunner([]), store = mailStore(runner, preview: true)
    #expect(store.phase == .open); #expect(store.body != nil)
    store.signIn(username: "demo@example.com", password: "SYNTHETIC"); store.unlock(); store.signOut(); store.refresh()
    store.selectedFolder = 2; store.changeFolder(); #expect(store.messages.count == 2); #expect(store.body == nil)
    store.selectedFolder = 1; store.changeFolder(); #expect(store.messages.count == 2)
    store.lock(); #expect(store.body == nil); #expect(runner.calls.isEmpty)
}

private let linkedDraft = NativeMailDraft(token: 3, sender: "alex.demo@gmail.com", senders: ["alex@example.com", "alex.demo@gmail.com"], to: ["sam@example.com"], subject: "Re: Synthetic", quote: "SYNTHETIC original quote")

@Test @MainActor func nativeMailReplyKeepsCoreGmailSenderAndWaitsForConfirmedDelivery() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot),
        .init(method: "compose", result: .init(draft: linkedDraft)),
        .init(method: "send_draft", result: .init(token: 3, sendState: .queued)),
        .init(method: "draft_status", result: .init(token: 3, sendState: .sent)),
        .init(method: "close_draft", result: .init(closed: true)), .init(method: "snapshot", result: mailSnapshot)
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.selectedItem = 11; store.compose("reply")
    await waitForMail { !store.busy }
    #expect(store.draft?.sender == "alex.demo@gmail.com")
    #expect(runner.payloads[2].item == 11); #expect(runner.payloads[2].folder == 1)
    var content = linkedDraft.content; content.text = "SYNTHETIC response"
    store.sendDraft(content); await waitForMail { !store.busy }
    #expect(store.draft?.state == .queued); #expect(store.notice == nil)
    store.sendDraft(content) // A second click cannot send the same draft twice.
    await waitForMail { store.draft == nil }
    #expect(store.notice == "Message sent")
    #expect(runner.calls.filter { $0 == "send_draft" }.count == 1)
    #expect(runner.payloads[3].content?.sender == "alex.demo@gmail.com")
    #expect(runner.payloads[3].content?.to == ["sam@example.com"])
    store.lock()
}

@Test @MainActor func nativeMailAmbiguousSendNeverRetriesOrDiscardsDraft() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot),
        .init(method: "compose", result: .init(draft: linkedDraft)),
        .init(method: "send_draft", result: .init(), failure: .sendUncertain)
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }; store.compose(); await waitForMail { !store.busy }
    store.sendDraft(linkedDraft.content); await waitForMail { !store.busy }
    #expect(store.draft?.state == .unknown); #expect(store.notice == nil)
    store.sendDraft(linkedDraft.content); store.discardDraft(); store.saveDraft(linkedDraft.content)
    #expect(runner.calls == ["restore", "snapshot", "compose", "send_draft"])
    store.lock(); #expect(store.draft == nil); #expect(store.composeStatus == nil)
}

@Test @MainActor func nativeMailUnconnectedSenderAndLateComposerCannotSend() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot),
        .init(method: "compose", result: .init(draft: linkedDraft))
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }; store.compose(); await waitForMail { !store.busy }
    var spoofed = linkedDraft.content; spoofed.sender = "unconnected@gmail.com"
    store.sendDraft(spoofed)
    #expect(store.draft?.state == .editing); #expect(runner.calls.count == 3); #expect(store.error != nil)
    store.lock()
    let lateRunner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot),
        .init(method: "compose", result: .init(draft: linkedDraft), delay: .milliseconds(80))
    ])
    let late = mailStore(lateRunner, saved: true)
    late.unlock(); await waitForMail { !late.busy }; late.compose(); await waitForMail { lateRunner.calls.count == 3 }
    late.lock(); try? await Task.sleep(for: .milliseconds(150))
    #expect(late.draft == nil); #expect(late.phase == .locked)
}

@Test @MainActor func nativeMailFailedDraftSaveRetainsComposerAndSuccessfulSaveCanClose() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot),
        .init(method: "compose", result: .init(draft: linkedDraft)),
        .init(method: "save_draft", result: .init(), failure: .draftFailed),
        .init(method: "save_draft", result: .init(draft: linkedDraft)),
        .init(method: "close_draft", result: .init(closed: true)), .init(method: "snapshot", result: mailSnapshot)
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }; store.compose(); await waitForMail { !store.busy }
    store.saveDraft(linkedDraft.content, close: true); await waitForMail { !store.busy }
    #expect(store.draft != nil); #expect(runner.calls.last == "save_draft")
    store.saveDraft(linkedDraft.content, close: true); await waitForMail { !store.busy }
    #expect(store.draft == nil); #expect(store.notice == "Draft saved")
    store.lock()
}

@Test @MainActor func nativeMailPreviewComposeSaveAndSendAreSynthetic() async {
    let runner = SyntheticMailRunner([]), store = mailStore(runner, preview: true)
    store.selectedItem = 12; store.compose("reply")
    #expect(store.draft?.sender == "alex.demo@gmail.com")
    let content = store.draft!.content
    store.saveDraft(content); store.sendDraft(content)
    #expect(store.draft == nil); #expect(store.notice == "Demo message sent · nothing was delivered")
    #expect(runner.calls.isEmpty)
}

@Test @MainActor func nativeMailPreflightRejectionAllowsCorrectionButNeverRetriesAutomatically() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot),
        .init(method: "compose", result: .init(draft: linkedDraft)),
        .init(method: "send_draft", result: .init(), failure: .sendRejected)
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }; store.compose(); await waitForMail { !store.busy }
    store.sendDraft(linkedDraft.content); await waitForMail { !store.busy }
    #expect(store.draft?.state == .editing)
    #expect(runner.calls.filter { $0 == "send_draft" }.count == 1)
    store.markDraftEdited(); #expect(store.composeStatus == nil)
    store.lock()
}

@Test @MainActor func mailSavedListAppearsBeforeRefreshAndNeverClaimsServerSync() async {
    var saved = mailSnapshot; saved.fresh = false
    var refreshing = mailSnapshot; refreshing.loading = true; refreshing.fresh = false
    var fresh = mailSnapshot; fresh.fresh = true
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected, cacheFirst: true)),
        .init(method: "snapshot", result: saved),
        .init(method: "message", result: .init(id: 11, body: "SYNTHETIC cached body")),
        .init(method: "snapshot", result: refreshing),
        .init(method: "snapshot", result: fresh)
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }
    #expect(store.messages.count == 1); #expect(store.showingSavedContent)
    #expect(store.lastSynced == nil); #expect(runner.payloads[1].mode == "local")
    store.selectedItem = 11; store.select(); await waitForMail { store.body != nil }
    await waitForMail { store.lastSynced != nil }
    #expect(runner.payloads.filter { $0.method == "snapshot" }.map(\.mode) == ["local", "refresh", "poll"])
    #expect(store.selectedItem == 11); #expect(store.body == "SYNTHETIC cached body")
    #expect(!store.showingSavedContent); #expect(!store.loading)
    store.lock()
}

@Test @MainActor func mailRefreshFailureRetainsSavedContentAndLockStopsScheduledWork() async {
    var saved = mailSnapshot; saved.fresh = false
    var failed = saved; failed.refreshFailed = true
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected, cacheFirst: true)),
        .init(method: "snapshot", result: saved), .init(method: "snapshot", result: failed)
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }
    await waitForMail { store.cacheRefreshFailed }
    #expect(store.messages.count == 1); #expect(store.showingSavedContent)
    #expect(store.lastSynced == nil); #expect(store.error != nil)
    store.lock(); #expect(!store.cacheRefreshFailed); #expect(!store.showingSavedContent)
    let stopped = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected, cacheFirst: true)),
        .init(method: "snapshot", result: saved)
    ])
    let locked = mailStore(stopped, saved: true)
    locked.unlock(); await waitForMail { !locked.busy }; locked.lock()
    try? await Task.sleep(for: .milliseconds(500))
    #expect(stopped.calls == ["restore", "snapshot"]); #expect(locked.messages.isEmpty)
}

@Test @MainActor func mailRichContentClearsOnSelectionChangeAndLock() async {
    let runner = SyntheticMailRunner([
        .init(method: "login", result: .init(phase: .connected)),
        .init(method: "snapshot", result: mailSnapshot),
        .init(method: "message", result: .init(id: 11, body: "Synthetic", sanitizedHTML: "<h1>Synthetic</h1>")),
        .init(method: "message", result: .init(id: 11, body: "Late synthetic", sanitizedHTML: "<h1>Late synthetic</h1>"), delay: .milliseconds(100))
    ])
    let store = mailStore(runner)
    store.signIn(username: "demo@example.com", password: "SYNTHETIC")
    await waitForMail { !store.busy }
    store.selectedItem = 11; store.select()
    await waitForMail { store.sanitizedHTML != nil }
    store.select(); #expect(store.sanitizedHTML == nil)
    store.lock()
    try? await Task.sleep(for: .milliseconds(160))
    #expect(store.body == nil); #expect(store.sanitizedHTML == nil)
}

@Test @MainActor func mailActionsUseOneSelectedMessageAndSDKUndoToken() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot),
        .init(method: "message", result: .init(id: 11, body: "SYNTHETIC", actions: [.archive])),
        .init(method: "message_action", result: .init(id: 11, queued: true, undoToken: 42)),
        .init(method: "snapshot", result: .init(folders: mailSnapshot.folders, folder: 1, messages: [], loading: false)),
        .init(method: "undo_action", result: .init(queued: true)), .init(method: "snapshot", result: mailSnapshot)
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.selectedItem = 11; store.select(); await waitForMail { store.body != nil }
    #expect(!store.canPerform(.trash)); #expect(store.canPerform(.archive))
    store.actOnMessage(.trash); #expect(runner.calls.count == 3)
    store.actOnMessage(.archive); await waitForMail { !store.busy }
    #expect(store.selectedItem == nil); #expect(store.messages.isEmpty); #expect(store.canUndoAction)
    let command = runner.payloads.first { $0.method == "message_action" }
    #expect(command?.item == 11); #expect(command?.folder == 1); #expect(command?.action == .archive)
    store.undoMessageAction(); await waitForMail { !store.busy }
    #expect(store.messages.count == 1); #expect(!store.canUndoAction)
    #expect(runner.payloads.first { $0.method == "undo_action" }?.token == 42)
    store.undoMessageAction(); #expect(runner.calls.count == 7)
    store.lock()
}

@Test @MainActor func uncertainMailActionDoesNotRetryAndNeedsRefresh() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot),
        .init(method: "message", result: .init(id: 11, body: "SYNTHETIC", actions: [.trash])),
        .init(method: "message_action", result: .init(), failure: .actionUncertain),
        .init(method: "snapshot", result: mailSnapshot)
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.selectedItem = 11; store.select(); await waitForMail { store.body != nil }
    store.actOnMessage(.trash); await waitForMail { !store.busy }
    #expect(store.mustRefreshBeforeActions); #expect(store.selectedItem == 11); #expect(store.body == "SYNTHETIC")
    store.actOnMessage(.trash); #expect(runner.calls.filter { $0 == "message_action" }.count == 1)
    store.refresh(); await waitForMail { !store.busy }
    #expect(!store.mustRefreshBeforeActions); #expect(runner.calls.filter { $0 == "message_action" }.count == 1)
    store.lock()
}

@Test @MainActor func lockRejectsLateMailActionAndDropsUndo() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore", result: .init(phase: .connected)), .init(method: "snapshot", result: mailSnapshot),
        .init(method: "message", result: .init(id: 11, body: "SYNTHETIC", actions: [.archive])),
        .init(method: "message_action", result: .init(id: 11, queued: true, undoToken: 42), delay: .milliseconds(120))
    ])
    let store = mailStore(runner, saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.selectedItem = 11; store.select(); await waitForMail { store.body != nil }
    store.actOnMessage(.archive); await waitForMail { runner.calls.count == 4 }
    store.lock(); try? await Task.sleep(for: .milliseconds(180))
    #expect(store.phase == .locked); #expect(store.undoToken == nil); #expect(store.messageActions.isEmpty)
    #expect(store.messages.isEmpty); #expect(runner.calls.count == 4)
}

@Test @MainActor func previewMailTrashRestoreAndUndoNeverStartHelper() {
    let runner = SyntheticMailRunner([])
    let store = mailStore(runner, preview: true)
    store.actOnMessage(.trash); #expect(store.messages.count == 1); #expect(store.canUndoAction)
    store.undoMessageAction(); #expect(store.messages.count == 2)
    store.selectedItem = 11; store.select(); store.actOnMessage(.trash)
    store.selectedFolder = 4; store.changeFolder(); #expect(store.messages.count == 1)
    store.selectedItem = 11; store.select(); store.actOnMessage(.inbox); #expect(store.messages.isEmpty)
    store.selectedFolder = 1; store.changeFolder(); #expect(store.messages.count == 2)
    #expect(runner.calls.isEmpty); store.lock()
}

private let threadAnchor = NativeMailMessage(id: 11, subject: "Synthetic conversation", sender: "sam@example.com", recipient: "alex@example.com", date: 1, conversationID: 70)
private let threadChild = NativeMailMessage(id: 13, subject: "Re: Synthetic conversation", sender: "alex@example.com", recipient: "sam@example.com", date: 2, conversationID: 70)
private let threadSnapshot = NativeMailResult(folders: [NativeMailFolder(id: 1,name: "Inbox"),NativeMailFolder(id: 2,name: "Sent")], folder: 1,messages: [threadAnchor],loading: false,email: "alex@example.com")
private let threadResult = NativeMailResult(thread: NativeMailThread(anchor: 11,conversationID: 70,messages: [threadAnchor,threadChild]))

@Test @MainActor func mailThreadIncludesSentMemberAndReplyTargetsExpandedMessage() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore",result: .init(phase: .connected)), .init(method: "snapshot",result: threadSnapshot),
        .init(method: "thread",result: threadResult), .init(method: "message",result: .init(id: 11,body: "SYNTHETIC received",actions: [.read])),
        .init(method: "message",result: .init(id: 13,body: "SYNTHETIC sent",actions: [.unread])),
        .init(method: "compose",result: .init(draft: linkedDraft))
    ])
    let store = mailStore(runner,saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.selectedItem = 11; store.select(); await waitForMail { store.body != nil }
    #expect(store.thread?.messages.map(\.id) == [11,13]); #expect(store.messages.map(\.id) == [11])
    store.expandThreadMessage(13); await waitForMail { store.body == "SYNTHETIC sent" }
    #expect(store.selectedItem == 11); #expect(store.selectedMessage?.id == 13); #expect(store.canPerform(.unread))
    store.compose("reply"); await waitForMail { !store.busy }
    #expect(runner.payloads.last?.method == "compose"); #expect(runner.payloads.last?.item == 13)
    store.lock(); #expect(store.thread == nil); #expect(store.expandedThreadItem == nil); #expect(store.body == nil)
}

@Test @MainActor func mailThreadActionIsSingleMessageAndRefreshKeepsExpandedChild() async {
    let runner = SyntheticMailRunner([
        .init(method: "restore",result: .init(phase: .connected)), .init(method: "snapshot",result: threadSnapshot),
        .init(method: "thread",result: threadResult), .init(method: "message",result: .init(id: 11,body: "anchor")),
        .init(method: "message",result: .init(id: 13,body: "child",actions: [.archive])),
        .init(method: "message_action",result: .init(id: 13,queued: true,undoToken: 1)), .init(method: "snapshot",result: threadSnapshot),
        .init(method: "thread",result: threadResult), .init(method: "message",result: .init(id: 13,body: "child refreshed",actions: [.read])),
        .init(method: "undo_action",result: .init(queued: true)), .init(method: "snapshot",result: threadSnapshot),
        .init(method: "thread",result: threadResult), .init(method: "message",result: .init(id: 13,body: "child restored",actions: [.archive]))
    ])
    let store = mailStore(runner,saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.selectedItem = 11; store.select(); await waitForMail { store.body == "anchor" }
    store.expandThreadMessage(13); await waitForMail { store.body == "child" }
    store.actOnMessage(.archive); await waitForMail { store.body == "child refreshed" && !store.busy }
    #expect(runner.payloads.first(where: { $0.method == "message_action" })?.item == 13)
    #expect(store.selectedMessage?.id == 13); #expect(store.canPerform(.read)); #expect(store.canUndoAction)
    store.undoMessageAction(); await waitForMail { store.body == "child restored" && !store.busy }
    #expect(store.selectedMessage?.id == 13); #expect(store.canPerform(.archive))
    #expect(runner.payloads.first(where: { $0.method == "undo_action" })?.token == 1); store.lock()
}

@Test @MainActor func failedOrInvalidThreadStillAllowsAnchorButNeverDisclosesOtherBodies() async {
    for invalid in [false,true] {
        let bad = NativeMailResult(thread: NativeMailThread(anchor: 11,conversationID: 99,messages: [threadChild]))
        let runner = SyntheticMailRunner([
            .init(method: "restore",result: .init(phase: .connected)), .init(method: "snapshot",result: threadSnapshot),
            .init(method: "thread",result: invalid ? bad : .init(),failure: invalid ? nil : .threadTooLarge),
            .init(method: "message",result: .init(id: 11,body: "only anchor")),
            .init(method: "message",result: .init(id: 11,body: "individual mode"))
        ])
        let store = mailStore(runner,saved: true)
        store.unlock(); await waitForMail { !store.busy }
        store.selectedItem = 11; store.select(); await waitForMail { store.body != nil }
        #expect(store.thread == nil); #expect(store.threadError != nil); #expect(store.expandedThreadItem == 11)
        store.expandThreadMessage(13); #expect(store.selectedMessage?.id == 11)
        store.conversationView = false; store.select(); await waitForMail { store.body == "individual mode" }
        #expect(runner.calls.filter { $0 == "thread" }.count == 1)
        #expect(runner.payloads.filter { $0.method == "message" }.allSatisfy { $0.item == 11 }); store.lock()
    }
}

@Test @MainActor func lockingDuringThreadFetchCannotReopenOrDecryptLateMembers() async {
    let gate = MailReplyGate()
    let runner = SyntheticMailRunner([
        .init(method: "restore",result: .init(phase: .connected)), .init(method: "snapshot",result: threadSnapshot),
        .init(method: "thread",result: threadResult,gate: gate)
    ])
    let store = mailStore(runner,saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.selectedItem = 11; store.select(); await waitForMail { runner.calls.count == 3 }
    #expect(store.threadLoading); store.lock(); await gate.release()
    // Give the already-scheduled late continuation its turn, without network timing assumptions.
    for _ in 0..<20 { await Task.yield() }
    #expect(store.thread == nil); #expect(store.body == nil); #expect(store.phase == .locked)
    #expect(runner.calls == ["restore","snapshot","thread"])
}

@Test @MainActor func folderSwitchRejectsLateThreadMessageAndClearsThreadScope() async {
    let gate = MailReplyGate()
    let runner = SyntheticMailRunner([
        .init(method: "restore",result: .init(phase: .connected)), .init(method: "snapshot",result: threadSnapshot),
        .init(method: "thread",result: threadResult), .init(method: "message",result: .init(id: 11,body: "anchor")),
        .init(method: "message",result: .init(id: 13,body: "LATE synthetic body"),gate: gate),
        .init(method: "snapshot",result: .init(folders: [NativeMailFolder(id: 1,name: "Inbox"),NativeMailFolder(id: 2,name: "Sent")],folder: 2,messages: [],loading: false))
    ])
    let store = mailStore(runner,saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.selectedItem = 11; store.select(); await waitForMail { store.body == "anchor" }
    store.expandThreadMessage(13); await waitForMail { runner.calls.count == 5 }
    store.selectedFolder = 2; store.changeFolder(); await waitForMail { !store.busy }
    await gate.release(); for _ in 0..<20 { await Task.yield() }
    #expect(store.thread == nil); #expect(store.body == nil); #expect(store.selectedItem == nil)
    #expect(store.selectedFolder == 2); store.lock()
}

@Test @MainActor func collapsingPendingThreadBodyRejectsLateContentAndAllowsReopening() async {
    let gate = MailReplyGate()
    let runner = SyntheticMailRunner([
        .init(method: "restore",result: .init(phase: .connected)), .init(method: "snapshot",result: threadSnapshot),
        .init(method: "thread",result: threadResult), .init(method: "message",result: .init(id: 11,body: "anchor")),
        .init(method: "message",result: .init(id: 13,body: "late synthetic body",actions: [.archive]),gate: gate),
        .init(method: "message",result: .init(id: 13,body: "reopened synthetic body",actions: [.read]))
    ])
    let store = mailStore(runner,saved: true)
    store.unlock(); await waitForMail { !store.busy }
    store.selectedItem = 11; store.select(); await waitForMail { store.body == "anchor" }
    store.expandThreadMessage(13); await waitForMail { runner.calls.count == 5 }
    store.expandThreadMessage(13)
    #expect(store.selectedItem == 11 && store.expandedThreadItem == nil && store.body == nil)
    #expect(store.selectedMessage == nil && !store.canPerform(.archive))
    await gate.release(); for _ in 0..<20 { await Task.yield() }
    #expect(store.expandedThreadItem == nil && store.body == nil && !store.canPerform(.archive))
    store.expandThreadMessage(13); await waitForMail { store.body == "reopened synthetic body" }
    #expect(store.selectedItem == 11 && store.selectedMessage?.id == 13 && store.canPerform(.read))
    store.lock()
}

@Test @MainActor func previewThreadTraversesFoldersCollapsesAndNeverStartsHelper() {
    let runner = SyntheticMailRunner([]), store = mailStore(runner,preview: true)
    store.selectedItem = 12; store.select()
    #expect(store.thread?.messages.map(\.id) == [12,13,14])
    store.expandThreadMessage(13); #expect(store.body?.contains("Saturday sounds good") == true)
    store.compose("reply")
    #expect(store.draft?.sender == "alex.demo@gmail.com"); #expect(store.draft?.to == ["sam@example.com"])
    #expect(store.draft?.subject == "Re: Coffee this weekend?"); #expect(store.draft?.quote.contains("Shall we meet at ten?") == true)
    store.discardDraft()
    store.expandThreadMessage(13); #expect(store.body == nil); #expect(store.expandedThreadItem == nil); #expect(!store.canPerform(.read))
    store.compose("reply"); #expect(store.draft == nil)
    store.selectedFolder = 2; store.changeFolder(); #expect(store.visibleConversations.count == 1)
    store.conversationView = false; #expect(store.visibleConversations.count == 2)
    store.lock(); #expect(runner.calls.isEmpty)
}

@Test @MainActor func switchingProductsCancelsMailBiometricsBeforeAnyHelperAccess() async {
    let gate = MailReplyGate(), runner = SyntheticMailRunner([])
    let store = mailStore(runner, saved: true, unlock: { await gate.wait(); return true })
    let name = "ProtonXUnlockTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
    let workspace = SuiteWorkspace(defaults: defaults, previewOnly: false, initialProduct: .mail, makeMail: { store })
    store.unlock(mode: .touchID)
    await waitForMail { store.localAuthentication.state == .authenticating }
    workspace.select(nil)
    #expect(store.phase == .locked); #expect(!store.busy)
    await gate.release()
    for _ in 0..<100 { await Task.yield() }
    #expect(store.phase == .locked); #expect(runner.calls.isEmpty)
    #expect(store.localAuthentication.state == .cancelled)
}

@Test @MainActor func passwordFallbackCancelsPendingBiometricsAndRestoresOnlyOnce() async {
    let gate = MailReplyGate()
    let runner = SyntheticMailRunner([.init(method: "restore", result: NativeMailResult(phase: .connected)), .init(method: "snapshot", result: mailSnapshot)])
    var attempts = 0
    let store = mailStore(runner, saved: true, unlock: {
        attempts += 1
        if attempts == 1 { await gate.wait() }
        return true
    })
    store.unlock(mode: .touchID)
    await waitForMail { attempts == 1 }
    store.unlock(mode: .system)
    await waitForMail { !store.busy }
    await gate.release()
    for _ in 0..<100 { await Task.yield() }
    #expect(store.phase == .open); #expect(attempts == 2)
    #expect(runner.calls == ["restore", "snapshot"])
    store.lock()
}
