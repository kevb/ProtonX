import Foundation

public struct Vault: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let vaultID: String
    public let shareID: String
    public let canCreate: Bool?
    public let canUpdate: Bool?
    public let canTrash: Bool?
    public var id: String { shareID }
    enum CodingKeys: String, CodingKey { case name; case vaultID = "vault_id"; case shareID = "share_id"; case canCreate = "can_create"; case canUpdate = "can_update"; case canTrash = "can_trash" }
    public init(name: String, vaultID: String, shareID: String, canCreate: Bool? = nil, canUpdate: Bool? = nil, canTrash: Bool? = nil) { self.name = name; self.vaultID = vaultID; self.shareID = shareID; self.canCreate = canCreate; self.canUpdate = canUpdate; self.canTrash = canTrash }
}

public struct PassItem: Codable, Identifiable, Hashable, Sendable {
    public let itemID: String
    public let shareID: String
    public let title: String
    public let kind: String
    public let hasTOTP: Bool?
    public let createdAt: String?
    public let modifiedAt: String?
    public var id: String { shareID + ":" + itemID }
    enum CodingKeys: String, CodingKey { case itemID = "id"; case shareID = "share_id"; case title; case kind = "item_type"; case hasTOTP = "has_totp"; case createdAt = "create_time"; case modifiedAt = "modify_time" }
    public init(itemID: String, shareID: String, title: String, kind: String, hasTOTP: Bool? = nil, createdAt: String? = nil, modifiedAt: String? = nil) {
        self.hasTOTP = hasTOTP; self.createdAt = createdAt; self.modifiedAt = modifiedAt
        self.itemID = itemID; self.shareID = shareID; self.title = title; self.kind = kind
    }
    public var typeName: String {
        switch kind { case "login": "Login"; case "note": "Secure note"; case "alias": "Alias"; case "credit_card": "Card"; case "identity": "Identity"; case "ssh_key": "SSH key"; case "wifi": "Wi-Fi"; default: "Item" }
    }
    public var symbol: String {
        switch kind { case "login": "key.fill"; case "note": "note.text"; case "alias": "at";
        case "credit_card": "creditcard"; case "identity": "person.text.rectangle";
        case "ssh_key": "terminal"; case "wifi": "wifi"; default: "doc.text" }
    }
}

/// The desktop ranks limited TOTP access by creation time across active logins.
/// A missing capability record or incomplete metadata must not imply unlimited access.
public struct PassCapabilities: Decodable, Sendable {
    public let totpLimit: Int?
    public let customFieldsAllowed: Bool
    enum CodingKeys: String, CodingKey { case totpLimit = "totp_limit"; case customFieldsAllowed = "custom_fields_allowed" }
    public init(totpLimit: Int?, customFieldsAllowed: Bool = false) { self.totpLimit = totpLimit; self.customFieldsAllowed = customFieldsAllowed }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.totpLimit) else { throw ProtonXError.invalidResponse }
        customFieldsAllowed = try values.decodeIfPresent(Bool.self, forKey: .customFieldsAllowed) ?? false
        totpLimit = try values.decodeIfPresent(Int.self, forKey: .totpLimit)
        guard totpLimit == nil || (0...65535).contains(totpLimit!) else { throw ProtonXError.invalidResponse }
    }
    public func allowsTOTPSetup(itemID: String?, items: [PassItem]) -> Bool {
        guard let limit = totpLimit else { return true }
        let logins = items.filter { $0.kind == "login" }
        guard logins.allSatisfy({ $0.hasTOTP != nil }) else { return false }
        if let itemID, logins.contains(where: { $0.id == itemID && $0.hasTOTP == true }) {
            return allowsTOTP(itemID: itemID, items: items)
        }
        return logins.filter { $0.hasTOTP == true }.count < limit
    }
    public func allowsTOTP(itemID: String, items: [PassItem]) -> Bool {
        guard let limit = totpLimit else { return true }
        guard limit > 0 else { return false }
        let logins = items.filter { $0.kind == "login" }
        guard logins.allSatisfy({ $0.hasTOTP != nil }) else { return false }
        let ranked = logins.enumerated().filter { $0.element.hasTOTP == true }
        guard ranked.allSatisfy({ $0.element.createdAt?.isEmpty == false }) else { return false }
        return ranked.sorted {
            if $0.element.createdAt == $1.element.createdAt { return $0.offset < $1.offset }
            return $0.element.createdAt! < $1.element.createdAt!
        }.prefix(limit).contains { $0.element.id == itemID }
    }
}

public struct SecretField: Identifiable, Equatable, Sendable {
    public let label: String
    public let value: String
    public let concealed: Bool
    public var id: String { label }
    public init(label: String, value: String, concealed: Bool = true) { self.label = label; self.value = value; self.concealed = concealed }
}

/// Decodes the upstream serde representation; unsupported structures are never dumped into the UI or logs.
public struct ItemDetail: Sendable {
    public let title: String
    public let revision: UInt64?
    public let note: String
    public let fields: [SecretField]
    public let urls: [String]
    public let hasTOTP: Bool
    public let attachmentCount: Int
    public let offlineAttachmentsUnavailable: Bool
    public let passkeyCount: Int
    public let editableCustomFields: [CustomFieldDraft]
    public let unsupportedCustomFieldCount: Int
    public init(title: String, note: String, fields: [SecretField], revision: UInt64? = nil, urls: [String] = [], hasTOTP: Bool = false, attachmentCount: Int = 0, offlineAttachmentsUnavailable: Bool = false, passkeyCount: Int = 0, editableCustomFields: [CustomFieldDraft] = [], unsupportedCustomFieldCount: Int = 0) {
        self.revision = revision
        self.offlineAttachmentsUnavailable = offlineAttachmentsUnavailable
        self.editableCustomFields = editableCustomFields; self.unsupportedCustomFieldCount = unsupportedCustomFieldCount
        self.passkeyCount = passkeyCount
        self.title = title; self.note = note; self.fields = fields; self.urls = urls; self.hasTOTP = hasTOTP; self.attachmentCount = attachmentCount
    }
    public static func decode(_ data: Data) throws -> ItemDetail {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = root["item"] as? [String: Any], let content = item["content"] as? [String: Any],
              let title = content["title"] as? String, let variants = content["content"] as? [String: Any],
              let variant = variants.first, variants.count == 1 else { throw ProtonXError.invalidResponse }
        let value = variant.value as? [String: Any] ?? [:]
        let labels: [(String, String, Bool)] = [
            ("email", "Email", false), ("username", "Username", false), ("password", "Password", true),
            ("cardholder_name", "Cardholder", false), ("number", "Card number", true), ("verification_number", "Security code", true),
            ("expiration_date", "Expiry", false), ("ssid", "Network", false), ("private_key", "Private key", true),
            ("public_key", "Public key", false), ("pin", "PIN", true)]
        var seen = Set<String>()
        var fields = labels.compactMap { key, label, concealed -> SecretField? in
            guard seen.insert(key).inserted, let string = value[key] as? String, !string.isEmpty else { return nil }
            return SecretField(label: label, value: string, concealed: concealed)
        }
        if let alias = item["alias_email"] as? String, !alias.isEmpty { fields.append(SecretField(label: "Alias", value: alias, concealed: false)) }
        if variant.key == "Identity" {
            for key in value.keys.sorted() where !seen.contains(key) {
                if let text = value[key] as? String, !text.isEmpty {
                    fields.append(SecretField(label: key.replacingOccurrences(of: "_", with: " ").capitalized, value: text))
                }
            }
        }
        func appendExtra(_ extras: [[String: Any]], prefix: String) {
            for extra in extras {
                guard let name = extra["name"] as? String, let values = extra["content"] as? [String: Any],
                      let first = values.first, ["Text", "Hidden"].contains(first.key), let string = first.value as? String else { continue }
                fields.append(SecretField(label: prefix + name, value: string, concealed: first.key != "Text"))
            }
        }
        let extras = content["extra_fields"] as? [[String: Any]] ?? []
        let editableExtras = extras.enumerated().compactMap { index, extra -> CustomFieldDraft? in
            guard let name = extra["name"] as? String, let values = extra["content"] as? [String: Any], values.count == 1,
                  let first = values.first, ["Text", "Hidden"].contains(first.key), let text = first.value as? String else { return nil }
            return CustomFieldDraft(sourceIndex: index, name: name, value: text, concealed: first.key == "Hidden")
        }
        appendExtra(extras, prefix: "Custom: ")
        for key in ["extra_personal_details", "extra_address_details", "extra_contact_details", "extra_work_details"] {
            appendExtra(value[key] as? [[String: Any]] ?? [], prefix: key.replacingOccurrences(of: "_", with: " ").capitalized + ": ")
        }
        for section in (value["sections"] as? [[String: Any]] ?? []) + (value["extra_sections"] as? [[String: Any]] ?? []) {
            appendExtra(section["section_fields"] as? [[String: Any]] ?? [], prefix: (section["section_name"] as? String ?? "Custom") + ": ")
        }
        struct Revision: Decodable { let revision: UInt64? }
        let revision = try JSONDecoder().decode(Revision.self, from: data).revision
        let modernURLs = (value["autofill_urls"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
        let allURLs = (value["urls"] as? [String] ?? []) + modernURLs
        var uniqueURLs = Set<String>()
        return ItemDetail(title: title, note: content["note"] as? String ?? "", fields: fields, revision: revision,
                          urls: allURLs.filter { uniqueURLs.insert($0).inserted }, hasTOTP: !(value["totp_uri"] as? String ?? "").isEmpty,
                          attachmentCount: (root["attachments"] as? [Any])?.count ?? 0, offlineAttachmentsUnavailable: root["offline_attachments_unavailable"] as? Bool ?? false, passkeyCount: (value["passkeys"] as? [Any])?.count ?? 0,
                          editableCustomFields: editableExtras, unsupportedCustomFieldCount: extras.count - editableExtras.count)
    }
}

public struct LoginDraft: Codable, Sendable {
    public var title: String = ""
    public var username: String = ""
    public var email: String = ""
    public var password: String = ""
    public var urls: [String] = []
    public init() {}
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProtonXError.invalidInput("Give the item a title.") }
        guard urls.allSatisfy({ URLPolicy.webURL($0) != nil }) else { throw ProtonXError.invalidInput("Website addresses must use https:// or http://.") }
    }
}

public enum HelperFailure: String, Codable, Sendable {
    case eligibility, authentication, network, tls, sessionInvalidated, interactiveUnsupported, conflict, cacheUnavailable, operation
}
public struct HelperDiagnostic: Codable, Equatable, Sendable {
    public let failure: HelperFailure
    public let httpStatus: Int?
    public let apiCode: Int?
    public var message: String {
        let explanation: String
        switch failure {
        case .eligibility: explanation = "Proton authenticated this account, but it is not eligible for Proton Pass CLI access. ProtonX currently uses that client."
        case .authentication: explanation = "Proton could not complete authentication. Check your sign-in details and any required verification method."
        case .network: explanation = "The Proton client could not connect to Proton. Check your connection and try again."
        case .tls: explanation = "The Proton client could not verify its secure connection. Certificate verification remains enabled."
        case .sessionInvalidated: explanation = "Proton invalidated this session. Sign in again."
        case .interactiveUnsupported: explanation = "This account requires a sign-in method that ProtonX’s native login does not yet support."
        case .conflict: explanation = "This item changed in another client. Reopen it before editing; your changes have not been applied."
        case .cacheUnavailable: explanation = "This saved vault has expired or changed. Refresh online to continue."
        case .operation: explanation = "The Proton client could not complete this operation."
        }
        var codes: [String] = []
        if let httpStatus, (100...599).contains(httpStatus) { codes.append("HTTP \(httpStatus)") }
        if let apiCode, (0...Int(Int32.max)).contains(apiCode) { codes.append("API \(apiCode)") }
        return explanation + (codes.isEmpty ? "" : " (" + codes.joined(separator: ", ") + ")")
    }
}

public enum ProtonXError: Error, LocalizedError, Equatable, Sendable {
    case helperMissing, invalidResponse, cancelled, timeout, outputTooLarge
    case helperFailed(Int32), helperDiagnostic(HelperDiagnostic), invalidInput(String)
    public var errorDescription: String? {
        switch self {
        case .helperMissing: "The Proton Pass helper is missing. Build the app with scripts/build-app.sh."
        case .invalidResponse: "The Proton client returned an unsupported response."
        case .cancelled: "The operation was cancelled."
        case .timeout: "The Proton client did not respond in time. Try again."
        case .outputTooLarge: "The Proton client response exceeded the size limit."
        case .helperFailed: "The Proton client could not complete this operation. Check your connection and sign-in status. Your existing data has not been replaced."
        case .helperDiagnostic(let diagnostic): diagnostic.message
        case .invalidInput(let text): text
        }
    }
}

public enum URLPolicy {
    /// This URL carries a single-use fork secret. Never log or expose it in an error.
    public static func authenticationURL(_ value: String) -> URL? {
        guard value.utf8.count < 8192, let components = URLComponents(string: value),
              components.scheme == "https", components.host == "account.proton.me",
              components.port == nil, components.user == nil, components.password == nil,
              components.path == "/desktop/login", components.queryItems == [URLQueryItem(name: "app", value: "pass")],
              let fragment = components.fragment, fragment.hasPrefix("payload="), fragment.count > 8 else { return nil }
        return components.url
    }
    public static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

public enum ItemSort: String, CaseIterable, Sendable { case title = "Name", recentlyModified = "Recently changed" }

public enum ItemSearch {
    public static func matches(_ item: PassItem, query: String, vaultID: String? = nil, kind: String? = nil) -> Bool {
        matches(item, words: query.split(whereSeparator: \.isWhitespace).map(String.init), vaultID: vaultID, kind: kind)
    }
    private static func matches(_ item: PassItem, words: [String], vaultID: String?, kind: String?) -> Bool {
        (vaultID == nil || item.shareID == vaultID) && (kind == nil || item.kind == kind) &&
        words.allSatisfy { item.title.localizedStandardContains($0) }
    }
    public static func filter(_ items: [PassItem], query: String, vaultID: String? = nil, kind: String? = nil, sort: ItemSort = .title) -> [PassItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { matches($0, words: words, vaultID: vaultID, kind: kind) }.sorted {
            if sort == .recentlyModified, $0.modifiedAt != $1.modifiedAt { return ($0.modifiedAt ?? "") > ($1.modifiedAt ?? "") }
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}
