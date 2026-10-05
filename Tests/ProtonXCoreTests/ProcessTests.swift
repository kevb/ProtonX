import Foundation
import Testing
@testable import ProtonXCore

private func fixture(_ script: String) throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonXTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("fake-helper")
    try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return (root, executable)
}
@Test func nativeChallengesUsePrivatePipe() async throws {
    let (root, executable) = try fixture("printf 'PROTONX:{\"prompt\":\"Enter password: \",\"secure\":true}\\n' >&2\nIFS= read -r answer\nprintf '%s' \"$answer\"\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = NativeProcess(executable: executable, directory: root)
    let result = try await runner.run(HelperCommand(["login", "--interactive"])) { challenge in
        #expect(challenge.secure); #expect(challenge.title == "Proton password"); return "SYNTHETIC-password"
    }
    #expect(try JSONDecoder().decode(String.self, from: result) == "SYNTHETIC-password")
}
@Test func stderrIsNeverReturnedAsAnError() async throws {
    let (root, executable) = try fixture("printf 'SYNTHETIC-sensitive-error\\n' >&2\nexit 7\n")
    defer { try? FileManager.default.removeItem(at: root) }
    do { _ = try await NativeProcess(executable: executable, directory: root).run(HelperCommand([]), challenge: nil); Issue.record("Expected failure") }
    catch { #expect(!error.localizedDescription.contains("SYNTHETIC-sensitive")); #expect(error as? ProtonXError == .helperFailed(7)) }
}
@Test func helperTimeoutIsBounded() async throws {
    let (root, executable) = try fixture("exec /bin/sleep 30\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let start = ContinuousClock.now
    await #expect(throws: Error.self) { try await NativeProcess(executable: executable, directory: root, timeout: .milliseconds(100)).run(HelperCommand([]), challenge: nil) }
    #expect(start.duration(to: .now) < .seconds(5))
}
@Test func cancellationTerminatesTheHelper() async throws {
    let (root, executable) = try fixture("exec /bin/sleep 30\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = NativeProcess(executable: executable, directory: root)
    let task = Task { try await runner.run(HelperCommand([]), challenge: nil) }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    await #expect(throws: Error.self) { try await task.value }
}
@Test func templatesAreWrittenBeforeClosingStdin() async throws {
    let (root, executable) = try fixture("/bin/cat\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let input = Data(repeating: 65, count: 100_000)
    let result = try await NativeProcess(executable: executable, directory: root).run(HelperCommand([], input: input), challenge: nil)
    #expect(result == input)
}
@Test func missingHelperFailsBeforeStarting() async throws {
    await #expect(throws: ProtonXError.helperMissing) { try await NativeProcess(executable: URL(fileURLWithPath: "/nonexistent/protonx-helper"), directory: URL(fileURLWithPath: "/tmp")).run(HelperCommand([]), challenge: nil) }
}

@Test func timedOutAuthenticationCancelsPendingCredentialPrompt() async throws {
    let (root, executable) = try fixture("printf 'PROTONX:{\"prompt\":\"Enter password: \",\"secure\":true}\\n' >&2\nIFS= read -r answer\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = NativeProcess(executable: executable, directory: root, authenticationTimeout: .milliseconds(150))
    let start = ContinuousClock.now
    await #expect(throws: Error.self) {
        try await runner.run(HelperCommand(["login"])) { _ in
            try await Task.sleep(for: .seconds(30))
            return "UNREACHABLE"
        }
    }
    #expect(start.duration(to: .now) < .seconds(5))
}
