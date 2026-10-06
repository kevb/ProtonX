import SwiftUI
import LocalAuthentication
import ProtonXCore

@MainActor
final class NativeMailStore: ObservableObject {
    enum Phase: Equatable { case welcome, locked, signingIn, totp, mailboxPassword, securityKey, open }
    @Published private(set) var phase: Phase = .welcome
    @Published private(set) var folders: [NativeMailFolder] = []
    @Published private(set) var messages: [NativeMailMessage] = []
    @Published private(set) var body: String?
    @Published private(set) var email = ""
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    @Published private(set) var lastSynced: Date?
    @Published private(set) var demo = false
    @Published var selectedFolder: UInt64?
    @Published var selectedItem: UInt64?
    @Published var query = ""
    @Published var error: String?
    @Published private(set) var draft: NativeMailDraft?
    @Published private(set) var composeStatus: String?
    @Published private(set) var notice: String?
    private var sendPolling: Task<Void, Never>?
    let previewOnly: Bool
    private let runner: any NativeMailRunning
    private let defaults: UserDefaults
    private let localUnlock: (@MainActor @Sendable () async throws -> Bool)?
    private var epoch = SessionEpoch(), selectionEpoch = SessionEpoch()
    private var operation: Task<Void, Never>?, selection: Task<Void, Never>?, polling: Task<Void, Never>?
    private var auth: LAContext?
    private var hasSession: Bool
    private var loadedFolder: UInt64?
    private var demoMessages: [NativeMailMessage] = []
    private var demoBodies: [UInt64: String] = [:]
    init(runner: (any NativeMailRunning)? = nil, defaults: UserDefaults = .standard, previewOnly: Bool = false, localUnlock: (@MainActor @Sendable () async throws -> Bool)? = nil) {
        self.defaults = defaults; self.previewOnly = previewOnly; self.localUnlock = localUnlock
        self.runner = runner ?? NativeMailProcess(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/protonx-mail"), directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ProtonX/Mail"))
        hasSession = !previewOnly && defaults.bool(forKey: "nativeMailConnected")
        phase = hasSession ? .locked : .welcome
        if previewOnly { enterDemo() }
    }
    var visibleMessages: [NativeMailMessage] {
        messages.filter { query.isEmpty || $0.subject.localizedStandardContains(query) || $0.sender.localizedStandardContains(query) || $0.senderName.localizedStandardContains(query) }
    }
    var selectedMessage: NativeMailMessage? { visibleMessages.first { $0.id == selectedItem } }
    var isLoadingList: Bool { phase == .open && !demo && (loading || (busy && (loadedFolder == nil || loadedFolder != selectedFolder))) }
    var initialListFailed: Bool { phase == .open && !demo && !busy && error != nil && (loadedFolder == nil || loadedFolder != selectedFolder) }
    func signIn(username: String, password: String) {
        guard !previewOnly, !busy, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        if demo { lock(); demo = false }
        perform { [self] captured in
            phase = .signingIn
            let result = try await runner.request(NativeMailCommand("login", username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password))
            try check(captured); try await applyAuthentication(result, captured: captured)
        }
    }
    func submitChallenge(_ value: String) {
        guard !previewOnly, !busy else { return }
        let command: NativeMailCommand
        switch phase {
        case .totp: command = NativeMailCommand("totp", code: value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .mailboxPassword: command = NativeMailCommand("mailbox_password", password: value)
        default: return
        }
        perform { [self] captured in
            let result = try await runner.request(command)
            try check(captured); try await applyAuthentication(result, captured: captured)
        }
    }
    func unlock() {
        guard !busy, !previewOnly else { return }
        if demo { enterDemo(); return }
        let context = LAContext(); auth = context
        perform { [self] captured in
            let allowed: Bool
            if let localUnlock { allowed = try await localUnlock() }
            else { allowed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock ProtonX Mail on this Mac") }
            guard allowed else { throw ProtonXError.cancelled }
            try check(captured)
            let result = try await runner.request(NativeMailCommand("restore"))
            try check(captured); try await applyAuthentication(result, captured: captured)
        }
    }
    private func applyAuthentication(_ result: NativeMailResult, captured: UInt64) async throws {
        switch result.phase {
        case .totp: phase = .totp
        case .mailboxPassword: phase = .mailboxPassword
        case .securityKey: phase = .securityKey
        case .connected:
            hasSession = true; defaults.set(true, forKey: "nativeMailConnected"); phase = .open
            try await load(captured: captured)
        default: throw ProtonXError.invalidResponse
        }
    }
    func refresh(more: Bool = false) {
        guard phase == .open, !demo, !busy else { return }
        perform { [self] captured in try await load(captured: captured, more: more) }
    }
    private func load(captured: UInt64, more: Bool = false) async throws {
        let folder = selectedFolder
        let result = try await runner.request(NativeMailCommand("snapshot", folder: folder, more: more))
        try check(captured)
        guard selectedFolder == folder else { return }
        guard let nextFolders = result.folders, let nextMessages = result.messages, let nextFolder = result.folder, nextFolders.contains(where: { $0.id == nextFolder }) else { throw ProtonXError.invalidResponse }
        folders = nextFolders; messages = nextMessages; selectedFolder = nextFolder; loadedFolder = nextFolder
        email = result.email ?? ""; loading = result.loading ?? false
        if !loading { lastSynced = Date() }
        reconcileSelection()
        // Only incomplete initial sync is polled. No polling when the window is locked/closed.
        polling?.cancel()
        if loading {
            polling = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.epoch.accepts(captured), self.phase == .open else { return }
                self.refresh()
            }
        }
    }
    func changeFolder() {
        guard selectedFolder != loadedFolder else { return }
        body = nil; selectedItem = nil; selectionEpoch.invalidate(); selection?.cancel()
        messages = []
        if demo { messages = selectedFolder == 1 ? demoMessages : []; loadedFolder = selectedFolder; return }
        refresh()
    }
    func reconcileSelection() {
        if let selectedItem, !visibleMessages.contains(where: { $0.id == selectedItem }) {
            self.selectedItem = nil; body = nil; selectionEpoch.invalidate(); selection?.cancel()
        }
    }
    func select() {
        body = nil; error = nil; selectionEpoch.invalidate(); selection?.cancel()
        guard let item = selectedMessage?.id else { return }
        if demo { body = demoBodies[item]; return }
        guard let folder = selectedFolder, phase == .open else { return }
        let captured = epoch.value, selectedGeneration = selectionEpoch.value
        selection = Task { [self] in
            do {
                let result = try await runner.request(NativeMailCommand("message", folder: folder, item: item))
                try check(captured)
                guard selectionEpoch.accepts(selectedGeneration), selectedItem == item, selectedFolder == folder else { return }
                guard result.id == item, let next = result.body else { throw ProtonXError.invalidResponse }
                body = next
            } catch {
                if !Task.isCancelled && epoch.accepts(captured) && selectionEpoch.accepts(selectedGeneration) {
                    if (error as? NativeMailFailure) == .sessionExpired { expireSession() }
                    self.error = safeError(error)
                }
            }
        }
    }
    func compose(_ mode: String = "new") {
        guard phase == .open, !busy, draft == nil else { return }
        guard mode == "new" || selectedMessage != nil else { return }
        if mode == "open" { guard selectedMessage?.isDraft == true, selectedMessage?.isScheduled != true else { return } }
        if mode == "reply" || mode == "reply_all" { guard selectedMessage?.canReply != false else { return } }
        notice = nil; composeStatus = nil
        if demo {
            let reply = mode != "new" ? selectedMessage : nil
            let sender = reply?.recipient == "alex.demo@gmail.com" ? "alex.demo@gmail.com" : email
            draft = NativeMailDraft(token: 1, sender: sender, senders: [email, "alex.demo@gmail.com"], to: reply.map { [$0.sender] } ?? [], subject: reply.map { "Re: " + $0.subject } ?? "", quote: reply == nil ? "Alex" : "\n\nOn Tuesday, Sam wrote:\n> Coffee on Saturday?", state: .editing)
            return
        }
        perform { [self] captured in
            let result = try await runner.request(NativeMailCommand("compose", folder: mode == "new" ? nil : selectedFolder, item: mode == "new" ? nil : selectedItem, mode: mode))
            try check(captured)
            guard let next = result.draft else { throw ProtonXError.invalidResponse }
            draft = next
        }
    }
    func markDraftEdited() {
        if draft?.state == .editing { composeStatus = nil }
    }
    func saveDraft(_ content: NativeMailComposeContent, close: Bool = false) {
        guard phase == .open, !busy, let draft, draft.state == .editing else { return }
        do { try content.validate(senders: draft.senders, sending: false) } catch { self.error = safeError(error); return }
        if demo { composeStatus = "Demo draft saved · no account accessed"; if close { self.draft = nil }; return }
        perform { [self] captured in
            let result = try await runner.request(NativeMailCommand("save_draft", token: draft.token, content: content))
            try check(captured)
            guard result.draft?.token == draft.token else { throw ProtonXError.invalidResponse }
            self.draft = result.draft; composeStatus = "Draft saved locally · syncing with Proton"
            if close {
                let closed = try await runner.request(NativeMailCommand("close_draft", token: draft.token))
                try check(captured); guard closed.closed == true else { throw ProtonXError.invalidResponse }
                self.draft = nil; notice = "Draft saved"; try await load(captured: captured)
            }
        }
    }
    func closePendingDraft() {
        guard phase == .open, !busy, let draft, draft.state != .editing else { return }
        sendPolling?.cancel()
        perform { [self] captured in
            do {
                let result = try await runner.request(NativeMailCommand("close_draft", token: draft.token))
                try check(captured); guard result.closed == true else { throw ProtonXError.invalidResponse }
            } catch {
                try check(captured)
                // A lost connection cannot cancel a queued send. Closing this local
                // composer never deletes a draft or creates another send action.
                self.error = safeError(error)
            }
            self.draft = nil; composeStatus = nil; notice = "Check Sent and Drafts · delivery was not confirmed"
        }
    }
    func discardDraft() {
        guard phase == .open, !busy, let draft, draft.state == .editing else { return }
        if demo { self.draft = nil; return }
        perform { [self] captured in
            let result = try await runner.request(NativeMailCommand("discard_draft", token: draft.token))
            try check(captured); guard result.closed == true else { throw ProtonXError.invalidResponse }
            self.draft = nil; composeStatus = nil; try await load(captured: captured)
        }
    }
    func sendDraft(_ content: NativeMailComposeContent) {
        guard phase == .open, !busy, let draft, draft.state == .editing else { return }
        do { try content.validate(senders: draft.senders, sending: true) } catch { self.error = safeError(error); return }
        if demo { self.draft = nil; notice = "Demo message sent · nothing was delivered"; return }
        perform { [self] captured in
            // Sending is a deliberate user action. Once the IPC request starts,
            // an ambiguous outcome never becomes another send action automatically.
            self.draft?.state = .unknown; composeStatus = "Sending…"
            do {
                let result = try await runner.request(NativeMailCommand("send_draft", token: draft.token, content: content))
                try check(captured); try applySendResult(result, token: draft.token)
                if self.draft?.state == .queued { pollSend(token: draft.token, captured: captured) }
                if self.draft?.state == .sent { try await finishSent(token: draft.token, captured: captured) }
            } catch {
                if epoch.accepts(captured), !Task.isCancelled {
                    if (error as? NativeMailFailure) == .sendRejected {
                        self.draft?.state = .editing; composeStatus = "Message was not queued. Correct the sender or recipients and try again."
                    } else {
                        composeStatus = "Sending could not be confirmed. Check Sent and Drafts before sending again."
                    }
                }
                throw error
            }
        }
    }
    private func applySendResult(_ result: NativeMailResult, token: UInt64) throws {
        guard result.token == token, let state = result.sendState, state != .editing, draft?.token == token else { throw ProtonXError.invalidResponse }
        draft?.state = state
        switch state {
        case .queued: composeStatus = "Sending · awaiting Proton’s confirmation"
        case .sent: composeStatus = "Sent"
        case .failed: composeStatus = "Proton reported a sending failure. Check the draft in the official client before trying again."
        case .unknown: composeStatus = "Sending could not be confirmed. Check Sent and Drafts before sending again."
        case .editing: break
        }
    }
    private func finishSent(token: UInt64, captured: UInt64) async throws {
        let result = try await runner.request(NativeMailCommand("close_draft", token: token))
        try check(captured); guard result.closed == true else { throw ProtonXError.invalidResponse }
        draft = nil; notice = "Message sent"; composeStatus = nil
        try await load(captured: captured)
    }
    private func pollSend(token: UInt64, captured: UInt64) {
        sendPolling?.cancel()
        sendPolling = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.epoch.accepts(captured), self.draft?.token == token else { return }
                do {
                    let result = try await self.runner.request(NativeMailCommand("draft_status", token: token))
                    try self.check(captured); try self.applySendResult(result, token: token)
                    if self.draft?.state == .sent { try await self.finishSent(token: token, captured: captured); return }
                    if self.draft?.state == .failed { return }
                } catch {
                    guard self.epoch.accepts(captured), !Task.isCancelled else { return }
                    self.draft?.state = .unknown; self.composeStatus = NativeMailFailure.sendUncertain.localizedDescription
                    if (error as? NativeMailFailure) == .sessionExpired { self.expireSession() }
                    return
                }
            }
            guard let self, self.epoch.accepts(captured), self.draft?.token == token else { return }
            self.draft?.state = .unknown; self.composeStatus = NativeMailFailure.sendUncertain.localizedDescription
        }
    }
    func checkSendStatus() {
        sendPolling?.cancel()
        guard phase == .open, !busy, let draft, draft.state != .editing else { return }
        perform { [self] captured in
            let result = try await runner.request(NativeMailCommand("draft_status", token: draft.token))
            try check(captured); try applySendResult(result, token: draft.token)
            if self.draft?.state == .sent { try await finishSent(token: draft.token, captured: captured) }
        }
    }
    func signOut() {
        guard !previewOnly, !demo, !busy, draft == nil else { return }
        perform { [self] captured in
            _ = try await runner.request(NativeMailCommand("sign_out")); try check(captured)
            hasSession = false; defaults.set(false, forKey: "nativeMailConnected"); lock(); phase = .welcome
        }
    }
    func lock() {
        epoch.invalidate(); selectionEpoch.invalidate(); operation?.cancel(); selection?.cancel(); polling?.cancel(); sendPolling?.cancel(); auth?.invalidate(); auth = nil; runner.cancelAll()
        folders = []; messages = []; body = nil; selectedItem = nil; selectedFolder = nil; query = ""; email = ""; error = nil
        draft = nil; composeStatus = nil; notice = nil
        loading = false; lastSynced = nil; busy = false; demoBodies = [:]; demoMessages = []; loadedFolder = nil
        phase = hasSession ? .locked : .welcome
    }
    func cancelSignIn() { lock() }
    func enterDemo() {
        lock(); demo = true; phase = .open; email = "alex@example.com"
        folders = [NativeMailFolder(id: 1, name: "Inbox", count: 2), NativeMailFolder(id: 2, name: "Sent")]; selectedFolder = 1; loadedFolder = 1
        messages = [NativeMailMessage(id: 11, subject: "Welcome to your native inbox", sender: "hello@example.com", senderName: "ProtonX", recipient: "alex@example.com", date: 1791288000, unread: true), NativeMailMessage(id: 12, subject: "Coffee this weekend?", sender: "sam@example.com", senderName: "Sam", recipient: "alex.demo@gmail.com", date: 1791201600)]
        demoMessages = messages
        demoBodies = [11: "A native Mail window, with one shared menu-bar icon and Mac keyboard shortcuts.\n\nThis inbox is synthetic. No account has been accessed.\n\nThe direct Mail client uses Proton’s existing authentication and encryption core.", 12: "Hi Alex,\n\nCoffee on Saturday?\n\nSam"]
        selectedItem = 11; body = demoBodies[11]
    }
    private func expireSession() {
        hasSession = false; defaults.set(false, forKey: "nativeMailConnected")
        lock(); demo = false; phase = .welcome
    }
    private func check(_ captured: UInt64) throws { try Task.checkCancellation(); guard epoch.accepts(captured) else { throw CancellationError() } }
    private func safeError(_ error: Error) -> String {
        if let failure = error as? NativeMailFailure { return failure.localizedDescription }
        if case ProtonXError.helperMissing = error { return "This build is missing the native Mail helper. Rebuild ProtonX with Mail support." }
        return "Mail could not complete this operation. Retry or unlock your session again."
    }
    private func perform(_ action: @escaping @MainActor (UInt64) async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        let captured = epoch.value
        operation = Task { [self] in
            do { try await action(captured) }
            catch {
                if !Task.isCancelled && epoch.accepts(captured) {
                    let message = safeError(error)
                    let cancelled = (error as? ProtonXError) == .cancelled || [.userCancel, .appCancel, .systemCancel].contains((error as? LAError)?.code)
                    self.error = cancelled ? nil : message
                    if phase == .signingIn { phase = .welcome }
                    if (error as? NativeMailFailure) == .sessionExpired { expireSession(); self.error = message }
                }
            }
            if epoch.accepts(captured) { busy = false }
        }
    }
}
