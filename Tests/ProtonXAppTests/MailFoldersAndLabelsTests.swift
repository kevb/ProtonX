// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@Suite("MailFoldersAndLabelsTests")
@MainActor
struct MailFoldersAndLabelsTests {
    @Test func customFoldersExcludesCurrentFolderAndLabels() async throws {
        let folders = [
            NativeMailFolder(id: 1, name: "Inbox", count: 1, kind: .inbox, isCustom: false, isLabel: false),
            NativeMailFolder(id: 20, name: "Work", count: 0, kind: .other, isCustom: true, isLabel: false),
            NativeMailFolder(id: 21, name: "Finance", count: 0, kind: .other, isCustom: true, isLabel: false),
            NativeMailFolder(id: 30, name: "Receipts", count: 0, kind: .other, isCustom: true, isLabel: true),
        ]
        let message = NativeMailMessage(id: 101, subject: "Invoice", sender: "billing@example.invalid", unread: false, conversationID: 77)
        let labels = [
            NativeMailLabelOption(id: 30, name: "Receipts", state: .unselected),
            NativeMailLabelOption(id: 31, name: "Important", state: .selected),
        ]
        let runner = FolderLabelFakeRunner(folders: folders, message: message, labels: labels)
        let store = NativeMailStore(runner: runner, defaults: UserDefaults(suiteName: "ProtonX.FoldersLabels.\(UUID().uuidString)")!)
        store.signIn(username: "alice@example.invalid", password: "synthetic-password")
        try await waitFor { store.phase == .open && !store.messages.isEmpty }
        store.selectedItem = 101; store.select()
        try await waitFor { store.body != nil }

        #expect(store.customFolders.map(\.id) == [20, 21])
        #expect(store.customLabels.map(\.id) == [30])
        #expect(store.messageLabels == labels)

        store.toggleSelectedMessageLabel(labels[0])
        try await waitFor { !store.busy }
        let labelCmd = await runner.lastCommand(method: "toggle_label")
        #expect(labelCmd?.folder == 1)
        #expect(labelCmd?.item == 101)
        #expect(labelCmd?.label == 30)
        #expect(labelCmd?.apply == true)
        #expect(store.undoToken == 9)

        store.moveSelectedMessage(toFolder: folders[1])
        try await waitFor { !store.busy }
        let moveCmd = await runner.lastCommand(method: "move_to_folder")
        #expect(moveCmd?.folder == 1)
        #expect(moveCmd?.item == 101)
        #expect(moveCmd?.conversation == nil)
        #expect(moveCmd?.target == 20)
        #expect(store.undoToken == 10)
    }

    @Test func listMoveDispatchesConversationIDAndRejectsUnknownTarget() async throws {
        let folders = [
            NativeMailFolder(id: 1, name: "Inbox", count: 1, kind: .inbox, isCustom: false, isLabel: false),
            NativeMailFolder(id: 20, name: "Work", count: 0, kind: .other, isCustom: true, isLabel: false),
        ]
        let message = NativeMailMessage(id: 101, subject: "Thread", sender: "bob@example.invalid", unread: false, conversationID: 88)
        let runner = FolderLabelFakeRunner(folders: folders, message: message, labels: [])
        let store = NativeMailStore(runner: runner, defaults: UserDefaults(suiteName: "ProtonX.FoldersLabelsList.\(UUID().uuidString)")!)
        store.signIn(username: "alice@example.invalid", password: "synthetic-password")
        try await waitFor { store.phase == .open && !store.messages.isEmpty }

        // Unknown custom folder is ignored before IPC.
        let forged = NativeMailFolder(id: 999, name: "Forged", count: 0, kind: .other, isCustom: true, isLabel: false)
        store.moveListItem(101, toFolder: forged)
        #expect(await runner.lastCommand(method: "move_to_folder") == nil)

        store.moveListItem(101, toFolder: folders[1])
        try await waitFor { !store.busy }
        let moveCmd = await runner.lastCommand(method: "move_to_folder")
        #expect(moveCmd?.item == 101)
        #expect(moveCmd?.conversation == 88)
        #expect(moveCmd?.target == 20)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        Issue.record("Condition timed out")
    }
}

private actor FolderLabelFakeRunner: NativeMailRunning {
    let folders: [NativeMailFolder]
    let message: NativeMailMessage
    let labels: [NativeMailLabelOption]
    private var commands: [NativeMailCommand] = []
    private var nextUndo: UInt64 = 9
    init(folders: [NativeMailFolder], message: NativeMailMessage, labels: [NativeMailLabelOption]) {
        self.folders = folders; self.message = message; self.labels = labels
    }
    nonisolated func cancelAll() {}
    func lastCommand(method: String) -> NativeMailCommand? {
        commands.last { $0.method == method }
    }
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        commands.append(command)
        switch command.method {
        case "login":
            return NativeMailResult(phase: .connected, email: "alice@example.invalid")
        case "snapshot":
            return NativeMailResult(folders: folders, folder: 1, messages: [message], loading: false, email: "alice@example.invalid", fresh: true)
        case "thread":
            return NativeMailResult(thread: NativeMailThread(anchor: message.id, conversationID: message.conversationID ?? 1, messages: [message]))
        case "message":
            return NativeMailResult(id: message.id, body: "Invoice body", attachments: 0, actions: [.archive, .trash], labels: labels)
        case "move_to_folder", "toggle_label":
            let token = nextUndo; nextUndo += 1
            return NativeMailResult(id: command.item, queued: true, undoToken: token, conversationID: command.conversation)
        default:
            return NativeMailResult()
        }
    }
}
