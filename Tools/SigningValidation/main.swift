// Synthetic Keychain ACL regression probe. Never reads production services.
import Foundation
import Security

SecKeychainSetUserInteractionAllowed(false)
let service = "org.kevb.ProtonX.Testing.Signing"
guard CommandLine.arguments.count == 3, CommandLine.arguments[2].hasPrefix("synthetic-signature-regression-") else { exit(5) }
let account = CommandLine.arguments[2]
let value = Data("SYNTHETIC-NOT-A-CREDENTIAL".utf8)
let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
    kSecAttrAccount: account, kSecAttrSynchronizable: false]
#if PROTONX_SIGNING_SECOND
let revision = 2
#else
let revision = 1
#endif
switch CommandLine.arguments.dropFirst().first {
case "create":
    var add = query; add[kSecValueData] = value
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { exit(1) }
case "read", "refuse":
    var read = query; read[kSecReturnData] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &result)
    if CommandLine.arguments[1] == "refuse" {
        guard status == errSecInteractionNotAllowed || status == errSecAuthFailed else { exit(2) }
    } else { guard status == errSecSuccess, result as? Data == value else { print("Synthetic read refused with OSStatus \(status)"); exit(3) } }
case "remove":
    guard SecItemDelete(query as CFDictionary) == errSecSuccess else { exit(4) }
default: exit(5)
}
print("Synthetic signing probe revision \(revision) passed")
