// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProtonXCore
@Suite struct MailSearchPolicyTests {
    @Test func searchTermsAndRepliesAreBoundedAndBackwardCompatible() throws {
        #expect(MailSearchPolicy.valid("synthetic résumé"))
        for query in ["", "  ", "invoice\nBCC", String(repeating: "é", count: 129)] { #expect(!MailSearchPolicy.valid(query)) }
        let old = Data(#"{"schema":1,"id":1,"result":{"folder":1,"messages":[]}}"#.utf8)
        #expect(try NativeMailProcess.decode(old, expectedID: 1).searchQuery == nil)
        let invalid = Data(#"{"schema":1,"id":1,"result":{"searchQuery":"synthetic","messages":[]}}"#.utf8)
        #expect(throws: ProtonXError.invalidResponse) { try NativeMailProcess.decode(invalid, expectedID: 1) }
        let command = try JSONEncoder().encode(NativeMailCommand("snapshot", more: false, keywords: "synthetic"))
        let fields = try JSONSerialization.jsonObject(with: command) as! [String: Any]
        #expect(fields["keywords"] as? String == "synthetic" && fields["folder"] == nil)
    }
}
