import Foundation
import Testing
@testable import ProtonXCore

private final class RecordingRunner: HelperRunning, @unchecked Sendable {
    let lock = NSLock()
    var commands: [HelperCommand] = []
    var response = Data()
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data {
        lock.withLock { commands.append(command); return response }
    }
    func cancelAll() {}
    func last() -> HelperCommand? { lock.withLock { commands.last } }
}

@Test func searchUsesAllTermsAndVault() {
    let items = [PassItem(itemID: "a", shareID: "one", title: "Café Work Login", kind: "login"), PassItem(itemID: "a", shareID: "two", title: "Work Note", kind: "note")]
    #expect(ItemSearch.filter(items, query: "cafe work", vaultID: "one").count == 1)
    #expect(ItemSearch.filter(items, query: "missing").isEmpty)
    #expect(items[0].id != items[1].id)
}
@Test func invalidURLsAreNotOpened() {
    for text in ["javascript:alert(1)", "file:///etc/passwd", "https://user:password@example.com", "https:", "protonx://lock"] { #expect(URLPolicy.webURL(text) == nil) }
    #expect(URLPolicy.webURL("https://example.com/path") != nil)
}
@Test func lockInvalidatesAllCapturedResults() {
    var epoch = SessionEpoch(); let capture = epoch.value
    #expect(epoch.accepts(capture)); epoch.invalidate(); #expect(!epoch.accepts(capture))
}
@Test func clipboardNeverClearsSomeoneElsesCopy() {
    let lease = ClipboardLease(changeCount: 42)
    #expect(lease.owns(currentChangeCount: 42)); #expect(!lease.owns(currentChangeCount: 43))
}
@Test func generatorUsesRequestedLengthAndRejectsUnsafeLength() throws {
    let first = try PasswordGenerator.generate(), second = try PasswordGenerator.generate()
    #expect(first.count == 24); #expect(first != second)
    #expect(throws: ProtonXError.self) { try PasswordGenerator.generate(length: 1) }
}
@Test func createNeverPlacesPasswordInArguments() async throws {
    let runner = RecordingRunner()
    let client = PassService(runner: runner)
    var draft = LoginDraft(); draft.title = "Synthetic login"; draft.password = "SYNTHETIC-secret-\"-$()"; draft.urls = ["https://example.com"]
    try await client.createLogin(draft, vault: Vault(name: "Personal", vaultID: "vault", shareID: "share"))
    let command = try #require(runner.last())
    #expect(command.arguments == ["item", "create", "login", "--share-id", "share", "--from-template", "-"])
    #expect(!command.arguments.joined().contains(draft.password))
    let decoded = try JSONDecoder().decode(LoginDraft.self, from: #require(command.input))
    #expect(decoded.password == draft.password)
}
@Test func updatesUseStdinAndPreserveEqualsAndNewlines() async throws {
    let runner = RecordingRunner(); let service = PassService(runner: runner)
    try await service.update(PassItem(itemID: "id", shareID: "share", title: "Test", kind: "login"), fields: ["password": "a=b\nc"])
    let command = try #require(runner.last())
    #expect(command.arguments.suffix(2) == ["--field", "@stdin"])
    #expect(try JSONDecoder().decode([String].self, from: #require(command.input)) == ["password=a=b\nc"])
}
@Test func summaryNeverRequestsBulkSecrets() async throws {
    let runner = RecordingRunner(); runner.response = Data(#"{"items":[{"id":"i","share_id":"s","title":"Synthetic","item_type":"login"}]}"#.utf8)
    let service = PassService(runner: runner)
    let items = try await service.items(in: Vault(name: "Personal", vaultID: "v", shareID: "s"))
    #expect(items.count == 1); #expect(runner.last()?.arguments.contains("--show-secrets") == false)
}
@Test func detailMatchesUpstreamSerdeContract() throws {
    let fixture = Bundle.module.url(forResource: "pass-detail", withExtension: "json", subdirectory: "Fixtures")!
    let detail = try ItemDetail.decode(Data(contentsOf: fixture))
    #expect(detail.title == "Synthetic login"); #expect(detail.hasTOTP)
    #expect(detail.fields.first { $0.label == "Password" }?.concealed == true)
    #expect(detail.fields.first { $0.label == "Custom: Recovery" }?.concealed == true)
    #expect(detail.urls == ["https://example.com"])
    #expect(throws: ProtonXError.self) { try ItemDetail.decode(Data("{}".utf8)) }
}
@Test func invalidDraftNeverRunsHelper() async throws {
    let runner = RecordingRunner(); let service = PassService(runner: runner)
    var draft = LoginDraft(); draft.title = "   "
    await #expect(throws: ProtonXError.self) { try await service.createLogin(draft, vault: Vault(name: "v", vaultID: "v", shareID: "v")) }
    #expect(runner.last() == nil)
}

@Test func newerAutofillURLsAndPasskeysRemainVisibleWithoutExposingKeyMaterial() throws {
    let data = Data(#"{"item":{"content":{"title":"Modern login","content":{"Login":{"urls":[],"autofill_urls":[{"url":"https://example.com","mode":"Default"}],"passkeys":[{"content":"SYNTHETIC-KEY-MATERIAL"}]}},"extra_fields":[]}},"attachments":[]}"#.utf8)
    let detail = try ItemDetail.decode(data)
    #expect(detail.urls == ["https://example.com"]); #expect(detail.passkeyCount == 1)
    #expect(detail.fields.allSatisfy { !$0.value.contains("SYNTHETIC-KEY-MATERIAL") })
}
@Test func aliasAndCardPINContractsAreSupported() throws {
    let alias = try ItemDetail.decode(Data(#"{"item":{"alias_email":"alias@example.com","content":{"title":"Alias","content":{"Alias":null}}},"attachments":[]}"#.utf8))
    #expect(alias.fields.first?.value == "alias@example.com")
    let card = try ItemDetail.decode(Data(#"{"item":{"content":{"title":"Synthetic card","content":{"CreditCard":{"pin":"1234","number":"4111111111111111"}}}},"attachments":[]}"#.utf8))
    #expect(card.fields.first { $0.label == "PIN" }?.concealed == true)
}
@Test func customSectionsAndIdentityFieldsDefaultToConcealed() throws {
    let identity = try ItemDetail.decode(Data(#"{"item":{"content":{"title":"Synthetic identity","content":{"Identity":{"passport_number":"DEMO1234","extra_sections":[{"section_name":"Recovery","section_fields":[{"name":"Code","content":{"Hidden":"DEMO-ONLY"}}]}]}}}},"attachments":[]}"#.utf8))
    #expect(identity.fields.first { $0.label == "Passport Number" }?.concealed == true)
    #expect(identity.fields.first { $0.label == "Recovery: Code" }?.value == "DEMO-ONLY")
}

@Test func limitedTOTPRanksOnlyConfiguredLoginsByCreationTime() {
    let first = PassItem(itemID: "first", shareID: "s", title: "Z", kind: "login", hasTOTP: true, createdAt: "2026-01-01T00:00:00")
    let second = PassItem(itemID: "second", shareID: "s", title: "A", kind: "login", hasTOTP: true, createdAt: "2026-01-02T00:00:00")
    let plain = PassItem(itemID: "plain", shareID: "s", title: "Plain", kind: "login", hasTOTP: false)
    let policy = PassCapabilities(totpLimit: 1)
    #expect(policy.allowsTOTP(itemID: first.id, items: [second, plain, first]))
    #expect(!policy.allowsTOTP(itemID: second.id, items: [second, plain, first]))
    #expect(!policy.allowsTOTP(itemID: plain.id, items: [second, plain, first]))
}
@Test func TOTPZeroAndUnlimitedHaveDistinctPolicies() {
    #expect(!PassCapabilities(totpLimit: 0).allowsTOTP(itemID: "s:i", items: []))
    #expect(PassCapabilities(totpLimit: nil).allowsTOTP(itemID: "s:i", items: []))
}
@Test func incompleteTOTPMetadataFailsClosedForLimitedPlans() {
    let legacy = PassItem(itemID: "i", shareID: "s", title: "Legacy", kind: "login")
    let missingTime = PassItem(itemID: "i", shareID: "s", title: "No date", kind: "login", hasTOTP: true)
    #expect(!PassCapabilities(totpLimit: 3).allowsTOTP(itemID: legacy.id, items: [legacy]))
    #expect(!PassCapabilities(totpLimit: 3).allowsTOTP(itemID: missingTime.id, items: [missingTime]))
}
@Test func missingOrInvalidCapabilityLimitNeverMeansUnlimited() throws {
    #expect(throws: Error.self) { try JSONDecoder().decode(PassCapabilities.self, from: Data("{}".utf8)) }
    #expect(throws: Error.self) { try JSONDecoder().decode(PassCapabilities.self, from: Data("{\"totp_limit\":-1}".utf8)) }
    #expect(try JSONDecoder().decode(PassCapabilities.self, from: Data("{\"totp_limit\":null}".utf8)).totpLimit == nil)
}
