import Foundation
import Security

/// Generation checks prevent late async results from repopulating a locked or signed-out window.
public struct SessionEpoch: Sendable {
    public private(set) var value: UInt64 = 0
    public init() {}
    public mutating func invalidate() { value &+= 1 }
    public func accepts(_ captured: UInt64) -> Bool { captured == value }
}

public struct ClipboardLease: Equatable, Sendable {
    public let changeCount: Int
    public init(changeCount: Int) { self.changeCount = changeCount }
    public func owns(currentChangeCount: Int) -> Bool { currentChangeCount == changeCount }
}

public enum PasswordGenerator {
    // Rejection sampling via SecRandomCopyBytes, not modulo-biased arithmetic or a new crypto primitive.
    public static func generate(length: Int = 24) throws -> String {
        guard (12...128).contains(length) else { throw ProtonXError.invalidInput("Use a password length from 12 to 128.") }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%&*-_+".utf8)
        let limit = 256 - (256 % alphabet.count)
        var result: [UInt8] = []
        while result.count < length {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { throw ProtonXError.invalidResponse }
            if Int(byte) < limit { result.append(alphabet[Int(byte) % alphabet.count]) }
        }
        return String(decoding: result, as: UTF8.self)
    }
}

public final class KeychainStore: Sendable {
    private let service: String
    public init(service: String = "org.kevb.ProtonX") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    public func save(_ data: Data, account: String) throws {
        let query = query(account)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
    public func load(account: String) throws -> Data? {
        var query = query(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }
    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? { "Keychain access failed (\(status)). Unlock your login keychain and try again." }
}
