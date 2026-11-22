// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import ProtonXCore

struct MailRecipientSuggestion: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let subtitle: String
    let addresses: [String]
    let isGroup: Bool
}

enum MailRecipientAutocomplete {
    static let defaultLimit = 8

    static func existingAddresses(from fields: [String]) -> Set<String> {
        Set(fields.flatMap { NativeMailComposeContent.parseRecipients($0) }.map { $0.lowercased() })
    }

    static func suggestions(
        for rawQuery: String,
        contacts: [ContactEntry],
        excluding existing: Set<String>,
        limit: Int = defaultLimit
    ) -> [MailRecipientSuggestion] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, limit > 0 else { return [] }

        var scored: [(rank: Int, suggestion: MailRecipientSuggestion)] = []
        var seenEmails = existing

        for entry in contacts {
            if entry.kind == .group {
                let validEmails = Array(Set(entry.emails.map(\.email).filter(ContactRecipients.valid))).sorted()
                let remaining = validEmails.filter { !existing.contains($0.lowercased()) }
                guard !remaining.isEmpty else { continue }
                let lowerName = entry.displayName.lowercased()
                let rank: Int?
                if lowerName.hasPrefix(query) { rank = 0 }
                else if lowerName.contains(query) { rank = 2 }
                else if remaining.contains(where: { $0.lowercased().contains(query) }) { rank = 3 }
                else { rank = nil }
                if let rank {
                    scored.append((rank, MailRecipientSuggestion(
                        id: "group:\(entry.localID)",
                        displayName: entry.displayName,
                        subtitle: "\(remaining.count) member\(remaining.count == 1 ? "" : "s")",
                        addresses: remaining,
                        isGroup: true
                    )))
                }
            } else {
                for item in entry.emails where ContactRecipients.valid(item.email) {
                    let lowerEmail = item.email.lowercased()
                    guard seenEmails.insert(lowerEmail).inserted else { continue }
                    let lowerName = entry.displayName.lowercased()
                    let rank: Int?
                    if lowerName.hasPrefix(query) || lowerEmail.hasPrefix(query) { rank = 0 }
                    else if lowerName.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { rank = 1 }
                    else if lowerName.contains(query) || lowerEmail.contains(query) { rank = 2 }
                    else { rank = nil }
                    if let rank {
                        let name = entry.displayName.isEmpty ? item.email : entry.displayName
                        scored.append((rank, MailRecipientSuggestion(
                            id: "contact:\(entry.localID):\(lowerEmail)",
                            displayName: name,
                            subtitle: item.email,
                            addresses: [item.email],
                            isGroup: false
                        )))
                    }
                }
            }
        }

        return scored
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                let nameOrder = $0.suggestion.displayName.localizedStandardCompare($1.suggestion.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.suggestion.subtitle.localizedStandardCompare($1.suggestion.subtitle) == .orderedAscending
            }
            .prefix(limit)
            .map(\.suggestion)
    }

    static func commit(_ rawInput: String, into current: String, otherFields: [String]) -> (updated: String, remaining: String) {
        let parts = rawInput
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return (current, "") }
        let valid = parts.filter(ContactRecipients.valid)
        let invalid = parts.filter { !ContactRecipients.valid($0) }
        guard !valid.isEmpty else { return (current, rawInput) }
        if let merged = try? ContactRecipients.appending(valid, to: current, otherFields: otherFields) {
            return (merged, invalid.joined(separator: ", "))
        }
        return (current, rawInput)
    }

    static func remove(_ address: String, from current: String) -> String {
        let lower = address.lowercased()
        let remaining = NativeMailComposeContent.parseRecipients(current).filter { $0.lowercased() != lower }
        return remaining.joined(separator: ", ")
    }
}

struct MailRecipientChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                maxLineWidth = max(maxLineWidth, x - spacing)
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        maxLineWidth = max(maxLineWidth, max(0, x - spacing))
        return CGSize(width: min(maxWidth, maxLineWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct MailRecipientField: View {
    let title: String
    let fieldKey: String
    @ObservedObject var store: NativeMailStore
    let draftToken: UInt64
    @Binding var text: String
    let otherFields: [String]
    let editable: Bool
    var focus: FocusState<String?>.Binding
    @Binding var pickerField: String?

    @State private var draftInput = ""
    @State private var highlightedIndex = 0
    @State private var dismissSuggestions = false

    private var chips: [String] { NativeMailComposeContent.parseRecipients(text) }
    private var suggestions: [MailRecipientSuggestion] {
        guard !dismissSuggestions, editable, focus.wrappedValue == fieldKey else { return [] }
        let existing = MailRecipientAutocomplete.existingAddresses(from: [text] + otherFields)
        return MailRecipientAutocomplete.suggestions(for: draftInput, contacts: store.contacts, excluding: existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(title).foregroundStyle(.secondary).frame(width: 60, alignment: .leading).padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    if !chips.isEmpty {
                        MailRecipientChipFlowLayout(spacing: 6) {
                            ForEach(chips, id: \.self) { address in
                                HStack(spacing: 5) {
                                    Text(address).font(.callout).lineLimit(1)
                                    if editable {
                                        Button {
                                            text = MailRecipientAutocomplete.remove(address, from: text)
                                            store.markDraftEdited()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove \(address)")
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(MailTheme.accent.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    TextField(chips.isEmpty ? "Name or email address" : "Add another recipient", text: $draftInput)
                        .textFieldStyle(.plain)
                        .focused(focus, equals: fieldKey)
                        .disabled(!editable)
                        .onSubmit { acceptHighlightedOrCommit() }
                        .onChange(of: draftInput) { _, next in
                            dismissSuggestions = false
                            highlightedIndex = 0
                            if next.contains(",") || next.contains(";") {
                                commitDraftInput()
                            }
                        }
                        .onChange(of: focus.wrappedValue) { old, next in
                            if old == fieldKey && next != fieldKey && !draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                commitDraftInput()
                            }
                            if next == fieldKey && !store.contactsLoaded && !store.contactsBusy && store.phase == .open {
                                store.loadContacts(refreshDetails: false)
                            }
                        }
                        .onKeyPress(.downArrow) {
                            guard !suggestions.isEmpty else { return .ignored }
                            highlightedIndex = min(suggestions.count - 1, highlightedIndex + 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            guard !suggestions.isEmpty else { return .ignored }
                            highlightedIndex = max(0, highlightedIndex - 1)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            guard !suggestions.isEmpty else { return .ignored }
                            dismissSuggestions = true
                            return .handled
                        }
                        .onKeyPress(.tab) {
                            guard !suggestions.isEmpty else { return .ignored }
                            acceptHighlightedOrCommit()
                            return .handled
                        }
                        .accessibilityIdentifier("composerRecipientField." + fieldKey)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { pickerField = fieldKey } label: { Image(systemName: "person.crop.circle.badge.plus") }
                    .buttonStyle(.plain)
                    .padding(.top, 3)
                    .help("Add \(title) recipients from Contacts")
                    .accessibilityLabel("Add \(title) recipients from Contacts")
                    .disabled(!editable)
                    .popover(isPresented: Binding(get: { pickerField == fieldKey }, set: { if !$0 { pickerField = nil } })) {
                        ContactRecipientPicker(store: store) { addresses in store.addContactRecipients(addresses, field: fieldKey, token: draftToken) }
                    }
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button { accept(suggestion) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: suggestion.isGroup ? "person.2.fill" : "person.crop.circle")
                                    .foregroundStyle(MailTheme.accent)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.displayName).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(index == highlightedIndex ? MailTheme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(MailTheme.collection, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(MailTheme.border, lineWidth: 1) }
                .padding(.leading, 68)
                .accessibilityIdentifier("composerSuggestions." + fieldKey)
            }
        }
        .padding(.vertical, 12)
    }

    private func acceptHighlightedOrCommit() {
        if !suggestions.isEmpty {
            let safeIndex = min(max(0, highlightedIndex), suggestions.count - 1)
            accept(suggestions[safeIndex])
        } else {
            commitDraftInput()
        }
    }

    private func accept(_ suggestion: MailRecipientSuggestion) {
        if let merged = try? ContactRecipients.appending(suggestion.addresses, to: text, otherFields: otherFields) {
            text = merged
            draftInput = ""
            highlightedIndex = 0
            store.markDraftEdited()
        }
    }

    private func commitDraftInput() {
        let result = MailRecipientAutocomplete.commit(draftInput, into: text, otherFields: otherFields)
        if result.updated != text {
            text = result.updated
            store.markDraftEdited()
        }
        draftInput = result.remaining
    }
}
