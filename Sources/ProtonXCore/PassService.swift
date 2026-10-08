import Foundation

public struct AuthChallenge: Codable, Equatable, Sendable {
    public let prompt: String
    public let secure: Bool
    public let url: String?
    public init(prompt: String, secure: Bool, url: String? = nil) { self.prompt = prompt; self.secure = secure; self.url = url }
    public var title: String {
        if prompt.localizedCaseInsensitiveContains("TOTP") { return "Verification code" }
        if prompt.contains("second password") { return "Mailbox password" }
        if prompt.contains("extra password") { return "Pass extra password" }
        if prompt.localizedCaseInsensitiveContains("username") { return "Proton username" }
        return "Proton password"
    }
}
public typealias ChallengeHandler = @Sendable (AuthChallenge) async throws -> String

public struct HelperCommand: Sendable, Equatable {
    public let arguments: [String]
    public let input: Data?
    public init(_ arguments: [String], input: Data? = nil) { self.arguments = arguments; self.input = input }
}
public protocol HelperRunning: Sendable {
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data
    func cancelAll()
}

/// One helper command at a time: avoids concurrent session refreshes and SQLCipher writers.
actor CommandGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if occupied { await withCheckedContinuation { waiters.append($0) } } else { occupied = true }
    }
    func release() { if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() } }
}

public final class PassService: Sendable {
    private let runner: any HelperRunning
    private let gate = CommandGate()
    private let cacheGate = CommandGate()
    public init(runner: any HelperRunning) { self.runner = runner }
    public func cancel() { runner.cancelAll() }
    private func execute(_ command: HelperCommand, challenge: ChallengeHandler? = nil) async throws -> Data {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let data = try await runner.run(command, challenge: challenge)
            try Task.checkCancellation()
            await gate.release()
            return data
        } catch { await gate.release(); throw error }
    }
    public func login(interactive: Bool = true, challenge: @escaping ChallengeHandler) async throws {
        _ = try await execute(HelperCommand(interactive ? ["login", "--interactive"] : ["login"]), challenge: challenge)
    }
    public func calendarHandoff() async throws -> AccountHandoff {
        let result = try JSONDecoder().decode(AccountHandoff.self, from: await execute(HelperCommand(["native-calendar-handoff"])))
        try result.validate(); return result
    }
    public func logout() async throws { _ = try await execute(HelperCommand(["logout"])) }
    public func snapshot() async throws -> PassSnapshot {
        try JSONDecoder().decode(PassSnapshot.self, from: await execute(HelperCommand(["native-snapshot"])))
    }
    // Independent local read gate: a slow network refresh must not block browsing
    // saved items. SQLCipher transactions serialize publication in the helper.
    private func executeCache(_ command: HelperCommand) async throws -> Data {
        await cacheGate.acquire()
        do {
            try Task.checkCancellation()
            let data = try await runner.run(command, challenge: nil)
            try Task.checkCancellation()
            await cacheGate.release()
            return data
        } catch { await cacheGate.release(); throw error }
    }
    public func savedSnapshot() async throws -> SavedPassSnapshot? {
        try JSONDecoder().decode(SavedPassSnapshot?.self, from: await executeCache(HelperCommand(["native-cache-snapshot"])))
    }
    public func savedDetail(_ item: PassItem, generation: String) async throws -> ItemDetail {
        guard UUID(uuidString: generation) != nil else { throw ProtonXError.invalidInput("Refresh your saved vault.") }
        return try ItemDetail.decode(await executeCache(HelperCommand(["native-cache-detail", "--generation", generation,
            "--share-id", item.shareID, "--item-id", item.itemID])))
    }
    public func create(_ draft: NativeItemDraft, vault: Vault) async throws -> String {
        guard vault.canCreate == true else { throw ProtonXError.invalidInput("This vault is read-only for creating items.") }
        struct Result: Decodable { let item_id: String }
        let result = try JSONDecoder().decode(Result.self, from: await execute(HelperCommand(["native-create", "--share-id", vault.shareID], input: draft.encodedInput())))
        guard !result.item_id.isEmpty else { throw ProtonXError.invalidResponse }
        return result.item_id
    }
    public func edit(_ draft: NativeItemDraft, item: PassItem, vault: Vault) async throws {
        guard vault.id == item.shareID, vault.canUpdate == true else { throw ProtonXError.invalidInput("This vault is read-only for editing items.") }
        guard draft.expectedRevision != nil else { throw ProtonXError.invalidInput("Reopen the item before editing to load its current revision.") }
        struct Result: Decodable { let updated: Bool }
        let result = try JSONDecoder().decode(Result.self, from: await execute(HelperCommand(["native-edit", "--share-id", item.shareID, "--item-id", item.itemID], input: draft.encodedInput())))
        guard result.updated else { throw ProtonXError.invalidResponse }
    }
    public func capabilities() async throws -> PassCapabilities {
        try JSONDecoder().decode(PassCapabilities.self, from: await execute(HelperCommand(["native-capabilities"])))
    }
    public func vaults() async throws -> [Vault] {
        struct List: Decodable { let vaults: [Vault] }
        return try JSONDecoder().decode(List.self, from: await execute(HelperCommand(["vault", "list", "--output", "json"]))).vaults
    }
    public func items(in vault: Vault, trashed: Bool = false) async throws -> [PassItem] {
        struct List: Decodable { let items: [PassItem] }
        return try JSONDecoder().decode(List.self, from: await execute(HelperCommand([
            "item", "list", "--share-id", vault.shareID, "--filter-state", trashed ? "trashed" : "active", "--output", "json"]))).items
    }
    public func detail(_ item: PassItem) async throws -> ItemDetail {
        try ItemDetail.decode(await execute(HelperCommand(["item", "view", "--share-id", item.shareID, "--item-id", item.itemID, "--output", "json"])))
    }
    public func createLogin(_ draft: LoginDraft, vault: Vault) async throws {
        try draft.validate()
        _ = try await execute(HelperCommand(["item", "create", "login", "--share-id", vault.shareID, "--from-template", "-"], input: JSONEncoder().encode(draft)))
    }
    public func createNote(title: String, note: String, vault: Vault) async throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProtonXError.invalidInput("Give the note a title.") }
        _ = try await execute(HelperCommand(["item", "create", "note", "--share-id", vault.shareID, "--from-template", "-"],
                                          input: JSONSerialization.data(withJSONObject: ["title": title, "note": note])))
    }
    public func update(_ item: PassItem, fields: [String: String]) async throws {
        let values = fields.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
        _ = try await execute(HelperCommand(["item", "update", "--share-id", item.shareID, "--item-id", item.itemID, "--field", "@stdin"], input: JSONEncoder().encode(values)))
    }
    public func trash(_ item: PassItem, restore: Bool = false) async throws {
        _ = try await execute(HelperCommand(["item", restore ? "untrash" : "trash", "--share-id", item.shareID, "--item-id", item.itemID]))
    }
    public func totp(_ item: PassItem) async throws -> String {
        let data = try await execute(HelperCommand(["native-totp", "--share-id", item.shareID, "--item-id", item.itemID] ))
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (6...8).contains(text.count), text.allSatisfy(\.isNumber) else { throw ProtonXError.invalidResponse }
        return text
    }
}
