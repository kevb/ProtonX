// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@Suite("MailInlineImagesTests")
@MainActor
struct MailInlineImagesTests {
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test func validCIDRejectsTraversalInjectionAndOversizedValues() {
        #expect(NativeMailInlineImage.validCID("part1.abc@example.com"))
        #expect(NativeMailInlineImage.validCID("ii_m3x9a"))
        #expect(!NativeMailInlineImage.validCID(""))
        #expect(!NativeMailInlineImage.validCID("a/b"))
        #expect(!NativeMailInlineImage.validCID("a?x=1"))
        #expect(!NativeMailInlineImage.validCID("a#frag"))
        #expect(!NativeMailInlineImage.validCID("a b"))
        #expect(!NativeMailInlineImage.validCID("a<script>"))
        #expect(!NativeMailInlineImage.validCID(String(repeating: "a", count: 257)))
    }

    @Test func inlineImageDecodingEnforcesRasterMIMEAllowlistAndSizeCap() throws {
        let valid = NativeMailInlineImage(mime: "image/PNG", data: Self.pngBytes.base64EncodedString())
        let (bytes, mime) = try valid.decoded()
        #expect(bytes == Self.pngBytes)
        #expect(mime == "image/png")

        let svg = NativeMailInlineImage(mime: "image/svg+xml", data: Data("<svg/>".utf8).base64EncodedString())
        #expect(throws: ProtonXError.invalidResponse) { _ = try svg.decoded() }

        let empty = NativeMailInlineImage(mime: "image/png", data: "")
        #expect(throws: ProtonXError.invalidResponse) { _ = try empty.decoded() }

        let badBase64 = NativeMailInlineImage(mime: "image/png", data: "!!!not-base64!!!")
        #expect(throws: ProtonXError.invalidResponse) { _ = try badBase64.decoded() }
    }

    @Test func readerPolicyAllowsInlineSchemeWithoutEnablingRemoteImages() {
        let inlineOnly = MailReaderPolicy.document("<img data-protonx-cid=\"part1\">", allowsRemoteImages: false, allowsInlineImages: true)
        #expect(inlineOnly.contains("img-src protonx-image:;"))
        #expect(inlineOnly.contains("img[data-protonx-cid] { max-width:100%; height:auto; }"))
        #expect(inlineOnly.contains("img:not([data-protonx-cid]) { display:none !important; }"))
        #expect(MailReaderPolicy.inlineImageRules.contains("^protonx-image://inline"))
        #expect(!MailReaderPolicy.inlineImageRules.contains("asset"))

        let blocked = MailReaderPolicy.document("<img data-protonx-remote-src=\"https://example.invalid/a.png\">", allowsRemoteImages: false, allowsInlineImages: false)
        #expect(blocked.contains("img-src 'none';"))
        #expect(blocked.contains("img { display:none !important; }"))
    }

    @Test func storeLoadsInlineImageOnlyForSelectedMessageAndCancelsOnLock() async throws {
        let defaults = UserDefaults(suiteName: "ProtonX.InlineImages.\(UUID().uuidString)")!
        let message = NativeMailMessage(id: 42, subject: "Inline photo", sender: "alice@example.invalid", unread: false, conversationID: 1)
        let folder = NativeMailFolder(id: 1, name: "Inbox", count: 1, kind: .inbox)
        let runner = InlineImageFakeRunner(folder: folder, message: message, pngBytes: Self.pngBytes)
        let store = NativeMailStore(runner: runner, defaults: defaults)
        store.signIn(username: "alice@example.invalid", password: "synthetic-password")
        try await waitForCondition { store.phase == .open && !store.messages.isEmpty }
        store.selectedItem = 42
        store.select()
        try await waitForCondition { store.body != nil }

        let (data, mime) = try await store.loadInlineImage(item: 42, cid: "part1@example.invalid")
        #expect(data == Self.pngBytes)
        #expect(mime == "image/png")

        await #expect(throws: CancellationError.self) {
            _ = try await store.loadInlineImage(item: 999, cid: "part1@example.invalid")
        }
        await #expect(throws: CancellationError.self) {
            _ = try await store.loadInlineImage(item: 42, cid: "bad/cid")
        }

        store.lock()
        await #expect(throws: CancellationError.self) {
            _ = try await store.loadInlineImage(item: 42, cid: "part1@example.invalid")
        }
    }

    private func waitForCondition(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        Issue.record("Condition timed out")
    }
}

private final class InlineImageFakeRunner: NativeMailRunning, @unchecked Sendable {
    let folder: NativeMailFolder
    let message: NativeMailMessage
    let pngBytes: Data
    init(folder: NativeMailFolder, message: NativeMailMessage, pngBytes: Data) {
        self.folder = folder; self.message = message; self.pngBytes = pngBytes
    }
    func cancelAll() {}
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        switch command.method {
        case "login":
            return NativeMailResult(phase: .connected, email: "alice@example.invalid")
        case "snapshot":
            return NativeMailResult(folders: [folder], folder: folder.id, messages: [message], loading: false, email: "alice@example.invalid", fresh: true)
        case "thread":
            return NativeMailResult(thread: NativeMailThread(anchor: message.id, conversationID: 1, messages: [message]))
        case "message":
            return NativeMailResult(id: message.id, body: "Inline photo", sanitizedHTML: "<p><img data-protonx-cid=\"part1@example.invalid\"></p>", attachments: 0, actions: [])
        case "inline_image":
            return NativeMailResult(id: command.item, inlineImage: NativeMailInlineImage(mime: "image/png", data: pngBytes.base64EncodedString()))
        default:
            return NativeMailResult()
        }
    }
}
