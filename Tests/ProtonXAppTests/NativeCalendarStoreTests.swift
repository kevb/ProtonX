// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private actor CalendarRunnerFixture: NativeCalendarRunning {
    private(set) var calls: [String] = []
    private(set) var ranges: [(Int64,Int64)] = []
    var challenge: String?
    var fail: NativeCalendarFailure?
    private var held: CheckedContinuation<Void,Never>?
    var hold = false
    func configure(challenge: String? = nil, fail: NativeCalendarFailure? = nil, hold: Bool = false) { self.challenge = challenge; self.fail = fail; self.hold = hold }
    func release() { held?.resume(); held = nil }
    func request(_ command: NativeCalendarCommand) async throws -> NativeCalendarResult {
        calls.append(command.method)
        if hold { await withCheckedContinuation { held = $0 }; hold = false }
        if let fail { throw fail }
        if command.method == "snapshot" {
            let start = command.start!, end = command.end!; ranges.append((start,end))
            let data = Data("{\"schema\":1,\"id\":1,\"result\":{\"phase\":\"connected\",\"start\":\(start),\"end\":\(end),\"calendars\":[{\"id\":\"synthetic-cal\",\"name\":\"Synthetic calendar\",\"color\":0}],\"events\":[{\"id\":\"synthetic-event\",\"calendarID\":\"synthetic-cal\",\"title\":\"Synthetic event\",\"location\":\"\",\"notes\":\"\",\"start\":\(start+3600),\"end\":\(start+7200),\"zone\":\"UTC\",\"allDay\":false,\"recurring\":true}]}}".utf8)
            return try NativeCalendarProcess.decode(data, expectedID: 1)
        }
        if command.method == "login", let challenge { return .init(phase: challenge) }
        return .init(phase: command.method == "sign_out" ? "welcome" : "connected")
    }
    nonisolated func cancelAll() {}
}
@Suite @MainActor struct NativeCalendarStoreTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "NativeCalendarTests." + UUID().uuidString)! }
    func wait(_ test: () async -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await test()) && ContinuousClock.now < limit { try await Task.sleep(for:.milliseconds(10)) }
        #expect(await test())
    }
    private func store(_ runner: CalendarRunnerFixture, defaults: UserDefaults? = nil, preview: Bool = false, unlock: @escaping @MainActor @Sendable () async throws -> Bool = { true }) -> CalendarStore {
        CalendarStore(previewOnly: preview, now: { Date(timeIntervalSince1970:1791453600) }, runner: runner, defaults: defaults ?? self.defaults(), localUnlock: unlock)
    }
    @Test func liveSignInChallengesReadOnlyAndLock() async throws {
        let runner = CalendarRunnerFixture(); await runner.configure(challenge:"totp")
        let d = defaults(), s = store(runner,defaults:d)
        #expect(await runner.calls.isEmpty)
        s.signIn(username:"synthetic@example.com",password:"synthetic-password");try await wait { !s.busy }
        #expect(s.phase == .totp)
        s.submitChallenge("123456");try await wait { !s.busy }
        #expect(s.phase == .connected && s.events.count == 1 && !s.canEdit && d.bool(forKey:"nativeCalendarConnected"))
        s.beginEvent();#expect(s.editor == nil)
        s.select(s.events[0]);#expect(s.deleteIntent() == nil)
        s.lock();#expect(s.phase == .locked && s.events.isEmpty)
        s.unlock();try await wait { !s.busy }
        #expect(s.phase == .connected && s.events.count == 1)
        s.signOut();try await wait { !s.busy };#expect(s.phase == .welcome && !d.bool(forKey:"nativeCalendarConnected"))
        #expect(await runner.calls == ["login","totp","snapshot","restore","snapshot","sign_out"])
    }
    @Test func cancelledLocalUnlockDoesNotReadKeychainOrHelper() async throws {
        let runner = CalendarRunnerFixture(), d = defaults();d.set(true,forKey:"nativeCalendarConnected")
        let s = store(runner,defaults:d,unlock:{ false });s.unlock();try await wait { !s.busy }
        #expect(await runner.calls.isEmpty);#expect(s.phase == .locked && s.events.isEmpty)
    }
    @Test func previewCannotSignInOrRestore() async throws {
        let runner = CalendarRunnerFixture(), s = store(runner,preview:true);try await wait { !s.busy }
        s.signIn(username:"synthetic@example.com",password:"synthetic");s.unlock();s.submitChallenge("123456")
        #expect(await runner.calls.isEmpty && s.phase == .preview)
    }
    @Test func navigationLoadsNewRangeAndRetainsMailState() async throws {
        let runner = CalendarRunnerFixture(), s = store(runner)
        s.signIn(username:"synthetic@example.com",password:"synthetic");try await wait { !s.busy }
        let first = await runner.ranges.count
        s.mode = .month;try await wait { await runner.ranges.count > first && !s.busy }
        let next = await runner.ranges.count;s.navigate(1);try await wait { await runner.ranges.count > next && !s.busy }
        #expect(s.events.count == 1 && !s.canEdit)
        let workspace = SuiteWorkspace(defaults:defaults(),previewOnly:true,makeCalendar:{ s });workspace.select(.mail)
        workspace.mail?.compose();workspace.mail?.editorState?.text = "Synthetic retained draft"
        workspace.select(.calendar);workspace.select(.mail)
        #expect(workspace.mail?.editorState?.text == "Synthetic retained draft")
    }
    @Test func lateAuthenticationAndSnapshotCannotReopenLockedCalendar() async throws {
        let runner = CalendarRunnerFixture();await runner.configure(hold:true)
        let d = defaults(), s = store(runner,defaults:d)
        s.signIn(username:"synthetic@example.com",password:"synthetic");try await wait { await runner.calls.count == 1 }
        s.lock();await runner.release();for _ in 0..<20 { await Task.yield() }
        #expect(s.phase == .welcome && s.events.isEmpty && !d.bool(forKey:"nativeCalendarConnected"))
    }
    @Test func expiredSessionClearsVisibleContentsAndHints() async throws {
        let runner = CalendarRunnerFixture(), d = defaults(), s = store(runner,defaults:d)
        s.signIn(username:"synthetic@example.com",password:"synthetic");try await wait { !s.busy }
        await runner.configure(fail:.sessionExpired);s.refresh();try await wait { !s.busy }
        #expect(s.phase == .welcome && s.events.isEmpty && !d.bool(forKey:"nativeCalendarConnected"))
    }
}
