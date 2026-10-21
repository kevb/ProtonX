// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct PassAliasOptions: Codable, Sendable {
    public struct Suffix: Codable, Sendable, Hashable {
        public let suffix: String
        public let signedSuffix: String
        enum CodingKeys: String, CodingKey { case suffix; case signedSuffix = "signed_suffix" }
        public init(suffix: String, signedSuffix: String) { self.suffix = suffix; self.signedSuffix = signedSuffix }
        public func validate() throws {
            guard PassAliasOptions.validEmail("alias" + suffix), suffix.utf8.count <= 280,
                  suffix.hasPrefix(".") || suffix.hasPrefix("@"), !signedSuffix.isEmpty, signedSuffix.utf8.count <= 8192,
                  !signedSuffix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ProtonXError.invalidResponse }
        }
    }
    public struct Mailbox: Codable, Sendable, Identifiable, Hashable {
        public let id: Int64
        public let email: String
        public init(id: Int64, email: String) { self.id = id; self.email = email }
    }
    public let suffixes: [Suffix]
    public let mailboxes: [Mailbox]
    public init(suffixes: [Suffix], mailboxes: [Mailbox]) { self.suffixes = suffixes; self.mailboxes = mailboxes }
    public func validate() throws {
        guard (1...100).contains(suffixes.count), (1...100).contains(mailboxes.count),
              Set(mailboxes.map(\.id)).count == mailboxes.count,
              Set(suffixes.map(\.suffix)).count == suffixes.count,
              mailboxes.allSatisfy({ $0.id > 0 && Self.validEmail($0.email) }) else { throw ProtonXError.invalidResponse }
        for suffix in suffixes { try suffix.validate() }
    }
    public static func validEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return value.utf8.count <= 320 && parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
}
public struct PassAliasDraft: Codable, Sendable {
    public var title: String
    public var note: String
    public var prefix: String
    public let suffix: String
    public let signedSuffix: String
    public let mailboxID: Int64
    enum CodingKeys: String, CodingKey { case title, note, prefix, suffix; case signedSuffix = "signed_suffix"; case mailboxID = "mailbox_id" }
    public init(title: String, note: String = "", prefix: String, suffix: PassAliasOptions.Suffix, mailbox: PassAliasOptions.Mailbox) {
        self.title = title; self.note = note; self.prefix = prefix; self.suffix = suffix.suffix; signedSuffix = suffix.signedSuffix; mailboxID = mailbox.id
    }
    public var email: String { prefix + suffix }
    public static func validPrefix(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 40 && !value.hasPrefix(".") && !value.hasSuffix(".") && !value.contains("..") && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }
    }
    public static func suggestedPrefix(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let words = folded.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted).filter { !$0.isEmpty }
        let value = String(words.joined(separator: "-").prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "alias" : value
    }
    public func encodedInput() throws -> Data {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 256,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), note.utf8.count <= 16384,
              Self.validPrefix(prefix), PassAliasOptions.validEmail(email), mailboxID > 0 else { throw ProtonXError.invalidInput("Check the alias title, prefix and forwarding mailbox.") }
        try PassAliasOptions.Suffix(suffix: suffix, signedSuffix: signedSuffix).validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 32768 else { throw ProtonXError.invalidInput("The alias details are too long.") }
        return data
    }
}
public struct CreatedPassAlias: Codable, Sendable, Equatable {
    public let itemID: String
    public let alias: String
    enum CodingKeys: String, CodingKey { case itemID = "item_id", alias }
    public init(itemID: String, alias: String) { self.itemID = itemID; self.alias = alias }
}
