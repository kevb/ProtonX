import Foundation
import Testing
@testable import ProtonXCore

private func mailFixture(_ script: String) throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonXMailTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("synthetic-mail")
    try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return (root, executable)
}

@Test func mailReplyMustBelongToCurrentRequestAndSchema() throws {
    for reply in [
        #"{"schema":2,"id":7,"result":{"phase":"connected"}}"#,
        #"{"schema":1,"id":6,"result":{"phase":"connected"}}"#,
        #"{"schema":1,"id":7,"result":{},"failure":"session_expired"}"#,
        #"{"schema":1,"id":7}"#,
        #"{"schema":1,"id":7,"failure":"SYNTHETIC-private-server-text"}"#
    ] {
        #expect(throws: Error.self) { try NativeMailProcess.decode(Data(reply.utf8), expectedID: 7) }
    }
    let reply = try NativeMailProcess.decode(Data(#"{"schema":1,"id":7,"result":{"phase":"totp"}}"#.utf8), expectedID: 7)
    #expect(reply.phase == .totp)
}

@Test func mailRepliesBoundContentAndRejectDuplicateItems() throws {
    let item = NativeMailMessage(id: 11, subject: "Synthetic", sender: "demo@example.com")
    struct Packet: Encodable { let schema = 1; let id = 1; let result: NativeMailResult }
    for result in [NativeMailResult(messages: [item, item]), NativeMailResult(messages: Array(repeating: item, count: 1001)), NativeMailResult(body: String(repeating: "x", count: 2 * 1024 * 1024 + 1))] {
        let packet = try JSONEncoder().encode(Packet(result: result))
        #expect(throws: ProtonXError.invalidResponse) { try NativeMailProcess.decode(packet, expectedID: 1) }
    }
    #expect(throws: ProtonXError.outputTooLarge) { try NativeMailProcess.decode(Data(repeating: 65, count: 8 * 1024 * 1024 + 1), expectedID: 1) }
}

@Test func mailCredentialsUseStdinAndTypedChallengeFailureKeepsProcessAlive() async throws {
    let (root, executable) = try mailFixture("""
    [ "$#" = 0 ] || exit 9
    [ -z "$PROTONX_PASSWORD" ] || exit 10
    [ -z "$HTTP_PROXY" ] || exit 11
    IFS= read -r request
    case "$request" in *SYNTHETIC-password*) ;; *) exit 12 ;; esac
    printf '%s\n' '{"schema":1,"id":1,"result":{"phase":"totp"}}'
    IFS= read -r request
    printf '%s\n' '{"schema":1,"id":2,"failure":"incorrect_code"}'
    IFS= read -r request
    printf '%s\n' '{"schema":1,"id":3,"result":{"phase":"connected"}}'
    IFS= read -r request
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = NativeMailProcess(executable: executable, directory: root)
    defer { runner.cancelAll() }
    #expect(try await runner.request(NativeMailCommand("login", username: "demo@example.com", password: "SYNTHETIC-password")).phase == .totp)
    await #expect(throws: NativeMailFailure.incorrectCode) { try await runner.request(NativeMailCommand("totp", code: "000000")) }
    #expect(try await runner.request(NativeMailCommand("totp", code: "123456")).phase == .connected)
}

@Test func mailLockStopsBlockedProcessAndQueuedCredentials() async throws {
    let (root, executable) = try mailFixture("exec /bin/sleep 30\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = NativeMailProcess(executable: executable, directory: root)
    let first = Task { try await runner.request(NativeMailCommand("restore")) }
    try await Task.sleep(for: .milliseconds(100))
    let queued = Task { try await runner.request(NativeMailCommand("login", username: "demo@example.com", password: "SYNTHETIC")) }
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    runner.cancelAll()
    await #expect(throws: Error.self) { try await first.value }
    await #expect(throws: Error.self) { try await queued.value }
    #expect(start.duration(to: .now) < .seconds(3))
}

@Test func mailDeadlineAndPartialEOFDoNotExposeRawOutput() async throws {
    for script in ["exec /bin/sleep 30\n", "printf 'SYNTHETIC-private-error' >&2\nprintf '{partial'\n"] {
        let (root, executable) = try mailFixture(script)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NativeMailProcess(executable: executable, directory: root, deadline: .milliseconds(100))
        let start = ContinuousClock.now
        do { _ = try await runner.request(NativeMailCommand("restore")); Issue.record("Expected failure") }
        catch { #expect(!error.localizedDescription.contains("SYNTHETIC-private")) }
        #expect(start.duration(to: .now) < .seconds(3))
    }
}

@Test func cancelledMailSelectionDoesNotDestroyFollowingRequest() async throws {
    let (root, executable) = try mailFixture("""
    IFS= read -r request
    /bin/sleep 0.15
    printf '%s\n' '{"schema":1,"id":1,"result":{"id":11,"body":"SYNTHETIC first"}}'
    IFS= read -r request
    printf '%s\n' '{"schema":1,"id":2,"result":{"id":12,"body":"SYNTHETIC second"}}'
    IFS= read -r request
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = NativeMailProcess(executable: executable, directory: root)
    defer { runner.cancelAll() }
    let old = Task { try await runner.request(NativeMailCommand("message", folder: 1, item: 11)) }
    try await Task.sleep(for: .milliseconds(70))
    old.cancel()
    let current = Task { try await runner.request(NativeMailCommand("message", folder: 1, item: 12)) }
    await #expect(throws: CancellationError.self) { try await old.value }
    #expect(try await current.value.body == "SYNTHETIC second")
}

@Test func nativeMailComposerValidatesTheAuthoritativeSenderAndEnvelope() throws {
    let senders = ["alex@example.com", "alex.demo@gmail.com"]
    var content = NativeMailComposeContent(sender: senders[1], to: ["sam@example.com"], cc: ["team@example.com"], subject: "Synthetic café", text: "First line\n.second line")
    try content.validate(senders: senders, sending: true)
    content.sender = "unconnected@gmail.com"
    #expect(throws: NativeMailFailure.invalidInput) { try content.validate(senders: senders, sending: true) }
    content.sender = senders[1]; content.bcc = ["SAM@example.com"]
    #expect(throws: NativeMailFailure.invalidInput) { try content.validate(senders: senders, sending: true) }
    content.bcc = []; content.subject = "Hello\r\nBcc: hidden@example.com"
    #expect(throws: NativeMailFailure.invalidInput) { try content.validate(senders: senders, sending: true) }
    content.subject = "Synthetic"; content.to = []; content.cc = []
    try content.validate(senders: senders, sending: false)
    #expect(throws: NativeMailFailure.invalidInput) { try content.validate(senders: senders, sending: true) }
    content.text = String(repeating: "\u{0001}", count: 32 * 1024)
    #expect(throws: NativeMailFailure.invalidInput) { try content.validate(senders: senders, sending: false) }
    #expect(NativeMailComposeContent.parseRecipients("sam@example.com; team@example.com, ") == ["sam@example.com", "team@example.com"])
}

@Test func nativeMailComposerRejectsUntrustedHelperSenderAndSendState() throws {
    struct Packet: Encodable { let schema = 1; let id = 1; let result: NativeMailResult }
    let draft = NativeMailDraft(token: 1, sender: "unconnected@gmail.com", senders: ["alex@example.com"])
    #expect(throws: Error.self) { try NativeMailProcess.decode(JSONEncoder().encode(Packet(result: .init(draft: draft))), expectedID: 1) }
    #expect(throws: Error.self) { try NativeMailProcess.decode(Data(#"{"schema":1,"id":1,"result":{"token":1,"sendState":"SYNTHETIC-raw-error"}}"#.utf8), expectedID: 1) }
}

@Test func nativeMailSendPayloadIsPrivateStdinWithNoRecipientOrBodyArguments() async throws {
    let (root, executable) = try mailFixture("""
    [ "$#" = 0 ] || exit 9
    [ -z "$PROTONX_PASSWORD" ] || exit 10
    IFS= read -r request
    case "$request" in *alex.demo@gmail.com*) ;; *) exit 12 ;; esac
    case "$request" in *SYNTHETIC-private-body*) ;; *) exit 13 ;; esac
    printf '%s\n' '{"schema":1,"id":1,"result":{"token":3,"sendState":"queued"}}'
    IFS= read -r request
    printf '%s\n' '{"schema":1,"id":2,"result":{"token":3,"sendState":"sent"}}'
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = NativeMailProcess(executable: executable, directory: root)
    defer { runner.cancelAll() }
    let content = NativeMailComposeContent(sender: "alex.demo@gmail.com", to: ["sam@example.com"], text: "SYNTHETIC-private-body")
    #expect(try await runner.request(.init("send_draft", token: 3, content: content)).sendState == .queued)
    #expect(try await runner.request(.init("draft_status", token: 3)).sendState == .sent)
}

@Test func mailFreshnessCannotContradictLoadingOrFailedRefresh() throws {
    for flags in [#""fresh":true,"loading":true"#, #""fresh":true,"refreshFailed":true"#] {
        let reply = "{\"schema\":1,\"id\":1,\"result\":{\(flags)}}"
        #expect(throws: ProtonXError.invalidResponse) { try NativeMailProcess.decode(Data(reply.utf8), expectedID: 1) }
    }
    let saved = try NativeMailProcess.decode(Data(#"{"schema":1,"id":1,"result":{"fresh":false,"refreshFailed":true}}"#.utf8), expectedID: 1)
    #expect(saved.fresh == false); #expect(saved.refreshFailed == true)
}

@Test func mailStorageRecoveryFailuresRemainTypedAndDoNotRecommendSigningInAgain() {
    for failure in [NativeMailFailure.storageMigrationPending, .storageVersionUnsupported] {
        let packet = "{\"schema\":1,\"id\":7,\"failure\":\"\(failure.rawValue)\"}"
        #expect(throws: failure) { try NativeMailProcess.decode(Data(packet.utf8), expectedID: 7) }
        #expect(failure.localizedDescription.contains("retained"))
        #expect(!failure.localizedDescription.contains("sign in"))
    }
}
