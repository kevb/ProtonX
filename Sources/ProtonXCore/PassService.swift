import Foundation

public struct AuthChallenge: Codable, Equatable, Sendable {
    public let prompt: String
    public let secure: Bool
    public init(prompt: String, secure: Bool) { self.prompt = prompt; self.secure = secure }
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
    public init(runner: any HelperRunning) { self.runner = runner }
    public func cancel() { runner.cancelAll() }
    private func execute(_ command: HelperCommand, challenge: ChallengeHandler? = nil) async throws -> Data {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let data = try await runner.run(command, challenge: challenge)
            await gate.release()
            return data
        } catch { await gate.release(); throw error }
    }
    public func login(challenge: @escaping ChallengeHandler) async throws {
        _ = try await execute(HelperCommand(["login", "--interactive"]), challenge: challenge)
    }
    public func logout() async throws { _ = try await execute(HelperCommand(["logout"])) }
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
        let data = try await execute(HelperCommand(["item", "view", "pass://" + item.shareID + "/" + item.itemID + "/totp"] ))
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (6...8).contains(text.count), text.allSatisfy(\.isNumber) else { throw ProtonXError.invalidResponse }
        return text
    }
}
