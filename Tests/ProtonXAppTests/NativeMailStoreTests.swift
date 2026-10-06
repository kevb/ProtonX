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
    }
    private let lock = NSLock()
    private var steps: [Step]
    private var methods: [String] = []
    init(_ steps: [Step]) { self.steps = steps }
    var calls: [String] { lock.withLock { methods } }
    func cancelAll() {}
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        let step: Step? = lock.withLock { methods.append(command.method); return steps.isEmpty ? nil : steps.removeFirst() }
        guard let step else { throw ProtonXError.invalidResponse }
        #expect(command.method == step.method)
        // Simulate a network reply arriving after the caller has cancelled/locked.
        if step.delay > .zero { await Task.detached { try? await Task.sleep(for: step.delay) }.value }
        if let failure = step.failure { throw failure }
        return step.result
    }
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
    store.selectedFolder = 2; store.changeFolder(); #expect(store.messages.isEmpty); #expect(store.body == nil)
    store.selectedFolder = 1; store.changeFolder(); #expect(store.messages.count == 2)
    store.lock(); #expect(store.body == nil); #expect(runner.calls.isEmpty)
}
