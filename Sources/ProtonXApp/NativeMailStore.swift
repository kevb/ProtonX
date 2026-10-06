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
    func signOut() {
        guard !previewOnly, !demo, !busy else { return }
        perform { [self] captured in
            _ = try await runner.request(NativeMailCommand("sign_out")); try check(captured)
            hasSession = false; defaults.set(false, forKey: "nativeMailConnected"); lock(); phase = .welcome
        }
    }
    func lock() {
        epoch.invalidate(); selectionEpoch.invalidate(); operation?.cancel(); selection?.cancel(); polling?.cancel(); auth?.invalidate(); auth = nil; runner.cancelAll()
        folders = []; messages = []; body = nil; selectedItem = nil; selectedFolder = nil; query = ""; email = ""; error = nil
        loading = false; lastSynced = nil; busy = false; demoBodies = [:]; demoMessages = []; loadedFolder = nil
        phase = hasSession ? .locked : .welcome
    }
    func cancelSignIn() { lock() }
    func enterDemo() {
        lock(); demo = true; phase = .open; email = "alex@example.com"
        folders = [NativeMailFolder(id: 1, name: "Inbox", count: 2), NativeMailFolder(id: 2, name: "Sent")]; selectedFolder = 1; loadedFolder = 1
        messages = [NativeMailMessage(id: 11, subject: "Welcome to your native inbox", sender: "hello@example.com", senderName: "ProtonX", recipient: "alex@example.com", date: 1791288000, unread: true), NativeMailMessage(id: 12, subject: "Coffee this weekend?", sender: "sam@example.com", senderName: "Sam", recipient: "alex@example.com", date: 1791201600)]
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
