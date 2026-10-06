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
