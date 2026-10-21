import Foundation
import Testing
@testable import ProtonXCore

private final class AliasRunner: HelperRunning, @unchecked Sendable {
    let lock = NSLock()
    private var calls: [HelperCommand] = []
    func cancelAll() {}
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data {
        lock.withLock { calls.append(command) }
        if command.arguments.first == "native-alias-options" { return Data(#"{"suffixes":[{"suffix":".demo@example.invalid","signed_suffix":"SYNTHETIC-signed-capability"}],"mailboxes":[{"id":42,"email":"alex@example.invalid"}]}"#.utf8) }
        return Data(#"{"item_id":"created-synthetic","alias":"shop.demo@example.invalid"}"#.utf8)
    }
    var commands: [HelperCommand] { lock.withLock { calls } }
}
@Test func aliasCreationUsesPrivateInputAndExactPreviewCapability() async throws {
    let runner = AliasRunner(), service = PassService(runner: runner)
    let vault = Vault(name: "Personal", vaultID: "v", shareID: "s", canCreate: true)
    let options = try await service.aliasOptions(vault: vault)
    let draft = PassAliasDraft(title: "Synthetic shop", note: "SYNTHETIC-$()\nprivate note", prefix: "shop", suffix: options.suffixes[0], mailbox: options.mailboxes[0])
    let result = try await service.createAlias(draft, vault: vault)
    #expect(result.alias == draft.email)
    #expect(runner.commands.count == 2)
    let command = try #require(runner.commands.last)
    #expect(command.arguments == ["native-alias-create", "--share-id", "s"])
    #expect(!command.arguments.joined().contains(draft.title)); #expect(!command.arguments.joined().contains(draft.signedSuffix))
    let input = try JSONDecoder().decode(PassAliasDraft.self, from: #require(command.input))
    #expect(input.signedSuffix == draft.signedSuffix && input.note == draft.note && input.mailboxID == 42)
}
@Test func aliasValidationRejectsBadPrefixesCapabilitiesAndReadOnlyVaults() async throws {
    let runner = AliasRunner(), service = PassService(runner: runner)
    let vault = Vault(name: "Read only", vaultID: "v", shareID: "s")
    let suffix = PassAliasOptions.Suffix(suffix: ".demo@example.invalid", signedSuffix: "synthetic")
    let mailbox = PassAliasOptions.Mailbox(id: 1, email: "alex@example.invalid")
    var draft = PassAliasDraft(title: "Synthetic", prefix: "shop", suffix: suffix, mailbox: mailbox)
    await #expect(throws: ProtonXError.self) { try await service.aliasOptions(vault: vault) }
    await #expect(throws: ProtonXError.self) { try await service.createAlias(draft, vault: vault) }
    for bad in ["", "A", "two..dots", ".bad", "bad.", "space here", String(repeating: "a", count: 41)] {
        draft.prefix = bad; #expect(throws: ProtonXError.self) { try draft.encodedInput() }
    }
    draft.prefix = "shop"; draft.note = String(repeating: "a", count: 16385)
    #expect(throws: ProtonXError.self) { try draft.encodedInput() }
    #expect(runner.commands.isEmpty)
    for suffix in ["@", "@@example.invalid", "\n@example.invalid", "example.invalid"] {
        let options = PassAliasOptions(suffixes: [.init(suffix: suffix, signedSuffix: "synthetic")], mailboxes: [mailbox])
        #expect(throws: ProtonXError.self) { try options.validate() }
    }
    #expect(PassAliasDraft.suggestedPrefix("Café / Shopping!") == "cafe-shopping")
    #expect(PassAliasDraft.validPrefix(PassAliasDraft.suggestedPrefix("💌")))
}
