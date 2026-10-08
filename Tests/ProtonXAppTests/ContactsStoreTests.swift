// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private actor ContactsRunner: NativeMailRunning {
    private(set) var methods: [String] = []
    var held: String?
    var failure: NativeMailFailure?
    private var pending: CheckedContinuation<Void, Never>?
    func configure(hold: String? = nil, failure: NativeMailFailure? = nil) { held = hold; self.failure = failure }
    func release() { pending?.resume(); pending = nil }
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        methods.append(command.method)
        if command.method == held {
            // Hold exactly one response so a second selection can complete first.
            held = nil
            await withCheckedContinuation { pending = $0 }
        }
        if ["contacts", "contact_detail"].contains(command.method), let failure { throw failure }
        switch command.method {
        case "login", "restore": return .init(phase: .connected)
        case "snapshot": return .init(folders: [.init(id: 1, name: "Inbox")], folder: 1, messages: [], loading: false, email: "alex@example.com")
        case "contacts": return .init(contacts: [
            .init(localID: 10, name: "Sam Rivera", emails: [.init(contactID: 10, name: "Sam", email: "sam@example.com")]),
            .init(localID: 20, name: "Jamie Chen", emails: [.init(contactID: 20, name: "Jamie", email: "jamie@example.com")])])
        case "contact_detail": return .init(contactDetail: .init(localID: command.item!, fields: [.init("Note", "Synthetic contact \(command.item!)")]))
        case "compose": return .init(draft: .init(token: 70, sender: "alex@example.com", senders: ["alex@example.com"], state: .editing))
        default: throw ProtonXError.invalidResponse
        }
    }
    nonisolated func cancelAll() {}
}
@Suite @MainActor struct ContactsStoreTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "ContactsTests." + UUID().uuidString)! }
    func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await condition())
    }
    private func open(_ runner: ContactsRunner) async throws -> NativeMailStore {
        let store = NativeMailStore(runner: runner, defaults: defaults(), localUnlock: { true })
        store.signIn(username: "alex@example.com", password: "SYNTHETIC")
        try await wait { store.phase == .open && !store.busy }; return store
    }
    @Test func contactsNeverRestoreLockedMailAndLateListCannotReopenIt() async throws {
        let runner = ContactsRunner(), d = defaults(); d.set(true, forKey: "nativeMailConnected")
        let locked = NativeMailStore(runner: runner, defaults: d, localUnlock: { true })
        locked.loadContacts(); #expect(await runner.methods.isEmpty)
        let store = try await open(runner); await runner.configure(hold: "contacts")
        store.loadContacts(); try await wait { await runner.methods.contains("contacts") }
        store.lock(); await runner.release(); for _ in 0..<30 { await Task.yield() }
        #expect(store.phase == .locked && store.contacts.isEmpty && !store.contactsLoaded && !store.contactsBusy)
    }
    @Test func selectionRaceAndLockDiscardDetails() async throws {
        let runner = ContactsRunner(), store = try await open(runner)
        store.loadContacts(); try await wait { store.contactsLoaded }
        await runner.configure(hold: "contact_detail")
        store.selectContact("contact:10"); try await wait { await runner.methods.contains("contact_detail") }
        store.selectContact("contact:20"); await runner.release()
        try await wait { store.contactDetail?.localID == 20 }
        #expect(store.contactDetail?.fields.first?.value == "Synthetic contact 20")
        store.lock(); #expect(store.contactDetail == nil && store.contacts.isEmpty && store.selectedContact == nil)
    }
    @Test func expiredContactReadLocksMailAndRetryDoesNotEraseDraft() async throws {
        let runner = ContactsRunner(), store = try await open(runner)
        store.compose(); try await wait { !store.busy }; store.editorState?.text = "Retain this synthetic draft"
        await runner.configure(failure: .contactsFailed); store.loadContacts(); try await wait { !store.contactsBusy }
        #expect(store.contactsError != nil && store.editorState?.text == "Retain this synthetic draft")
        await runner.configure(); store.loadContacts(); try await wait { store.contactsLoaded }
        await runner.configure(failure: .sessionExpired); store.selectContact("contact:10"); try await wait { store.phase == .welcome }
        #expect(store.contacts.isEmpty && store.draft == nil)
    }
    @Test func pickerIsBoundToDisclosedAddressesAndCurrentDraft() async throws {
        let runner = ContactsRunner(), store = try await open(runner)
        store.loadContacts(); try await wait { store.contactsLoaded }; store.compose(); try await wait { !store.busy }
        store.editorState?.text = "Synthetic unsaved body"; store.editorState?.bcc = "SAM@example.com"
        #expect(!store.addContactRecipients(["sam@example.com"], field: "to", token: 71))
        #expect(!store.addContactRecipients(["undisclosed@example.com"], field: "to", token: 70))
        #expect(store.addContactRecipients(["sam@example.com", "jamie@example.com"], field: "to", token: 70))
        #expect(store.editorState?.to == "jamie@example.com" && store.editorState?.bcc == "SAM@example.com" && store.editorState?.text == "Synthetic unsaved body")
        store.editorState?.to = "partial@"
        #expect(!store.addContactRecipients(["sam@example.com"], field: "to", token: 70)); #expect(store.editorState?.to == "partial@")
    }
    @Test func contactsNavigationRetainsMailAndReturnsAfterExplicitUnlock() async throws {
        let d = defaults(), runner = ContactsRunner(); d.set(true, forKey: "nativeMailConnected")
        let suite = SuiteWorkspace(defaults: d, previewOnly: false, makeMail: { NativeMailStore(runner: runner, defaults: d, localUnlock: { true }) })
        suite.select(.contacts); #expect(suite.mail?.phase == .locked); #expect(await runner.methods.isEmpty)
        suite.openMailForContacts(); suite.mail?.unlock(); try await wait { suite.selected == .contacts && suite.mail?.busy == false }
        let mail = suite.mail!; mail.query = "Retained inbox search"; suite.writeContactEmail(["sam@example.com"])
        try await wait { mail.draft != nil && !mail.busy }; mail.editorState?.text = "Retain across products"
        suite.select(.contacts); suite.select(.mail)
        #expect(suite.mail === mail && mail.query == "Retained inbox search" && mail.editorState?.to == "sam@example.com" && mail.editorState?.text == "Retain across products")
        suite.lock(); #expect(mail.contacts.isEmpty && mail.editorState == nil)
    }
    @Test func previewDoesNotStartAnyAccountHelper() async throws {
        let runner = ContactsRunner(), store = NativeMailStore(runner: runner, defaults: defaults(), previewOnly: true)
        store.loadContacts(); store.selectContact("contact:10"); store.compose(recipients: ["sam@example.com"])
        #expect(store.contacts.count == 3 && store.contactDetail != nil && store.editorState?.to == "sam@example.com")
        #expect(await runner.methods.isEmpty)
    }
}
