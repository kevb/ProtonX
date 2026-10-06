import Foundation

@main enum OriginTests {
    static func main() {
        let cases: [(String, String, Bool)] = [
            ("https://example.com/account", "https://example.com/login", true),
            ("https://EXAMPLE.com", "https://example.com:443", true),
            ("https://example.com.", "https://example.com", true),
            ("https://example.com", "https://example.com.evil.invalid", false),
            ("https://example.com", "https://evil-example.com", false),
            ("https://example.com", "https://sub.example.com", false),
            ("https://example.com", "https://example.com:8443", false),
            ("https://example.com", "http://example.com", false),
            ("https://example.com", "https://example.com@evil.invalid", false),
            ("https://example.com", "file:///example.com", false),
            ("https://example.com", "https://example..com", false),
            ("https://example.com", "https://example.com:0", false),
            ("https://example.com", "https://exаmple.com", false), // Cyrillic a
            ("https://example.com", "https://example.com%2Fevil.invalid", false)
        ]
        for (saved, requested, expected) in cases {
            precondition(OriginCandidate.matches(savedURL: saved, requestedURL: requested) == expected, "Synthetic origin case failed")
        }
        for domain in ["example.com/path", "example.com:443", "user@example.com", "example.com?x=y", "example..com"] {
            precondition(OriginCandidate(domain: domain) == nil)
        }
        precondition(OriginCandidate(domain: "example.com") == OriginCandidate(url: "https://example.com"))
        print("20 synthetic origin candidate cases passed; no credential disclosure implemented.")
    }
}
