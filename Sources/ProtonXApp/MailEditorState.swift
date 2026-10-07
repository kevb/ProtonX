// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import ProtonXCore

/// Unsaved contents belong to the Mail session, never shared navigation defaults.
/// A tab switch retains this model; lock, sign-out and draft close release it.
@MainActor final class MailEditorState: ObservableObject {
    let token: UInt64
    @Published var sender: String
    @Published var to: String
    @Published var cc: String
    @Published var bcc: String
    @Published var subject: String
    @Published var text: String
    @Published var expandedRecipients: Bool
    init(draft: NativeMailDraft) {
        token = draft.token; sender = draft.sender
        to = draft.to.joined(separator: ", "); cc = draft.cc.joined(separator: ", "); bcc = draft.bcc.joined(separator: ", ")
        subject = draft.subject; text = draft.text
        expandedRecipients = !draft.cc.isEmpty || !draft.bcc.isEmpty
    }
    var content: NativeMailComposeContent {
        .init(sender: sender, to: NativeMailComposeContent.parseRecipients(to), cc: NativeMailComposeContent.parseRecipients(cc),
              bcc: NativeMailComposeContent.parseRecipients(bcc), subject: subject, text: text)
    }
}
