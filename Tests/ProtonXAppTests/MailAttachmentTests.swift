import AppKit
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private actor AttachmentGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if open { return }; await withCheckedContinuation { continuation = $0 } }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
private final class AttachmentRunner: NativeMailRunning, @unchecked Sendable {
    struct Step: Sendable { let method: String; let result: NativeMailResult; var gate: AttachmentGate?; var failure: NativeMailFailure? }
    private let lock = NSLock(); private var steps: [Step]; private var history: [NativeMailCommand] = []
    init(_ steps: [Step]) { self.steps = steps }
    var calls: [NativeMailCommand] { lock.withLock { history } }
    func cancelAll() {}
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        let step = lock.withLock { history.append(command); return steps.isEmpty ? nil : steps.removeFirst() }
        guard let step else { throw ProtonXError.invalidResponse }
        #expect(step.method == command.method)
        if let gate = step.gate { await gate.wait() }
        if let failure = step.failure { throw failure }; return step.result
    }
}
private let attachmentFixture = NativeMailAttachment(id: 21, name: "Synthetic.txt", size: 4, mime: "text/plain")
private let attachmentSnapshot = NativeMailResult(folders: [.init(id: 1, name: "Inbox")], folder: 1, messages: [.init(id: 11, subject: "Synthetic attachment", sender: "demo@example.com", attachments: 1)], loading: false, email: "demo@example.com")
@MainActor private func waitAttachment(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), .now < deadline { await Task.yield() }
    #expect(condition())
}
@MainActor private func attachmentStore(_ runner: AttachmentRunner) -> NativeMailStore {
    let name = "ProtonXAttachmentTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!; defaults.set(true, forKey: "nativeMailConnected")
    let store = NativeMailStore(runner: runner, defaults: defaults, localUnlock: { true }); defaults.removePersistentDomain(forName: name); return store
}
@Test @MainActor func downloadsExactBytesAndCleansPreviewOnLock() async throws {
    let runner = AttachmentRunner([
        .init(method:"restore",result:.init(phase:.connected)), .init(method:"snapshot",result:attachmentSnapshot),
        .init(method:"message",result:.init(id:11,body:"Synthetic",attachmentList:[attachmentFixture])),
        .init(method:"attachment_download",result:.init(transfer:.init(token:7,size:4,offset:0))),
        .init(method:"attachment_chunk",result:.init(transfer:.init(token:7,size:4,offset:4,data:"00ff0102",done:true))),
        .init(method:"transfer_cancel",result:.init(closed:true))
    ])
    let store = attachmentStore(runner); store.unlock(); await waitAttachment { !store.busy }
    store.selectedItem = 11; store.select(); await waitAttachment { !store.attachmentList.isEmpty }
    store.downloadAttachment(attachmentFixture, action:.preview); await waitAttachment { !store.attachmentBusy }
    let preview = try #require(store.attachmentPreview)
    #expect(try Data(contentsOf:preview.url) == Data([0,255,1,2]))
    await waitAttachment { runner.calls.count == 6 }
    store.lock(); #expect(store.attachmentPreview == nil); #expect(!FileManager.default.fileExists(atPath:preview.url.path)); #expect(store.attachmentList.isEmpty)
}
@Test @MainActor func lateDownloadCannotExportOrRestartHelperAfterLock() async {
    let gate = AttachmentGate()
    let runner = AttachmentRunner([
        .init(method:"restore",result:.init(phase:.connected)), .init(method:"snapshot",result:attachmentSnapshot),
        .init(method:"message",result:.init(id:11,body:"Synthetic",attachmentList:[attachmentFixture])),
        .init(method:"attachment_download",result:.init(transfer:.init(token:7,size:4,offset:0)),gate:gate)
    ])
    let store = attachmentStore(runner); store.unlock(); await waitAttachment { !store.busy }
    store.selectedItem = 11; store.select(); await waitAttachment { !store.attachmentList.isEmpty }
    store.downloadAttachment(attachmentFixture,action:.preview); await waitAttachment { runner.calls.count == 4 }
    store.lock(); await gate.release(); for _ in 0..<100 { await Task.yield() }
    #expect(store.attachmentPreview == nil); #expect(!store.attachmentBusy); #expect(runner.calls.count == 4)
}
@Test @MainActor func composingCancelsReaderDownloadWithoutPublishingLatePreview() async {
    let gate = AttachmentGate()
    let draft = NativeMailDraft(token:3,sender:"demo@example.com",senders:["demo@example.com"])
    let runner = AttachmentRunner([
        .init(method:"restore",result:.init(phase:.connected)), .init(method:"snapshot",result:attachmentSnapshot),
        .init(method:"message",result:.init(id:11,body:"Synthetic",attachmentList:[attachmentFixture])),
        .init(method:"attachment_download",result:.init(transfer:.init(token:7,size:4,offset:0)),gate:gate),
        .init(method:"compose",result:.init(draft:draft)),
        .init(method:"transfer_cancel",result:.init(closed:true))
    ])
    let store = attachmentStore(runner); store.unlock(); await waitAttachment { !store.busy }
    store.selectedItem = 11; store.select(); await waitAttachment { !store.attachmentList.isEmpty }
    store.downloadAttachment(attachmentFixture,action:.preview); await waitAttachment { runner.calls.count == 4 }
    store.compose(); await waitAttachment { !store.busy }; await gate.release(); await waitAttachment { runner.calls.count == 6 }
    #expect(store.attachmentPreview == nil); #expect(!store.attachmentBusy); #expect(store.draft?.token == 3)
    #expect(!runner.calls.contains { $0.method == "attachment_chunk" }); store.lock()
}
@Test @MainActor func invalidDownloadOffsetCannotPublishFile() async {
    let runner = AttachmentRunner([
        .init(method:"restore",result:.init(phase:.connected)), .init(method:"snapshot",result:attachmentSnapshot),
        .init(method:"message",result:.init(id:11,body:"Synthetic",attachmentList:[attachmentFixture])),
        .init(method:"attachment_download",result:.init(transfer:.init(token:7,size:4,offset:0))),
        .init(method:"attachment_chunk",result:.init(transfer:.init(token:7,size:4,offset:3,data:"00ff0102",done:true))),
        .init(method:"transfer_cancel",result:.init(closed:true))
    ])
    let store = attachmentStore(runner); store.unlock(); await waitAttachment { !store.busy }; store.selectedItem = 11; store.select(); await waitAttachment { !store.attachmentList.isEmpty }
    store.downloadAttachment(attachmentFixture,action:.preview); await waitAttachment { !store.attachmentBusy }
    #expect(store.attachmentPreview == nil); #expect(store.attachmentError != nil); store.lock()
}
@Test @MainActor func uploadKeepsUnsentTextAndDoesNotRetryAmbiguousFinish() async throws {
    let original = NativeMailDraft(token:3,sender:"demo@example.com",senders:["demo@example.com"],text:"Saved synthetic",attachmentList:[])
    let runner = AttachmentRunner([
        .init(method:"restore",result:.init(phase:.connected)), .init(method:"snapshot",result:attachmentSnapshot),
        .init(method:"compose",result:.init(draft:original)),
        .init(method:"upload_start",result:.init(transfer:.init(token:8,size:4,offset:0))),
        .init(method:"upload_chunk",result:.init(transfer:.init(token:8,size:4,offset:4))),
        .init(method:"upload_finish",result:.init(),failure:.attachmentFailed),
        .init(method:"transfer_cancel",result:.init(closed:true))
    ])
    let store = attachmentStore(runner); store.unlock(); await waitAttachment { !store.busy }; store.compose(); await waitAttachment { !store.busy }
    store.editorState?.text = "Unsaved synthetic edits"
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false); defer { try? FileManager.default.removeItem(at:dir) }
    let url = dir.appendingPathComponent("Synthetic.txt"); try Data([0,255,1,2]).write(to:url)
    store.addDraftAttachments([url]); await waitAttachment { !store.attachmentBusy }; await waitAttachment { runner.calls.count == 7 }
    #expect(store.editorState?.text == "Unsaved synthetic edits"); #expect(store.attachmentError != nil); #expect(store.attachmentNeedsRefresh)
    let before = runner.calls.count; store.addDraftAttachments([url]); for _ in 0..<100 { await Task.yield() }; #expect(runner.calls.count == before)
    #expect(runner.calls.filter { $0.method == "upload_finish" }.count == 1)
    #expect(runner.calls.first { $0.method == "upload_chunk" }?.data == "00ff0102")
    store.lock()
}
@Test @MainActor func multiChunkUploadRefreshAndRemovalPreserveEditorAndGateSend() async throws {
    let bytes = Data(repeating: 0xa7, count: MailAttachmentPolicy.chunkBytes + 3)
    let original = NativeMailDraft(token:3,sender:"demo@example.com",senders:["demo@example.com"],attachmentList:[])
    var pending = original
    pending.attachmentList = [.init(id:21,name:"Synthetic.bin",size:UInt64(bytes.count),state:.uploading)]
    var ready = original
    ready.attachmentList = [.init(id:21,name:"Synthetic.bin",size:UInt64(bytes.count),state:.uploaded)]
    let runner = AttachmentRunner([
        .init(method:"restore",result:.init(phase:.connected)), .init(method:"snapshot",result:attachmentSnapshot),
        .init(method:"compose",result:.init(draft:original)),
        .init(method:"upload_start",result:.init(transfer:.init(token:8,size:bytes.count,offset:0))),
        .init(method:"upload_chunk",result:.init(transfer:.init(token:8,size:bytes.count,offset:MailAttachmentPolicy.chunkBytes))),
        .init(method:"upload_chunk",result:.init(transfer:.init(token:8,size:bytes.count,offset:bytes.count))),
        .init(method:"upload_finish",result:.init(draft:pending)),
        .init(method:"draft_attachments",result:.init(draft:ready)),
        .init(method:"remove_attachment",result:.init(draft:original))
    ])
    let store = attachmentStore(runner); store.unlock(); await waitAttachment { !store.busy }; store.compose(); await waitAttachment { !store.busy }
    store.editorState?.text = "Unsent local changes"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bin")
    try bytes.write(to:url); defer { try? FileManager.default.removeItem(at:url) }
    store.addDraftAttachments([url]); await waitAttachment { !store.attachmentBusy }
    #expect(store.draft?.attachmentList?.first?.state == .uploading)
    store.sendDraft(.init(sender:"demo@example.com",to:["recipient@example.com"],text:"Synthetic"))
    #expect(!runner.calls.contains { $0.method == "send_draft" }); #expect(store.draft?.state == .editing)
    let chunks = runner.calls.filter { $0.method == "upload_chunk" }
    #expect(chunks.map(\.offset) == [0,MailAttachmentPolicy.chunkBytes])
    #expect(chunks.compactMap { $0.data.flatMap(MailAttachmentPolicy.decode) }.reduce(Data(),+) == bytes)
    store.refreshDraftAttachments(); await waitAttachment { !store.busy }
    #expect(store.draft?.attachmentList?.first?.state == .uploaded); #expect(store.editorState?.text == "Unsent local changes")
    store.removeDraftAttachment(21); await waitAttachment { !store.busy }
    #expect(store.draft?.attachmentList?.isEmpty == true); #expect(store.editorState?.text == "Unsent local changes")
    #expect(runner.calls.last?.attachment == 21); #expect(runner.calls.last?.token == 3); store.lock()
}
@Test func chosenFilesRefuseSymlinksAndPrivateExportsAreQuarantined() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false); defer { try? FileManager.default.removeItem(at:directory) }
    let original = directory.appendingPathComponent("original.txt"), link = directory.appendingPathComponent("link.txt")
    try Data("SYNTHETIC".utf8).write(to:original); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:original)
    #expect(throws: NativeMailFailure.self) { try MailAttachmentFiles.readUpload(link) }
    let file = directory.appendingPathComponent("export.txt"); try MailAttachmentFiles.writePrivate(Data("SYNTHETIC".utf8),to:file)
    let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(getxattr(file.path,"com.apple.quarantine",nil,0,0,0) > 0)
    #expect(!MailAttachmentFiles.canPreview("run.command")); #expect(!MailAttachmentFiles.canPreview("page.html")); #expect(MailAttachmentFiles.canPreview("document.pdf"))
    try MailAttachmentFiles.save(Data("REPLACED SYNTHETIC".utf8),to:link)
    #expect(try Data(contentsOf:original) == Data("SYNTHETIC".utf8)); #expect(try Data(contentsOf:link) == Data("REPLACED SYNTHETIC".utf8))
}
