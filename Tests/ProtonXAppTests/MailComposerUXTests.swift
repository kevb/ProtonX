// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@Suite @MainActor struct MailComposerUXTests {
    private let sampleContacts: [ContactEntry] = [
        .init(localID: 1, name: "Sam Rivera", emails: [.init(contactID: 1, name: "Sam Rivera", email: "sam@example.com")]),
        .init(localID: 2, name: "Jamie Chen", emails: [
            .init(contactID: 2, name: "Jamie Chen", email: "jamie@example.com"),
            .init(contactID: 2, name: "Jamie Chen", email: "jamie.work@example.com")
        ]),
        .init(localID: 3, name: "Alex Samuels", emails: [.init(contactID: 3, name: "Alex Samuels", email: "alex@example.com")]),
        .init(localID: 4, kind: .group, name: "Weekend friends", emails: [
            .init(contactID: 1, name: "Sam Rivera", email: "sam@example.com"),
            .init(contactID: 2, name: "Jamie Chen", email: "jamie@example.com")
        ])
    ]

    @Test func autocompleteRanksPrefixAheadOfWordAndSubstringAndExcludesExistingAcrossFields() {
        let existing = MailRecipientAutocomplete.existingAddresses(from: ["SAM@example.com", "other@example.com"])
        let results = MailRecipientAutocomplete.suggestions(for: "sam", contacts: sampleContacts, excluding: existing)
        // sam@example.com is excluded, Alex Samuels matches by word prefix, and Weekend friends keeps remaining jamie@example.com.
        #expect(!results.contains { $0.addresses.contains("sam@example.com") })
        #expect(results.first?.displayName == "Alex Samuels")

        let allSam = MailRecipientAutocomplete.suggestions(for: "sam", contacts: sampleContacts, excluding: [])
        #expect(allSam.first?.displayName == "Sam Rivera")
        #expect(allSam.count >= 2 && allSam[1].displayName == "Alex Samuels")
    }

    @Test func autocompleteMatchesGroupsAndRespectsLimit() {
        let groups = MailRecipientAutocomplete.suggestions(for: "week", contacts: sampleContacts, excluding: [])
        #expect(groups.count == 1)
        #expect(groups[0].isGroup && groups[0].addresses == ["jamie@example.com", "sam@example.com"])

        let capped = MailRecipientAutocomplete.suggestions(for: "example.com", contacts: sampleContacts, excluding: [], limit: 2)
        #expect(capped.count == 2)
        #expect(MailRecipientAutocomplete.suggestions(for: "   ", contacts: sampleContacts, excluding: []).isEmpty)
    }

    @Test func commitAndRemoveManageRecipientChipsWithoutDuplicatingAcrossFields() {
        let first = MailRecipientAutocomplete.commit("sam@example.com, invalid-token, jamie@example.com", into: "", otherFields: ["bcc@example.com"])
        #expect(first.updated == "sam@example.com, jamie@example.com")
        #expect(first.remaining == "invalid-token")

        // Duplicate across Cc/Bcc is deduplicated cleanly.
        let dup = MailRecipientAutocomplete.commit("BCC@example.com; new@example.com", into: first.updated, otherFields: ["bcc@example.com"])
        #expect(dup.updated == "sam@example.com, jamie@example.com, new@example.com")
        #expect(dup.remaining.isEmpty)

        let removed = MailRecipientAutocomplete.remove("JAMIE@example.com", from: dup.updated)
        #expect(removed == "sam@example.com, new@example.com")
    }

    @Test func detachedComposerResetsOnDiscardAndLock() {
        let store = NativeMailStore(previewOnly: true)
        store.compose()
        #expect(store.draft != nil && !store.composerDetached)
        store.composerDetached = true
        #expect(store.composerDetached)

        store.discardDraft()
        #expect(store.draft == nil && !store.composerDetached)

        store.compose()
        store.composerDetached = true
        store.lock()
        #expect(store.draft == nil && !store.composerDetached)
    }
}
