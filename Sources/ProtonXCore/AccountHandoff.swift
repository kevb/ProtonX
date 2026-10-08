// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One-use, in-memory account handoff over private helper pipes. This contains
/// a derived key-unlock secret, never a parent access/refresh token or password.
public struct AccountHandoff: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let selector: String
    public let accountID: String
    public let keyPassHex: String
    public let expires: Int64
    public var description: String { "AccountHandoff(redacted)" }
    public var debugDescription: String { description }
    public init(selector: String, accountID: String, keyPassHex: String, expires: Int64) {
        self.selector = selector; self.accountID = accountID; self.keyPassHex = keyPassHex; self.expires = expires
    }
    public func validate(now: Date = Date()) throws {
        let current = Int64(now.timeIntervalSince1970)
        let identifiers = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_=-".utf8)
        guard (1...512).contains(selector.utf8.count), selector.utf8.allSatisfy({ identifiers.contains($0) }),
              (1...128).contains(accountID.utf8.count), accountID.utf8.allSatisfy({ identifiers.contains($0) || $0 == 43 }),
              (2...8192).contains(keyPassHex.utf8.count), keyPassHex.utf8.count % 2 == 0,
              keyPassHex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              expires > current, expires <= current + 120 else { throw NativeCalendarFailure.handoffUnavailable }
    }
}
