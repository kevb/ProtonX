// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import ProtonXCore

/// SDK identity determines grouping, even when a custom folder is named Inbox.
struct MailSidebarSections {
    let primary: [NativeMailFolder]
    let more: [NativeMailFolder]
    let folders: [NativeMailFolder]
    let labels: [NativeMailFolder]
    init(_ all: [NativeMailFolder]) {
        let kinds: [NativeMailFolderKind] = [.inbox, .drafts, .sent, .starred]
        labels = all.filter { $0.isLabel == true }
        folders = all.filter { $0.isCustom == true && $0.isLabel != true }
        primary = kinds.flatMap { kind in all.filter { $0.isCustom != true && $0.isLabel != true && $0.kind == kind } }
        let ids = Set(primary.map(\.id) + folders.map(\.id) + labels.map(\.id))
        more = all.filter { !ids.contains($0.id) }
    }
}
