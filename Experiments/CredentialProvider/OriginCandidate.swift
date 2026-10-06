import Foundation

/// Conservative candidate filter for the feasibility probe, not a production autofill matcher.
/// HTTPS only, exact host and port. It never authorizes credential disclosure.
struct OriginCandidate: Equatable {
    let host: String
    let port: Int
    init?(url: String) {
        guard let value = URLComponents(string: url), value.scheme?.lowercased() == "https",
              value.user == nil, value.password == nil, let raw = value.host else { return nil }
        let host = raw.lowercased().hasSuffix(".") ? String(raw.lowercased().dropLast()) : raw.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, !labels.isEmpty,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }),
              (1...65535).contains(value.port ?? 443) else { return nil }
        self.host = host; port = value.port ?? 443
    }
    init?(domain: String) {
        guard !domain.contains(":"), !domain.contains("/"), !domain.contains("@"), !domain.contains("?"), !domain.contains("#") else { return nil }
        self.init(url: "https://" + domain)
    }
    static func matches(savedURL: String, requestedURL: String) -> Bool {
        guard let saved = OriginCandidate(url: savedURL), let requested = OriginCandidate(url: requestedURL) else { return false }
        return saved == requested
    }
}
