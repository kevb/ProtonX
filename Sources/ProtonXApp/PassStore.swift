import SwiftUI
import LocalAuthentication
import ProtonXCore

@MainActor
final class PassStore: ObservableObject {
    enum Phase { case welcome, locked, open }
    @Published private(set) var phase: Phase = .welcome
    @Published private(set) var isDemo = false
    @Published private(set) var vaults: [Vault] = []
    @Published private(set) var items: [PassItem] = []
    @Published var selectedVault: String?
    @Published var selectedItem: String?
    @Published var query = ""
    @Published var kind: String?
    @Published var showingTrash = false
    @Published private(set) var detail: ItemDetail?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var challenge: AuthChallenge?
    private var credentialRequestID: UUID?
    private var credentialContinuation: CheckedContinuation<String, Error>?
    private var epoch = SessionEpoch()
    private var selectionEpoch = SessionEpoch()
    private var operation: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var capabilities: PassCapabilities?
    private var demoDetails: [String: ItemDetail] = [:]
    let service: PassService
    let sessionDirectory: URL
    private var authContext: LAContext?
    private let webAuthentication = NativeWebAuthentication()
    var filteredItems: [PassItem] { ItemSearch.filter(items, query: query, vaultID: selectedVault, kind: kind) }
    var currentItem: PassItem? { items.first { $0.id == selectedItem } }
    var canCopyTOTP: Bool {
        if isDemo { return true }
        guard !showingTrash, let selectedItem, let capabilities else { return false }
        return capabilities.allowsTOTP(itemID: selectedItem, items: items)
    }
    var hasSession: Bool { FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(".session/session.json").path) }

    init() {
        sessionDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ProtonX/Pass", isDirectory: true)
        let helper = Bundle.main.url(forAuxiliaryExecutable: "protonx-pass") ??
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/protonx-pass")
        service = PassService(runner: NativeProcess(executable: helper, directory: sessionDirectory))
        phase = hasSession ? .locked : .welcome
    }
    func login(interactive: Bool = false) {
        guard !busy else { return }
        isDemo = false
        perform { [self] in
            defer { webAuthentication.cancel() }
            try await service.login(interactive: interactive) { [weak self] prompt in
                guard let self else { throw ProtonXError.cancelled }
                if let url = prompt.url { return try await self.beginWebAuthentication(url) }
                return try await self.requestCredential(prompt)
            }
            phase = .open
            try await loadSnapshot()
        }
    }
    private func beginWebAuthentication(_ value: String) throws -> String {
        guard let url = URLPolicy.authenticationURL(value) else { throw ProtonXError.invalidResponse }
        try webAuthentication.start(url: url) { [weak self] in self?.cancelLogin() }
        return "started"
    }
    private func requestCredential(_ prompt: AuthChallenge) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                credentialRequestID = id; credentialContinuation = continuation; challenge = prompt
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.credentialRequestID == id else { return }
                let continuation = self.credentialContinuation
                self.credentialRequestID = nil; self.credentialContinuation = nil; self.challenge = nil
                continuation?.resume(throwing: ProtonXError.cancelled)
            }
        }
    }
    func answerCredential(_ answer: String) {
        let continuation = credentialContinuation; credentialContinuation = nil; credentialRequestID = nil; challenge = nil
        continuation?.resume(returning: answer)
    }
    func cancelLogin() { lock(); phase = hasSession ? .locked : .welcome }
    func unlock() {
        guard !busy else { return }
        if isDemo { enterDemo(); return }
        let context = LAContext(); authContext = context
        perform { [self] in
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock ProtonX on this Mac")
            guard success else { throw ProtonXError.cancelled }
            try Task.checkCancellation()
            phase = .open
            try await loadSnapshot()
        }
    }
    func lock() {
        epoch.invalidate(); selectionEpoch.invalidate()
        authContext?.invalidate(); authContext = nil
        webAuthentication.cancel()
        operation?.cancel(); selectionTask?.cancel(); service.cancel()
        let continuation = credentialContinuation; credentialContinuation = nil; credentialRequestID = nil; challenge = nil
        continuation?.resume(throwing: ProtonXError.cancelled)
        ClipboardController.shared.clearOwned()
        vaults = []; items = []; detail = nil; demoDetails = [:]; capabilities = nil
        selectedItem = nil; selectedVault = nil; query = ""; busy = false; error = nil
        phase = hasSession || isDemo ? .locked : .welcome
    }
    func refresh() { perform { [self] in try await loadSnapshot(); selectItem() } }
    private func loadSnapshot() async throws {
        guard !isDemo else { return }
        let captured = epoch.value
        let nextCapabilities = try await service.capabilities()
        let nextVaults = try await service.vaults()
        var nextItems: [PassItem] = []
        for vault in nextVaults { try Task.checkCancellation(); nextItems += try await service.items(in: vault, trashed: showingTrash) }
        try Task.checkCancellation()
        guard epoch.accepts(captured), phase == .open else { return }
        capabilities = nextCapabilities; vaults = nextVaults; items = nextItems
        if let selectedItem, !items.contains(where: { $0.id == selectedItem }) { self.selectedItem = nil; detail = nil }
        if let selectedVault, !vaults.contains(where: { $0.id == selectedVault }) { self.selectedVault = nil }
    }
    func selectItem() {
        selectionEpoch.invalidate(); selectionTask?.cancel(); detail = nil; error = nil
        guard phase == .open, let item = currentItem else { return }
        if isDemo { detail = demoDetails[item.id]; return }
        let captured = epoch.value, selection = selectionEpoch.value
        selectionTask = Task {
            do {
                let value = try await service.detail(item)
                try Task.checkCancellation()
                guard epoch.accepts(captured), selectionEpoch.accepts(selection), phase == .open else { return }
                detail = value
            } catch { if !Task.isCancelled && epoch.accepts(captured) { self.error = error.localizedDescription } }
        }
    }
    func create(draft: LoginDraft, note: String?, vaultID: String) {
        guard let vault = vaults.first(where: { $0.id == vaultID }) else { return }
        perform { [self] in
            if isDemo {
                selectedVault = vault.id; kind = nil; query = ""
                let item = PassItem(itemID: UUID().uuidString, shareID: vault.id, title: draft.title, kind: note == nil ? "login" : "note")
                items.append(item)
                demoDetails[item.id] = ItemDetail(title: draft.title, note: note ?? "", fields: note == nil ?
                    [SecretField(label: "Username", value: draft.username, concealed: false), SecretField(label: "Password", value: draft.password)] : [], urls: draft.urls)
                selectedItem = item.id; selectItem()
            } else {
                if let note { try await service.createNote(title: draft.title, note: note, vault: vault) }
                else { try await service.createLogin(draft, vault: vault) }
                try Task.checkCancellation()
                selectedVault = vault.id; kind = nil; query = ""
                try await loadSnapshot()
            }
        }
    }
    func updateCurrent(fields: [String: String]) {
        guard let item = currentItem else { return }
        perform { [self] in
            if isDemo {
                let old = demoDetails[item.id]
                let title = fields["title"] ?? item.title
                items = items.map { $0.id == item.id ? PassItem(itemID: $0.itemID, shareID: $0.shareID, title: title, kind: $0.kind) : $0 }
                demoDetails[item.id] = ItemDetail(title: title, note: fields["note"] ?? old?.note ?? "", fields: old?.fields.map {
                    SecretField(label: $0.label, value: fields[$0.label.lowercased()] ?? $0.value, concealed: $0.concealed)
                } ?? [], urls: old?.urls ?? [])
            } else { try await service.update(item, fields: fields); try await loadSnapshot() }
            selectItem()
        }
    }
    func trashCurrent() {
        guard let item = currentItem else { return }
        perform { [self] in
            if isDemo { items.removeAll { $0.id == item.id }; demoDetails.removeValue(forKey: item.id) }
            else { try await service.trash(item, restore: showingTrash); try await loadSnapshot() }
            selectedItem = nil; detail = nil
        }
    }
    func copyTOTP() {
        guard canCopyTOTP else { error = "Verification code access is limited for this account."; return }
        guard let item = currentItem else { return }
        perform { [self] in
            let code = isDemo ? "123456" : try await service.totp(item)
            try Task.checkCancellation()
            guard phase == .open else { return }
            ClipboardController.shared.copy(code)
        }
    }
    func signOut() {
        guard !busy else { return }
        if isDemo { lock(); isDemo = false; phase = hasSession ? .locked : .welcome; return }
        // Clear visible data immediately; preserve credentials if remote logout fails so users can retry.
        lock()
        perform { [self] in try await service.logout(); phase = .welcome }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        error = nil; busy = true
        let captured = epoch.value
        operation = Task {
            do { try await action() }
            catch { if !Task.isCancelled && epoch.accepts(captured) { self.error = error.localizedDescription } }
            if epoch.accepts(captured) { busy = false }
        }
    }
    func enterDemo() {
        lock(); isDemo = true; phase = .open; showingTrash = false
        vaults = [Vault(name: "Personal", vaultID: "demo-personal", shareID: "demo-personal"),
                  Vault(name: "Work", vaultID: "demo-work", shareID: "demo-work")]
        let examples: [(String, String, String, String, String)] = [
            ("GitHub", "login", "demo-work", "developer@example.com", "Synthetic-Passphrase-42!"),
            ("Proton", "login", "demo-personal", "alex@example.com", "Demo-Only-Password-73!"),
            ("Travel notes", "note", "demo-personal", "", ""),
            ("Home Wi-Fi", "wifi", "demo-personal", "ProtonX Demo Network", "Demo-Wifi-Not-A-Secret")]
        items = examples.enumerated().map { index, value in
            let item = PassItem(itemID: String(index), shareID: value.2, title: value.0, kind: value.1)
            demoDetails[item.id] = ItemDetail(title: value.0, note: value.1 == "note" ? "A synthetic note for exploring the native experience. No Proton account is connected." : "", fields:
                value.1 == "note" ? [] : [SecretField(label: value.1 == "wifi" ? "Network" : "Username", value: value.3, concealed: false), SecretField(label: "Password", value: value.4)],
                urls: value.1 == "login" ? ["https://example.com"] : [], hasTOTP: value.0 == "Proton")
            return item
        }
        selectedItem = items.first?.id; selectItem()
    }
}
