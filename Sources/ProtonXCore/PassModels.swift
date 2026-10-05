import Foundation

public struct Vault: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let vaultID: String
    public let shareID: String
    public var id: String { shareID }
    enum CodingKeys: String, CodingKey { case name; case vaultID = "vault_id"; case shareID = "share_id" }
    public init(name: String, vaultID: String, shareID: String) { self.name = name; self.vaultID = vaultID; self.shareID = shareID }
}

public struct PassItem: Codable, Identifiable, Hashable, Sendable {
    public let itemID: String
    public let shareID: String
    public let title: String
    public let kind: String
    public var id: String { shareID + ":" + itemID }
    enum CodingKeys: String, CodingKey { case itemID = "id"; case shareID = "share_id"; case title; case kind = "item_type" }
    public init(itemID: String, shareID: String, title: String, kind: String) {
        self.itemID = itemID; self.shareID = shareID; self.title = title; self.kind = kind
    }
    public var symbol: String {
        switch kind { case "login": "key.fill"; case "note": "note.text"; case "alias": "at";
        case "credit_card": "creditcard"; case "identity": "person.text.rectangle";
        case "ssh_key": "terminal"; case "wifi": "wifi"; default: "doc.text" }
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
    public let note: String
    public let fields: [SecretField]
    public let urls: [String]
    public let hasTOTP: Bool
    public let attachmentCount: Int
    public init(title: String, note: String, fields: [SecretField], urls: [String] = [], hasTOTP: Bool = false, attachmentCount: Int = 0) {
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
            ("public_key", "Public key", false), ("email", "Alias", false)]
        var seen = Set<String>()
        var fields = labels.compactMap { key, label, concealed -> SecretField? in
            guard seen.insert(key).inserted, let string = value[key] as? String, !string.isEmpty else { return nil }
            return SecretField(label: label, value: string, concealed: concealed)
        }
        for extra in content["extra_fields"] as? [[String: Any]] ?? [] {
            guard let name = extra["name"] as? String, let values = extra["content"] as? [String: Any],
                  let first = values.first, let string = first.value as? String else { continue }
            fields.append(SecretField(label: "Custom: " + name, value: string, concealed: first.key != "Text"))
        }
        return ItemDetail(title: title, note: content["note"] as? String ?? "", fields: fields,
                          urls: value["urls"] as? [String] ?? [], hasTOTP: !(value["totp_uri"] as? String ?? "").isEmpty,
                          attachmentCount: (root["attachments"] as? [Any])?.count ?? 0)
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

public enum ProtonXError: Error, LocalizedError, Equatable, Sendable {
    case helperMissing, invalidResponse, cancelled, timeout, outputTooLarge
    case helperFailed(Int32), invalidInput(String)
    public var errorDescription: String? {
        switch self {
        case .helperMissing: "The Proton Pass helper is missing. Build the app with scripts/build-app.sh."
        case .invalidResponse: "The Proton client returned an unsupported response."
        case .cancelled: "The operation was cancelled."
        case .timeout: "The Proton client did not respond in time. Try again."
        case .outputTooLarge: "The Proton client response exceeded the size limit."
        case .helperFailed: "The Proton client could not complete this operation. Check your connection, credentials, and CLI plan eligibility. Your existing data has not been replaced."
        case .invalidInput(let text): text
        }
    }
}

public enum URLPolicy {
    public static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

public enum ItemSearch {
    public static func filter(_ items: [PassItem], query: String, vaultID: String? = nil, kind: String? = nil) -> [PassItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            (vaultID == nil || item.shareID == vaultID) && (kind == nil || item.kind == kind) &&
            words.allSatisfy { item.title.localizedStandardContains($0) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
