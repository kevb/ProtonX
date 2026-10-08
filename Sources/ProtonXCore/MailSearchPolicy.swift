// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
public enum MailSearchPolicy {
    public static func valid(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && query.utf8.count <= 256 &&
        !query.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
