// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct ContactAddress: Codable, Equatable, Sendable {
    public var contactID: UInt64
    public var name: String
    public var email: String
    public init(contactID: UInt64, name: String, email: String) { self.contactID = contactID; self.name = name; self.email = email }
}
public struct ContactEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case contact, group }
    public var localID: UInt64
    public var kind: Kind
    public var name: String
    public var emails: [ContactAddress]
    public var id: String { kind.rawValue + ":" + String(localID) }
    public var displayName: String { name.isEmpty ? (emails.first?.email ?? "Unnamed contact") : name }
    public init(localID: UInt64, kind: Kind = .contact, name: String, emails: [ContactAddress]) {
        self.localID = localID; self.kind = kind; self.name = name; self.emails = emails
    }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || displayName.localizedStandardContains(query) || emails.contains { $0.email.localizedStandardContains(query) || $0.name.localizedStandardContains(query) }
    }
    public static func validate(_ entries: [Self]) throws {
        guard entries.count <= 5000, Set(entries.map(\.id)).count == entries.count else { throw ProtonXError.invalidResponse }
        for entry in entries {
            guard entry.localID > 0, entry.name.utf8.count <= 4096, entry.emails.count <= 1000,
                  entry.emails.allSatisfy({ $0.contactID > 0 && $0.name.utf8.count <= 4096 && $0.email.utf8.count <= 1024 }) else { throw ProtonXError.invalidResponse }
        }
    }
}
public struct ContactDetail: Codable, Equatable, Sendable {
    public struct Field: Codable, Equatable, Sendable {
        public var label: String
        public var value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }
    public var localID: UInt64
    public var fields: [Field]
    public init(localID: UInt64, fields: [Field]) { self.localID = localID; self.fields = fields }
    public func validate(for expected: UInt64) throws {
        guard localID == expected, fields.count <= 1024,
              fields.allSatisfy({ !$0.label.isEmpty && $0.label.utf8.count <= 128 && $0.value.utf8.count <= 128 * 1024 }),
              fields.reduce(0, { $0 + $1.value.utf8.count }) <= 256 * 1024 else { throw ProtonXError.invalidResponse }
    }
}
public enum ContactRecipients {
    /// Match the native composer envelope policy, never interpret names as addresses.
    public static func valid(_ value: String) -> Bool {
        guard value.utf8.count <= 254, !value.isEmpty,
              !value.contains(where: { $0.isWhitespace || $0.isNewline || "<>\"(),;:".contains($0) }),
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }
    public static func appending(_ addresses: [String], to text: String, otherFields: [String]) throws -> String {
        let existing = NativeMailComposeContent.parseRecipients(text)
        let others = otherFields.flatMap(NativeMailComposeContent.parseRecipients)
        guard addresses.allSatisfy(valid), (existing + others).allSatisfy(valid) else { throw ProtonXError.invalidResponse }
        var used = Set((existing + others).map { $0.lowercased() })
        var additions: [String] = []
        for address in addresses where used.insert(address.lowercased()).inserted { additions.append(address) }
        guard existing.count + others.count + additions.count <= 100 else { throw ProtonXError.invalidResponse }
        return (existing + additions).joined(separator: ", ")
    }
}
