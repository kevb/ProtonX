// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProtonXCore

@Suite struct ContactTests {
    func entry(_ id: UInt64 = 10, _ kind: ContactEntry.Kind = .contact) -> ContactEntry {
        .init(localID: id, kind: kind, name: "Sam Rivera", emails: [.init(contactID: 10, name: "Sam", email: "sam@example.com")])
    }
    @Test func identitySeparatesGroupsAndContactsAndSearchesEmails() throws {
        try ContactEntry.validate([entry(), entry(10, .group)])
        #expect(entry().id != entry(10, .group).id)
        #expect(entry().matches("rivera")); #expect(entry().matches("SAM@EXAMPLE")); #expect(!entry().matches("not here"))
        #expect(throws: ProtonXError.invalidResponse) { try ContactEntry.validate([entry(), entry()]) }
        #expect(throws: ProtonXError.invalidResponse) { try ContactEntry.validate([entry(0)]) }
        #expect(throws: ProtonXError.invalidResponse) { try ContactEntry.validate(Array(repeating: entry(), count: 5001)) }
    }
    @Test func detailBoundsAndIdentityAreEnforced() throws {
        let detail = ContactDetail(localID: 10, fields: [.init("Note", "Synthetic note")])
        try detail.validate(for: 10)
        #expect(throws: ProtonXError.invalidResponse) { try detail.validate(for: 20) }
        #expect(throws: ProtonXError.invalidResponse) { try ContactDetail(localID: 10, fields: [.init("Note", String(repeating: "x", count: 128 * 1024 + 1))]).validate(for: 10) }
    }
    @Test func recipientsDeduplicateAcrossFieldsAndPreserveExistingInputOnFailure() throws {
        #expect(try ContactRecipients.appending(["sam@example.com", "SAM@example.com", "jamie@example.com"], to: "alex@example.com", otherFields: ["SAM@example.com", ""]) == "alex@example.com, jamie@example.com")
        #expect(throws: ProtonXError.invalidResponse) { try ContactRecipients.appending(["sam@example.com"], to: "unfinished@", otherFields: []) }
        #expect(throws: ProtonXError.invalidResponse) { try ContactRecipients.appending(["evil@example.com\nBcc: other@example.com"], to: "", otherFields: []) }
        #expect(throws: ProtonXError.invalidResponse) { try ContactRecipients.appending(["extra@example.com"], to: (0..<100).map { "person\($0)@example.com" }.joined(separator: ","), otherFields: []) }
    }
    @Test func helperReplyChecksContactsAndClosedRoutes() throws {
        struct Reply: Encodable { let schema = 1; let id = 1; let result: NativeMailResult }
        let data = try JSONEncoder().encode(Reply(result: .init(contacts: [entry(), entry()])))
        #expect(throws: ProtonXError.invalidResponse) { try NativeMailProcess.decode(data, expectedID: 1) }
        #expect(ProductRoute(url: URL(string: "protonx://contacts")!) == .contacts)
        #expect(ProductRoute(url: URL(string: "protonx://contacts?account=other")!) == nil)
    }
}
