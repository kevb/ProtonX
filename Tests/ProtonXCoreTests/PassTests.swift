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

@Test func nativeDraftSendsOnlyChangedCustomFieldsAndPreservesOmittedSetup() throws {
    var draft = NativeItemDraft(); draft.title = "Synthetic"
    draft.customFields = [CustomFieldDraft(sourceIndex: 2, name: "Recovery", value: "DEMO", concealed: true)]
    var json = try #require(JSONSerialization.jsonObject(with: draft.encodedInput()) as? [String: Any])
    #expect((json["custom_fields"] as? [Any])?.isEmpty == true)
    #expect(json["totp_uri"] == nil); #expect(json["urls"] == nil)
    draft.customFields[0].value = "CHANGED"
    json = try #require(JSONSerialization.jsonObject(with: draft.encodedInput()) as? [String: Any])
    let edit = try #require((json["custom_fields"] as? [[String: Any]])?.first)
    #expect(edit["source_index"] as? Int == 2); #expect(edit["expected_hidden"] as? Bool == true)
    #expect(edit["expected_name"] as? String == "Recovery")
}
@Test func completeDraftSizeAndSetupValidationRunsBeforeHelper() async throws {
    let runner = RecordingRunner()
    let service = PassService(runner: runner)
    let vault = Vault(name: "Synthetic", vaultID: "v", shareID: "s", canCreate: true)
    var draft = NativeItemDraft(); draft.title = "Synthetic"; draft.email = String(repeating: "a", count: 262144)
    await #expect(throws: ProtonXError.self) { try await service.create(draft, vault: vault) }
    #expect(runner.last() == nil)
    draft.email = nil
    for uri in ["otpauth://hotp/Test?secret=ABC", "otpauth://totp/Test?secret=invalid!", "https://example.com"] {
        draft.totpURI = uri; #expect(throws: ProtonXError.self) { try draft.encodedInput() }
    }
    draft.totpURI = "otpauth://totp/Synthetic?secret=JBSWY3DPEHPK3PXP"
    #expect(throws: Never.self) { _ = try draft.encodedInput() }
}
@Test func nativeWritesUseStdinAndPermissionsFailClosed() async throws {
    let runner = RecordingRunner(); runner.response = Data(#"{"item_id":"created-synthetic"}"#.utf8)
    let service = PassService(runner: runner)
    var draft = NativeItemDraft(); draft.title = "Synthetic"; draft.password = "SYNTHETIC-$()\n=secret"; draft.note = "Login notes"
    let vault = Vault(name: "Synthetic", vaultID: "v", shareID: "s", canCreate: true, canUpdate: true)
    #expect(try await service.create(draft, vault: vault) == "created-synthetic")
    #expect(runner.last()?.arguments == ["native-create", "--share-id", "s"])
    #expect(runner.last()?.arguments.joined().contains(draft.password!) == false)
    let input = try #require(runner.last()?.input)
    let json = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
    #expect(json["note"] as? String == draft.note)
    let readonly = Vault(name: "Read only", vaultID: "v", shareID: "s")
    let count = runner.commands.count
    await #expect(throws: ProtonXError.self) { try await service.create(draft, vault: readonly) }
    #expect(runner.commands.count == count)
}
@Test func atomicSnapshotRejectsUnknownVaultsAndDuplicateAcrossTrash() throws {
    let valid = #"{"vaults":[{"name":"Synthetic","vault_id":"v","share_id":"s","can_create":false,"can_update":false,"can_trash":false}],"items":[{"id":"i","share_id":"s","title":"Synthetic","item_type":"login"}],"trashed_items":[],"capabilities":{"totp_limit":null}}"#
    let snapshot = try JSONDecoder().decode(PassSnapshot.self, from: Data(valid.utf8))
    #expect(snapshot.vaults.first?.canCreate == false); #expect(!snapshot.capabilities.customFieldsAllowed)
    #expect(throws: Error.self) { try JSONDecoder().decode(PassSnapshot.self, from: Data(valid.replacingOccurrences(of: "\"share_id\":\"s\",\"title\"", with: "\"share_id\":\"unknown\",\"title\"").utf8)) }
    var json = try #require(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any]); json["trashed_items"] = json["items"]
    #expect(throws: Error.self) { try JSONDecoder().decode(PassSnapshot.self, from: JSONSerialization.data(withJSONObject: json)) }
}
@Test func recentlyModifiedSortAndTitleTiesAreDeterministic() {
    let items = [PassItem(itemID: "a", shareID: "s", title: "Same", kind: "login", modifiedAt: "2026-01-01"), PassItem(itemID: "b", shareID: "s", title: "Same", kind: "login", modifiedAt: "2026-02-01")]
    #expect(ItemSearch.filter(items.reversed(), query: "").map(\.itemID) == ["a", "b"])
    #expect(ItemSearch.filter(items, query: "", sort: .recentlyModified).map(\.itemID) == ["b", "a"])
}
@Test func TOTPSetupLimitsCountExistingConfiguredLoginsAndPreserveEligibleReplacement() {
    let item = PassItem(itemID: "a", shareID: "s", title: "Synthetic", kind: "login", hasTOTP: true, createdAt: "2026-01-01")
    let policy = PassCapabilities(totpLimit: 1)
    #expect(!policy.allowsTOTPSetup(itemID: nil, items: [item]))
    #expect(policy.allowsTOTPSetup(itemID: item.id, items: [item]))
    #expect(!PassCapabilities(totpLimit: 0).allowsTOTPSetup(itemID: nil, items: []))
}
@Test func customTOTPSeedIsNeverExposedAsAnOrdinarySecretField() throws {
    let detail = try ItemDetail.decode(Data(#"{"item":{"content":{"title":"Synthetic","content":{"Note":null},"extra_fields":[{"name":"TOTP","content":{"Totp":"otpauth://totp/Test?secret=SYNTHETIC"}}]}}}"#.utf8))
    #expect(detail.fields.isEmpty); #expect(detail.editableCustomFields.isEmpty); #expect(detail.unsupportedCustomFieldCount == 1)
}

@Test func nativeEditRequiresRevisionAndSendsItWithDraft() async throws {
    let runner = RecordingRunner(); let service = PassService(runner: runner)
    let vault = Vault(name: "Synthetic", vaultID: "v", shareID: "s", canUpdate: true)
    let item = PassItem(itemID: "i", shareID: "s", title: "Synthetic", kind: "note")
    var draft = NativeItemDraft(); draft.kind = "note"; draft.title = "Synthetic"
    await #expect(throws: ProtonXError.self) { try await service.edit(draft, item: item, vault: vault) }
    #expect(runner.last() == nil)
    draft.expectedRevision = 7; runner.response = Data(#"{"updated":true}"#.utf8)
    try await service.edit(draft, item: item, vault: vault)
    let input = try #require(runner.last()?.input)
    let json = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
    #expect(json["expected_revision"] as? Int == 7)
    let detail = try ItemDetail.decode(Data(#"{"revision":7,"item":{"content":{"title":"Synthetic","content":{"Note":null}}}}"#.utf8))
    #expect(detail.revision == 7)
    let conflict = try JSONDecoder().decode(HelperDiagnostic.self, from: Data(#"{"failure":"conflict"}"#.utf8))
    #expect(conflict.message.contains("Reopen"))
}

@Test func malformedRevisionsCannotAuthorizeEditing() {
    for revision in ["true", "-1", "1.5", "\"7\""] {
        let json = "{\"revision\":" + revision + ",\"item\":{\"content\":{\"title\":\"Synthetic\",\"content\":{\"Note\":null}}}}"
        #expect(throws: Error.self) { try ItemDetail.decode(Data(json.utf8)) }
    }
}

@Test func verificationCodeUsesFreshPlanCheckedNativeCommand() async throws {
    let runner = RecordingRunner(); runner.response = Data("123456\n".utf8)
    let service = PassService(runner: runner)
    let item = PassItem(itemID: "i", shareID: "s", title: "Synthetic", kind: "login")
    #expect(try await service.totp(item) == "123456")
    #expect(runner.last()?.arguments == ["native-totp", "--share-id", "s", "--item-id", "i"])
    #expect(runner.last()?.input == nil)
    runner.response = Data("not-a-code".utf8)
    await #expect(throws: ProtonXError.self) { try await service.totp(item) }
}

@Test func savedPassSnapshotRejectsMalformedLeasesAndGenerationBeforeUse() throws {
    let metadata = #"{"vaults":[],"items":[],"trashed_items":[],"capabilities":{"totp_limit":null,"custom_fields_allowed":true}}"#
    func data(_ saved: Int64, _ expires: Int64, _ generation: String = "00000000-0000-4000-8000-000000000001") -> Data {
        Data("{\"snapshot\":\(metadata),\"saved_at\":\(saved),\"expires_at\":\(expires),\"generation\":\"\(generation)\"}".utf8)
    }
    for (saved, expires) in [(Int64(0), Int64(60)), (100, 100), (100, 99), (100, 86501), (1, Int64.max), (Int64.min, Int64.max)] {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SavedPassSnapshot.self, from: data(saved, expires)) }
    }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SavedPassSnapshot.self, from: data(100, 200, "unknown")) }
    let saved = try JSONDecoder().decode(SavedPassSnapshot.self, from: data(100, 200))
    #expect(!saved.usable(at: Date(timeIntervalSince1970: 99)))
    #expect(saved.usable(at: Date(timeIntervalSince1970: 100)))
    #expect(!saved.usable(at: Date(timeIntervalSince1970: 200)))
    let unknown = metadata.dropLast() + #", "cache_status":"future-unknown"}"#
    #expect(throws: (any Error).self) { try JSONDecoder().decode(PassSnapshot.self, from: Data(unknown.utf8)) }
}
