// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProtonXCore

@Test func mailNotificationProtocolRejectsUnboundedAndSecretBearingRoutingPayloads() throws {
    func decode(_ result: NativeMailResult) throws -> NativeMailResult {
        struct Reply: Encodable { let schema = 1; let id: UInt64 = 1; let result: NativeMailResult }
        return try NativeMailProcess.decode(JSONEncoder().encode(Reply(result: result)), expectedID: 1)
    }
    let good = NativeMailNotification(id: 1, folder: 2, sender: "Synthetic", subject: "Synthetic")
    #expect(try decode(.init(notifications: [good], unreadCount: 7)).notifications == [good])
    // Unicode joiners in legitimate names and emoji are format characters, not
    // control characters. Match Rust's sanitization without breaking the session.
    let unicode = NativeMailNotification(id: 3, folder: 2, sender: "Synthetic 👩‍💻", subject: "Family 👨‍👩‍👧‍👦")
    #expect(try decode(.init(notifications: [unicode], unreadCount: 7)).notifications == [unicode])
    for result in [NativeMailResult(notifications: [good]), .init(notifications: [good, good], unreadCount: 0),
                   .init(notifications: (1...65).map { .init(id: UInt64($0), folder: 2, sender: "Synthetic", subject: "Synthetic") }, unreadCount: 0),
                   .init(notifications: [.init(id: 0, folder: 2, sender: "Synthetic", subject: "Synthetic")], unreadCount: 0),
                   .init(notifications: [.init(id: 1, folder: 0, sender: "Synthetic", subject: "Synthetic")], unreadCount: 0),
                   .init(notifications: [.init(id: 1, folder: 2, sender: "bad\nvalue", subject: "Synthetic")], unreadCount: 0),
                   .init(notifications: [.init(id: 1, folder: 2, sender: "Synthetic", subject: String(repeating: "x", count: 999))], unreadCount: 0),
                   .init(notifications: [], unreadCount: UInt64.max)] {
        #expect(throws: (any Error).self) { try decode(result) }
    }
}
