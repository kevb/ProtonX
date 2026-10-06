import Foundation

/// Only editable text/hidden fields cross this contract. Other field types stay in Proton's SDK.
public struct CustomFieldDraft: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let sourceIndex: Int?
    public let originalName: String?
    public let originalValue: String?
    public let originalConcealed: Bool?
    public var name: String
    public var value: String
    public var concealed: Bool
    public var removed = false
    public init(sourceIndex: Int? = nil, name: String = "", value: String = "", concealed: Bool = false) {
        self.sourceIndex = sourceIndex; self.name = name; self.value = value; self.concealed = concealed
        originalName = sourceIndex == nil ? nil : name
        originalValue = sourceIndex == nil ? nil : value
        originalConcealed = sourceIndex == nil ? nil : concealed
    }
    var changed: Bool { sourceIndex == nil || removed || name != originalName || value != originalValue || concealed != originalConcealed }
}

public struct NativeItemDraft: Encodable, Sendable {
    public var expectedRevision: UInt64?
    public var kind = "login"
    public var title = ""
    public var note = ""
    public var username: String?
    public var email: String?
    public var password: String?
    /// nil preserves existing URL matching settings; an empty list explicitly clears websites.
    public var urls: [String]?
    /// nil preserves setup without exposing the existing seed; empty explicitly removes setup.
    public var totpURI: String?
    public var customFields: [CustomFieldDraft] = []
    public init() {}
    enum CodingKeys: String, CodingKey { case kind, title, note, username, email, password, urls; case expectedRevision = "expected_revision"; case totpURI = "totp_uri"; case customFields = "custom_fields" }
    private struct FieldEdit: Encodable {
        let sourceIndex: Int?, expectedName: String?, expectedHidden: Bool?
        let name: String, value: String, concealed: Bool, remove: Bool
        enum CodingKeys: String, CodingKey { case sourceIndex = "source_index"; case expectedName = "expected_name"; case expectedHidden = "expected_hidden"; case name, value, concealed, remove }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
        try values.encode(kind, forKey: .kind); try values.encode(title, forKey: .title); try values.encode(note, forKey: .note)
        try values.encodeIfPresent(username, forKey: .username); try values.encodeIfPresent(email, forKey: .email)
        try values.encodeIfPresent(password, forKey: .password); try values.encodeIfPresent(urls, forKey: .urls); try values.encodeIfPresent(totpURI, forKey: .totpURI)
        try values.encode(customFields.filter(\.changed).filter { !($0.sourceIndex == nil && $0.removed) }.map {
            FieldEdit(sourceIndex: $0.sourceIndex, expectedName: $0.originalName, expectedHidden: $0.originalConcealed,
                      name: $0.removed ? $0.originalName ?? $0.name : $0.name, value: $0.removed ? "" : $0.value, concealed: $0.concealed, remove: $0.removed)
        }, forKey: .customFields)
    }
    public func encodedInput() throws -> Data {
        guard ["login", "note"].contains(kind), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProtonXError.invalidInput("Give the item a title and choose a supported type.")
        }
        guard urls?.allSatisfy({ URLPolicy.webURL($0) != nil }) ?? true else { throw ProtonXError.invalidInput("Website addresses must use https:// or http://.") }
        if let uri = totpURI, !uri.isEmpty {
            guard kind == "login", let parts = URLComponents(string: uri), parts.scheme == "otpauth", parts.host == "totp", !parts.path.isEmpty,
                  let secret = parts.queryItems?.first(where: { $0.name == "secret" })?.value, !secret.isEmpty,
                  secret.uppercased().allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=".contains($0) }) else {
                throw ProtonXError.invalidInput("Enter an otpauth://totp/ setup URI with a valid Base32 secret.")
            }
        }
        guard customFields.filter({ !$0.removed }).allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ProtonXError.invalidInput("Give every custom field a name.")
        }
        let input = try JSONEncoder().encode(self)
        guard input.count <= 262144 else { throw ProtonXError.invalidInput("Keep the complete item below 256 KB.") }
        return input
    }
}

/// Atomic metadata-only snapshot. Reject inconsistent responses instead of mixing partial vault loads.
public struct PassSnapshot: Decodable, Sendable {
    public let vaults: [Vault]
    public let items: [PassItem]
    public let trashedItems: [PassItem]
    public let capabilities: PassCapabilities
    public let cacheStatus: String?
    enum CodingKeys: String, CodingKey { case vaults, items, capabilities; case trashedItems = "trashed_items"; case cacheStatus = "cache_status" }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vaults = try values.decode([Vault].self, forKey: .vaults)
        items = try values.decode([PassItem].self, forKey: .items)
        trashedItems = try values.decode([PassItem].self, forKey: .trashedItems)
        capabilities = try values.decode(PassCapabilities.self, forKey: .capabilities)
        cacheStatus = try values.decodeIfPresent(String.self, forKey: .cacheStatus)
        guard cacheStatus == nil || ["ready", "unavailable", "planUnavailable"].contains(cacheStatus!) else { throw ProtonXError.invalidResponse }
        let shares = Set(vaults.map(\.id)), all = items + trashedItems
        guard shares.count == vaults.count, !shares.contains(""), Set(all.map(\.id)).count == all.count,
              all.allSatisfy({ !$0.itemID.isEmpty && shares.contains($0.shareID) }) else { throw ProtonXError.invalidResponse }
    }
}

/// Metadata only. All persisted contents and selected-item decryption stay in Rust.
public struct SavedPassSnapshot: Decodable, Sendable {
    public let snapshot: PassSnapshot
    public let savedAt: Date
    public let expiresAt: Date
    public let generation: String
    enum CodingKeys: String, CodingKey { case snapshot, generation; case savedAt = "saved_at"; case expiresAt = "expires_at" }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try values.decode(PassSnapshot.self, forKey: .snapshot)
        let saved = try values.decode(Int64.self, forKey: .savedAt)
        let expires = try values.decode(Int64.self, forKey: .expiresAt)
        generation = try values.decode(String.self, forKey: .generation)
        guard saved > 0, expires > saved, expires - saved <= 86400,
              UUID(uuidString: generation) != nil else { throw ProtonXError.invalidResponse }
        savedAt = Date(timeIntervalSince1970: TimeInterval(saved))
        expiresAt = Date(timeIntervalSince1970: TimeInterval(expires))
    }
    public func usable(at date: Date) -> Bool { date >= savedAt && date < expiresAt }
}
