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
    @Published private(set) var trashedItems: [PassItem] = []
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var mustRefreshBeforeWriting = false
    @Published var sort: ItemSort = .title
    @Published var selectedVault: String? { didSet { reconcileSelection() } }
    @Published var selectedItem: String? { didSet { if oldValue != selectedItem { selectItem() } } }
    @Published var query = "" { didSet { reconcileSelection() } }
    @Published var kind: String? { didSet { reconcileSelection() } }
    @Published var showingTrash = false { didSet { reconcileSelection() } }
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
    private(set) var capabilities: PassCapabilities?
    let previewOnly: Bool
    private var demoDetails: [String: ItemDetail] = [:]
    let service: PassService
    let sessionDirectory: URL
    private var authContext: LAContext?
    private let webAuthentication = NativeWebAuthentication()
    var filteredItems: [PassItem] { ItemSearch.filter(showingTrash ? trashedItems : items, query: query, vaultID: selectedVault, kind: kind, sort: sort) }
    var currentItem: PassItem? {
        guard let selectedItem, let item = (showingTrash ? trashedItems : items).first(where: { $0.id == selectedItem }),
              ItemSearch.matches(item, query: query, vaultID: selectedVault, kind: kind) else { return nil }
        return item
    }
    var writableVaults: [Vault] { vaults.filter { $0.canCreate == true } }
    var canCreate: Bool { !mustRefreshBeforeWriting && phase == .open && !busy && !showingTrash && !writableVaults.isEmpty }
    var canEdit: Bool { !mustRefreshBeforeWriting && !showingTrash && currentItem.map { ["login", "note"].contains($0.kind) } == true && currentVault?.canUpdate == true && (isDemo || detail?.revision != nil) }
    var currentVault: Vault? { guard let item = currentItem else { return nil }; return vaults.first { $0.id == item.shareID } }
    var canTrash: Bool { !mustRefreshBeforeWriting && currentVault?.canTrash == true }
    var customFieldsAllowed: Bool { capabilities?.customFieldsAllowed == true }
    func canSetupTOTP(for item: PassItem?) -> Bool { capabilities?.allowsTOTPSetup(itemID: item?.id, items: items) == true }
    private func reconcileSelection() {
        if selectedItem != nil && currentItem == nil { self.selectedItem = nil }
    }
    var canCopyTOTP: Bool {
        if isDemo { return !showingTrash }
        guard !mustRefreshBeforeWriting, !showingTrash, let selectedItem, let capabilities else { return false }
        return capabilities.allowsTOTP(itemID: selectedItem, items: items)
    }
    var hasSession: Bool { !previewOnly && FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(".session/session.json").path) }

    init(service: PassService? = nil, sessionDirectory: URL? = nil, previewOnly: Bool = Bundle.main.bundleIdentifier == "org.kevb.ProtonX.Preview") {
        self.previewOnly = previewOnly
        self.sessionDirectory = sessionDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(previewOnly ? "Library/Application Support/ProtonX/Preview" : "Library/Application Support/ProtonX/Pass", isDirectory: true)
        let helper = Bundle.main.url(forAuxiliaryExecutable: "protonx-pass") ??
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/protonx-pass")
        self.service = service ?? PassService(runner: NativeProcess(executable: helper, directory: self.sessionDirectory))
        phase = hasSession ? .locked : .welcome
    }
    func login(interactive: Bool = false) {
        guard !busy, !previewOnly else { return }
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
        vaults = []; items = []; trashedItems = []; lastSyncedAt = nil; mustRefreshBeforeWriting = false; detail = nil; demoDetails = [:]; capabilities = nil
        selectedItem = nil; selectedVault = nil; query = ""; busy = false; error = nil
        phase = hasSession || isDemo ? .locked : .welcome
    }
    func refresh() {
        perform { [self] in
            do { try await loadSnapshot(); selectItem() }
            catch {
                if case ProtonXError.helperDiagnostic(let diagnostic) = error, diagnostic.failure == .sessionInvalidated { throw error }
                if phase == .open && lastSyncedAt != nil {
                    mustRefreshBeforeWriting = true
                    self.error = "Could not refresh. Showing the last loaded vault; refresh successfully before saving changes. " + error.localizedDescription
                } else { throw error }
            }
        }
    }
    private func loadSnapshot() async throws {
        guard !isDemo else { return }
        let captured = epoch.value
        let snapshot = try await service.snapshot()
        try Task.checkCancellation()
        guard epoch.accepts(captured), phase == .open else { return }
        capabilities = snapshot.capabilities; vaults = snapshot.vaults; items = snapshot.items; trashedItems = snapshot.trashedItems
        lastSyncedAt = Date(); mustRefreshBeforeWriting = false
        if let selectedVault, !vaults.contains(where: { $0.id == selectedVault }) { self.selectedVault = nil }
        reconcileSelection()
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
            } catch { if !Task.isCancelled && epoch.accepts(captured) && selectionEpoch.accepts(selection) { self.error = error.localizedDescription } }
        }
    }
    /// Returns only after the write is acknowledged. A later refresh failure must not invite duplicate creation.
    func save(_ draft: NativeItemDraft, item: PassItem?, vaultID: String) async throws {
        guard !mustRefreshBeforeWriting, !busy, phase == .open, let vault = vaults.first(where: { $0.id == vaultID }),
              item == nil ? vault.canCreate == true : vault.canUpdate == true else {
            throw ProtonXError.invalidInput("This vault is unavailable for saving items.")
        }
        _ = try draft.encodedInput()
        guard !showingTrash else { throw ProtonXError.invalidInput("Restore the item before editing.") }
        let captured = epoch.value
        busy = true; error = nil
        defer { if epoch.accepts(captured) { busy = false } }
        var savedID: String
        if isDemo {
            let id = item?.itemID ?? UUID().uuidString
            let old = item.flatMap { demoDetails[$0.id] }
            var extras = old?.editableCustomFields ?? []
            for field in draft.customFields where field.sourceIndex != nil {
                if let index = extras.firstIndex(where: { $0.sourceIndex == field.sourceIndex }) {
                    if field.removed { extras.remove(at: index) } else { extras[index] = field }
                }
            }
            extras += draft.customFields.filter { $0.sourceIndex == nil && !$0.removed }
            extras = extras.enumerated().map { CustomFieldDraft(sourceIndex: $0.offset, name: $0.element.name, value: $0.element.value, concealed: $0.element.concealed) }
            let next = PassItem(itemID: id, shareID: vault.id, title: draft.title, kind: draft.kind,
                                hasTOTP: draft.totpURI.map { !$0.isEmpty } ?? old?.hasTOTP ?? false,
                                createdAt: item?.createdAt ?? ISO8601DateFormatter().string(from: Date()), modifiedAt: ISO8601DateFormatter().string(from: Date()))
            items.removeAll { $0.id == next.id }; items.append(next)
            let fields = draft.kind == "login" ? [("Email", draft.email ?? "", false), ("Username", draft.username ?? "", false), ("Password", draft.password ?? "", true)].filter { !$0.1.isEmpty }.map { SecretField(label: $0.0, value: $0.1, concealed: $0.2) } : []
            demoDetails[next.id] = ItemDetail(title: draft.title, note: draft.note,
                fields: fields + extras.map { SecretField(label: "Custom: " + $0.name, value: $0.value, concealed: $0.concealed) },
                revision: (old?.revision ?? 0) + 1, urls: draft.urls ?? old?.urls ?? [], hasTOTP: next.hasTOTP == true,
                editableCustomFields: extras, unsupportedCustomFieldCount: old?.unsupportedCustomFieldCount ?? 0)
            savedID = next.id; lastSyncedAt = Date()
        } else {
            do {
                if let item { try await service.edit(draft, item: item, vault: vault); savedID = item.id }
                else { savedID = vault.id + ":" + (try await service.create(draft, vault: vault)) }
            } catch {
                if epoch.accepts(captured), phase == .open { mustRefreshBeforeWriting = true }
                throw error
            }
            // A committed write and a successful refresh are distinct outcomes.
            guard epoch.accepts(captured), phase == .open else { return }
            do { try await loadSnapshot() }
            catch {
                guard epoch.accepts(captured), phase == .open else { return }
                mustRefreshBeforeWriting = true
                self.error = "Item saved. Refresh failed; refresh your vault before making further changes."
                selectedItem = nil
                return
            }
        }
        guard epoch.accepts(captured), phase == .open else { return }
        selectedVault = vault.id; kind = nil; query = ""; showingTrash = false
        selectedItem = savedID; selectItem()
    }
    func trashCurrent() {
        guard !busy, canTrash, let item = currentItem else { return }
        let restore = showingTrash
        perform { [self] in
            if isDemo {
                if restore { trashedItems.removeAll { $0.id == item.id }; items.append(item) }
                else { items.removeAll { $0.id == item.id }; trashedItems.append(item) }
                lastSyncedAt = Date()
            } else {
                try await service.trash(item, restore: restore)
                do { try await loadSnapshot() }
                catch { if phase == .open { mustRefreshBeforeWriting = true; self.error = "Item \(restore ? "restored" : "moved to Trash"). Refresh failed; refresh to see the latest state." } }
            }
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
            catch {
                if !Task.isCancelled && epoch.accepts(captured) {
                    if case ProtonXError.helperDiagnostic(let diagnostic) = error, diagnostic.failure == .sessionInvalidated {
                        lock(); self.error = diagnostic.message
                    } else { self.error = error.localizedDescription }
                }
            }
            if epoch.accepts(captured) { busy = false }
        }
    }
    func enterDemo() {
        lock(); isDemo = true; phase = .open; showingTrash = false
        vaults = [Vault(name: "Personal", vaultID: "demo-personal", shareID: "demo-personal", canCreate: true, canUpdate: true, canTrash: true),
                  Vault(name: "Work", vaultID: "demo-work", shareID: "demo-work", canCreate: true, canUpdate: true, canTrash: true)]
        let examples: [(String, String, String, String, String)] = [
            ("GitHub", "login", "demo-work", "developer@example.com", "Synthetic-Passphrase-42!"),
            ("Proton", "login", "demo-personal", "alex@example.com", "Demo-Only-Password-73!"),
            ("Travel notes", "note", "demo-personal", "", ""),
            ("Home Wi-Fi", "wifi", "demo-personal", "ProtonX Demo Network", "Demo-Wifi-Not-A-Secret")]
        capabilities = PassCapabilities(totpLimit: nil, customFieldsAllowed: true)
        items = examples.enumerated().map { index, value in
            let item = PassItem(itemID: String(index), shareID: value.2, title: value.0, kind: value.1, hasTOTP: value.0 == "Proton", createdAt: "2026-09-30T10:00:00", modifiedAt: "2026-10-05T12:00:00")
            demoDetails[item.id] = ItemDetail(title: value.0, note: value.1 == "note" ? "A synthetic note for exploring the native experience. No Proton account is connected." : "", fields:
                value.1 == "note" ? [] : [SecretField(label: value.1 == "wifi" ? "Network" : "Username", value: value.3, concealed: false), SecretField(label: "Password", value: value.4)],
                urls: value.1 == "login" ? ["https://example.com"] : [], hasTOTP: value.0 == "Proton")
            return item
        }
        lastSyncedAt = Date(); selectedItem = items.first?.id; selectItem()
    }
}
