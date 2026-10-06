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
    await #expect(throws: ProtonXError.timeout) { try await NativeProcess(executable: executable, directory: root, timeout: .milliseconds(100)).run(HelperCommand([]), challenge: nil) }
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

@Test func nativeFailureReportsStageAndCodesWithoutRawServerText() async throws {
    let (root, executable) = try fixture("printf 'SYNTHETIC-private-server-error\\n' >&2\nprintf 'PROTONX_ERROR:{\"failure\":\"authentication\",\"httpStatus\":401,\"apiCode\":8002}\\n' >&2\nexit 1\n")
    defer { try? FileManager.default.removeItem(at: root) }
    do { _ = try await NativeProcess(executable: executable, directory: root).run(HelperCommand([])); Issue.record("Expected failure") }
    catch {
        #expect(error.localizedDescription.contains("HTTP 401"))
        #expect(error.localizedDescription.contains("API 8002"))
        #expect(!error.localizedDescription.contains("SYNTHETIC-private"))
    }
}
@Test func nativeEligibilityFailureIsDistinctFromBadCredentials() async throws {
    let (root, executable) = try fixture("printf 'PROTONX_ERROR:{\"failure\":\"eligibility\"}\\n' >&2\nexit 1\n")
    defer { try? FileManager.default.removeItem(at: root) }
    do { _ = try await NativeProcess(executable: executable, directory: root).run(HelperCommand([])); Issue.record("Expected failure") }
    catch { #expect(error.localizedDescription.contains("not eligible")); #expect(!error.localizedDescription.contains("Check your sign-in details")) }
}

@Test func authenticationForkURLTravelsThroughPrivateChallengePipe() async throws {
    let url = "https://account.proton.me/desktop/login?app=pass#payload=SYNTHETIC-SECRET"
    let record = String(decoding: try JSONEncoder().encode(AuthChallenge(prompt: "Complete Proton sign-in", secure: false, url: url)), as: UTF8.self)
    let (root, executable) = try fixture("printf '%s\\n' 'PROTONX:\(record)' >&2\nIFS= read -r answer\nprintf '%s' \"$answer\"\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try await NativeProcess(executable: executable, directory: root).run(HelperCommand(["login"])) { challenge in
        #expect(challenge.url == url)
        #expect(URLPolicy.authenticationURL(challenge.url!) != nil)
        return "started"
    }
    #expect(try JSONDecoder().decode(String.self, from: result) == "started")
}

@Test func authenticationOnlyOpensPinnedAccountDestination() {
    #expect(URLPolicy.authenticationURL("https://account.proton.me/desktop/login?app=pass#payload=SYNTHETIC") != nil)
    for value in [
        "https://account.proton.me.evil.invalid/desktop/login?app=pass#payload=SYNTHETIC",
        "http://account.proton.me/desktop/login?app=pass#payload=SYNTHETIC",
        "https://user:secret@account.proton.me/desktop/login?app=pass#payload=SYNTHETIC",
        "https://account.proton.me:8443/desktop/login?app=pass#payload=SYNTHETIC",
        "https://account.proton.me/desktop/login?app=pass&redirectUrl=https://evil.invalid#payload=SYNTHETIC",
        "https://account.proton.me/desktop/login?app=mail#payload=SYNTHETIC",
        "https://account.proton.me/desktop/login?app=pass",
    ] { #expect(URLPolicy.authenticationURL(value) == nil) }
}

@Test(arguments: [false, true]) func failedHelperCommandAllowsFreshProcessWithoutAutomaticWriteRetry(_ write: Bool) async throws {
    let snapshot = #"{"vaults":[],"items":[],"trashed_items":[],"capabilities":{"totp_limit":null}}"#
    let script = """
    if [ ! -f "$PROTON_PASS_SESSION_DIR/attempted" ]; then
        /usr/bin/touch "$PROTON_PASS_SESSION_DIR/attempted"
        if [ "$1" = native-create ]; then /bin/cat >/dev/null; fi
        printf '{"partial":'
        exit 7
    fi
    if [ "$1" != native-snapshot ]; then exit 8; fi
    printf '%s' '\(snapshot)'
    """
    let (root, executable) = try fixture(script)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = PassService(runner: NativeProcess(executable: executable, directory: root))
    do {
        if write {
            var draft = NativeItemDraft(); draft.kind = "note"; draft.title = "Synthetic"
            _ = try await service.create(draft, vault: Vault(name: "Synthetic", vaultID: "v", shareID: "s", canCreate: true))
        } else { _ = try await service.snapshot() }
        Issue.record("The first child process must fail")
    } catch { #expect(error as? ProtonXError == .helperFailed(7)) }
    let snapshotResult = try await service.snapshot()
    #expect(snapshotResult.items.isEmpty); #expect(snapshotResult.vaults.isEmpty)
}

@Test func exitedHelperCancelsPendingPromptBeforeFreshRequest() async throws {
    let script = """
    if [ "$1" = login ]; then
        printf 'PROTONX:{"prompt":"Enter password: ","secure":true}\\n' >&2
        /bin/sleep 0.1
        exit 7
    fi
    printf 'fresh'
    """
    let (root, executable) = try fixture(script)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = NativeProcess(executable: executable, directory: root)
    let start = ContinuousClock.now
    await #expect(throws: Error.self) {
        try await runner.run(HelperCommand(["login"])) { _ in
            try await Task.sleep(for: .seconds(30))
            return "UNREACHABLE"
        }
    }
    #expect(start.duration(to: .now) < .seconds(5))
    #expect(try await runner.run(HelperCommand(["fresh"]), challenge: nil) == Data("fresh".utf8))
}
