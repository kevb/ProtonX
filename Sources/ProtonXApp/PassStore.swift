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
    @Published private(set) var savedVaultGeneration: String?
    @Published private(set) var offlineCacheStatus: String?
    private var savedVaultExpiresAt: Date?
    private var savedVaultSavedAt: Date?
    private var cacheExpiryTask: Task<Void, Never>?
    private let now: @MainActor @Sendable () -> Date
    var isUsingSavedVault: Bool { savedVaultGeneration != nil }
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
    private let localUnlock: (@MainActor @Sendable () async throws -> Bool)?
    private var requiresSignIn = false
    private let webAuthentication = NativeWebAuthentication()
    var filteredItems: [PassItem] { ItemSearch.filter(showingTrash ? trashedItems : items, query: query, vaultID: selectedVault, kind: kind, sort: sort) }
    var isLoadingInitialSnapshot: Bool { phase == .open && !isDemo && busy && lastSyncedAt == nil }
    var initialSnapshotFailed: Bool { phase == .open && !isDemo && !busy && lastSyncedAt == nil && error != nil }
    var currentItem: PassItem? {
        guard let selectedItem, let item = (showingTrash ? trashedItems : items).first(where: { $0.id == selectedItem }),
              ItemSearch.matches(item, query: query, vaultID: selectedVault, kind: kind) else { return nil }
        return item
    }
    var writableVaults: [Vault] { vaults.filter { $0.canCreate == true } }
    var canCreate: Bool { !isUsingSavedVault && !mustRefreshBeforeWriting && phase == .open && !busy && !showingTrash && !writableVaults.isEmpty }
    var canEdit: Bool { !isUsingSavedVault && phase == .open && !busy && !mustRefreshBeforeWriting && !showingTrash && currentItem.map { ["login", "note"].contains($0.kind) } == true && currentVault?.canUpdate == true && (isDemo || detail?.revision != nil) }
    var currentVault: Vault? { guard let item = currentItem else { return nil }; return vaults.first { $0.id == item.shareID } }
    var canTrash: Bool { !isUsingSavedVault && phase == .open && !busy && !mustRefreshBeforeWriting && currentVault?.canTrash == true }
    var customFieldsAllowed: Bool { capabilities?.customFieldsAllowed == true }
    func canSetupTOTP(for item: PassItem?) -> Bool { capabilities?.allowsTOTPSetup(itemID: item?.id, items: items) == true }
    private func reconcileSelection() {
        if selectedItem != nil && currentItem == nil { self.selectedItem = nil }
    }
    var canCopyTOTP: Bool {
        guard phase == .open, !busy else { return false }
        if isDemo { return !showingTrash }
        guard !isUsingSavedVault, !mustRefreshBeforeWriting, !showingTrash, let selectedItem, let capabilities else { return false }
        return capabilities.allowsTOTP(itemID: selectedItem, items: items)
    }
    var hasSession: Bool { !previewOnly && FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(".session/session.json").path) }

    init(service: PassService? = nil, sessionDirectory: URL? = nil, previewOnly: Bool = Bundle.main.bundleIdentifier == "org.kevb.ProtonX.Preview", localUnlock: (@MainActor @Sendable () async throws -> Bool)? = nil, now: @escaping @MainActor @Sendable () -> Date = { Date() }) {
        self.previewOnly = previewOnly
        self.localUnlock = localUnlock
        self.now = now
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
        let captured = epoch.value
        perform { [self] in
            defer { if epoch.accepts(captured) { webAuthentication.cancel() } }
            try await service.login(interactive: interactive) { [weak self] prompt in
                guard let self else { throw ProtonXError.cancelled }
                if let url = prompt.url { return try await self.beginWebAuthentication(url, captured: captured) }
                return try await self.requestCredential(prompt, captured: captured)
            }
            try check(captured)
            requiresSignIn = false
            phase = .open
            try await loadSnapshot()
        }
    }
    private func beginWebAuthentication(_ value: String, captured: UInt64) throws -> String {
        try check(captured)
        guard let url = URLPolicy.authenticationURL(value) else { throw ProtonXError.invalidResponse }
        try webAuthentication.start(url: url) { [weak self] in self?.cancelLogin() }
        return "started"
    }
    private func requestCredential(_ prompt: AuthChallenge, captured: UInt64) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try check(captured)
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
    func cancelLogin() { lock() }
    func unlock() {
        guard !busy, !previewOnly, phase == .locked else { return }
        if isDemo { enterDemo(); return }
        guard !requiresSignIn else { return }
        let context = LAContext(); authContext = context
        let captured = epoch.value
        perform { [self] in
            let success: Bool
            if let localUnlock { success = try await localUnlock() }
            else { success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock ProtonX on this Mac") }
            guard success else { throw ProtonXError.cancelled }
            try check(captured)
            phase = .open
            do {
                if let saved = try await service.savedSnapshot(), saved.usable(at: now()) {
                    try check(captured)
                    applySnapshot(saved.snapshot)
                    lastSyncedAt = saved.savedAt; savedVaultGeneration = saved.generation
                    savedVaultExpiresAt = saved.expiresAt; savedVaultSavedAt = saved.savedAt
                    mustRefreshBeforeWriting = true
                    scheduleCacheExpiry(saved)
                }
            } catch {
                try check(captured)
                if handleSessionFailure(error, captured: captured) { return }
                // Cache failure never resets keys or deletes the profile. Try online.
            }
            try check(captured)
            try await refreshSnapshot()
            try check(captured)
            selectItem()
        }
    }
    func lock() {
        epoch.invalidate(); selectionEpoch.invalidate()
        authContext?.invalidate(); authContext = nil
        webAuthentication.cancel()
        operation?.cancel(); selectionTask?.cancel(); service.cancel()
        cacheExpiryTask?.cancel(); cacheExpiryTask = nil
        savedVaultGeneration = nil; savedVaultExpiresAt = nil; savedVaultSavedAt = nil; offlineCacheStatus = nil
        let continuation = credentialContinuation; credentialContinuation = nil; credentialRequestID = nil; challenge = nil
        continuation?.resume(throwing: ProtonXError.cancelled)
        ClipboardController.shared.clearOwned()
        vaults = []; items = []; trashedItems = []; lastSyncedAt = nil; mustRefreshBeforeWriting = false; detail = nil; demoDetails = [:]; capabilities = nil
        selectedItem = nil; selectedVault = nil; query = ""; busy = false; error = nil
        phase = isDemo || (!requiresSignIn && hasSession) ? .locked : .welcome
    }
    func refresh() {
        guard phase == .open else { return }
        perform { [self] in
            try await refreshSnapshot()
            selectItem()
        }
    }
    private func refreshSnapshot() async throws {
        do { try await loadSnapshot() }
        catch {
            if isUsingSavedVault {
                let permitsSavedRead: Bool
                if case ProtonXError.helperDiagnostic(let diagnostic) = error { permitsSavedRead = diagnostic.failure == .network }
                else { permitsSavedRead = (error as? ProtonXError) == .timeout }
                if !permitsSavedRead || !savedVaultUsable() { discardSavedVault() }
            }
            if case ProtonXError.helperDiagnostic(let diagnostic) = error, diagnostic.failure == .sessionInvalidated { throw error }
            if phase == .open && lastSyncedAt != nil {
                mustRefreshBeforeWriting = true
                self.error = isUsingSavedVault ? "Could not connect. Browsing your saved vault; changes require an online refresh." :
                    "Could not refresh. Showing the last loaded vault; refresh successfully before saving changes. " + error.localizedDescription
            } else { throw error }
        }
    }
    private func applySnapshot(_ snapshot: PassSnapshot) {
        capabilities = snapshot.capabilities; vaults = snapshot.vaults; items = snapshot.items; trashedItems = snapshot.trashedItems
        if let selectedVault, !vaults.contains(where: { $0.id == selectedVault }) { self.selectedVault = nil }
        reconcileSelection()
    }
    private func savedVaultUsable() -> Bool {
        guard let expires = savedVaultExpiresAt, let saved = savedVaultSavedAt else { return false }
        return now() >= saved && now() < expires
    }
    private func scheduleCacheExpiry(_ saved: SavedPassSnapshot) {
        cacheExpiryTask?.cancel()
        let remaining = max(0, saved.expiresAt.timeIntervalSince(now()))
        cacheExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !Task.isCancelled, savedVaultGeneration == saved.generation else { return }
            discardSavedVault()
            error = "Your saved vault has expired. Refresh online to continue."
        }
    }
    private func discardSavedVault() {
        cacheExpiryTask?.cancel(); cacheExpiryTask = nil
        savedVaultGeneration = nil; savedVaultExpiresAt = nil; savedVaultSavedAt = nil
        selectionEpoch.invalidate(); selectionTask?.cancel()
        vaults = []; items = []; trashedItems = []; capabilities = nil; detail = nil; lastSyncedAt = nil
        selectedItem = nil; selectedVault = nil; mustRefreshBeforeWriting = true
        ClipboardController.shared.clearOwned()
    }
    func canUseVisibleDetail() -> Bool {
        guard phase == .open else { return false }
        if isUsingSavedVault && !savedVaultUsable() {
            discardSavedVault(); error = "Your saved vault has expired. Refresh online to continue."
            return false
        }
        return true
    }
    private func loadSnapshot() async throws {
        guard !isDemo else { return }
        let captured = epoch.value
        let snapshot = try await service.snapshot()
        try Task.checkCancellation()
        guard epoch.accepts(captured), phase == .open else { return }
        applySnapshot(snapshot)
        cacheExpiryTask?.cancel(); cacheExpiryTask = nil
        savedVaultGeneration = nil; savedVaultExpiresAt = nil; savedVaultSavedAt = nil
        offlineCacheStatus = snapshot.cacheStatus
        lastSyncedAt = now(); mustRefreshBeforeWriting = false
    }
    func selectItem() {
        selectionEpoch.invalidate(); selectionTask?.cancel(); detail = nil
        // Navigation must not dismiss a write/sync warning that still blocks saving.
        if !mustRefreshBeforeWriting { error = nil }
        guard canUseVisibleDetail(), let item = currentItem else { return }
        if isDemo { detail = demoDetails[item.id]; return }
        let captured = epoch.value, selection = selectionEpoch.value
        let generation = savedVaultGeneration
        selectionTask = Task {
            do {
                let value: ItemDetail
                if let generation { value = try await service.savedDetail(item, generation: generation) }
                else { value = try await service.detail(item) }
                try Task.checkCancellation()
                guard epoch.accepts(captured), selectionEpoch.accepts(selection), phase == .open else { return }
                guard generation == savedVaultGeneration, canUseVisibleDetail() else { return }
                detail = value
            } catch {
                if !Task.isCancelled && epoch.accepts(captured) && selectionEpoch.accepts(selection) {
                    guard generation == savedVaultGeneration else { return }
                    if !handleSessionFailure(error, captured: captured) {
                        if generation != nil { discardSavedVault() }
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }
    /// Returns only after the write is acknowledged. A later refresh failure must not invite duplicate creation.
    func save(_ draft: NativeItemDraft, item: PassItem?, vaultID: String) async throws {
        guard !isUsingSavedVault, !mustRefreshBeforeWriting, !busy, phase == .open, let vault = vaults.first(where: { $0.id == vaultID }),
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
                if !handleSessionFailure(error, captured: captured), epoch.accepts(captured), phase == .open { mustRefreshBeforeWriting = true }
                throw error
            }
            // A committed write and a successful refresh are distinct outcomes.
            guard epoch.accepts(captured), phase == .open else { return }
            do { try await loadSnapshot() }
            catch {
                guard epoch.accepts(captured), phase == .open else { return }
                if handleSessionFailure(error, captured: captured, acknowledgement: "Item saved.") { return }
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
        let captured = epoch.value
        perform { [self] in
            if isDemo {
                if restore { trashedItems.removeAll { $0.id == item.id }; items.append(item) }
                else { items.removeAll { $0.id == item.id }; trashedItems.append(item) }
                lastSyncedAt = Date()
            } else {
                do { try await service.trash(item, restore: restore) }
                catch {
                    if !handleSessionFailure(error, captured: captured), epoch.accepts(captured), phase == .open {
                        mustRefreshBeforeWriting = true
                        self.error = "Could not confirm whether the item was \(restore ? "restored" : "moved to Trash"). Refresh your vault before trying again. " + error.localizedDescription
                    }
                    return
                }
                do { try await loadSnapshot() }
                catch {
                    guard epoch.accepts(captured), phase == .open else { return }
                    if handleSessionFailure(error, captured: captured, acknowledgement: "Item \(restore ? "restored" : "moved to Trash").") { return }
                    mustRefreshBeforeWriting = true
                    self.error = "Item \(restore ? "restored" : "moved to Trash"). Refresh failed; refresh to see the latest state."
                }
            }
            guard epoch.accepts(captured), phase == .open else { return }
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
        if isDemo { lock(); isDemo = false; phase = !requiresSignIn && hasSession ? .locked : .welcome; return }
        // Clear visible data immediately; preserve credentials if remote logout fails so users can retry.
        lock()
        perform { [self] in try await service.logout(); requiresSignIn = false; phase = .welcome }
    }
    private func check(_ captured: UInt64) throws {
        try Task.checkCancellation()
        guard epoch.accepts(captured) else { throw ProtonXError.cancelled }
    }
    /// Leave saved-session cleanup to the SDK; stop offering unlock for a rejected session.
    @discardableResult private func handleSessionFailure(_ error: Error, captured: UInt64, acknowledgement: String? = nil) -> Bool {
        guard epoch.accepts(captured), case ProtonXError.helperDiagnostic(let diagnostic) = error,
              diagnostic.failure == .sessionInvalidated else { return false }
        lock(); requiresSignIn = true; phase = .welcome
        self.error = [acknowledgement, diagnostic.message].compactMap { $0 }.joined(separator: " ")
        return true
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        error = nil; busy = true
        let captured = epoch.value
        operation = Task {
            do { try await action() }
            catch {
                if !Task.isCancelled && epoch.accepts(captured) {
                    if !handleSessionFailure(error, captured: captured) { self.error = error.localizedDescription }
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
