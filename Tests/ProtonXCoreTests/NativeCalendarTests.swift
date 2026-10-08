// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProtonXCore

@Suite struct NativeCalendarTests {
    let range = CalendarQueryRange(start: Date(timeIntervalSince1970: 1791417600), end: Date(timeIntervalSince1970: 1792022400), timeZoneID: "UTC")
    @Test func closedCommandsAndRangeBounds() throws {
        for method in ["create","update","delete","export","host_override"] {
            #expect(throws: Error.self) { try NativeCalendarCommand(method) }
        }
        #expect(throws: Error.self) { try NativeCalendarCommand("restore", password: "synthetic") }
        #expect(throws: Error.self) { try NativeCalendarCommand("totp", code: "invalid") }
        #expect(throws: Error.self) { try NativeCalendarCommand("snapshot", range: .init(start: .distantPast, end: .distantFuture, timeZoneID: "UTC")) }
        #expect(throws: Error.self) { try NativeCalendarCommand("snapshot", range: .init(start: Date(timeIntervalSince1970: .infinity), end: .now, timeZoneID: "UTC")) }
        let login = try NativeCalendarCommand("login", username: "synthetic@example.com", password: "synthetic-password")
        let json = try #require(String(data: JSONEncoder().encode(login), encoding: .utf8))
        #expect(json.contains("synthetic-password") && !json.contains("range"))
    }
    @Test func replyRejectsUnknownFailuresFramingAndMixedReplies() throws {
        for reply in [
            #"{"schema":2,"id":1,"result":{"phase":"connected"}}"#,
            #"{"schema":1,"id":2,"result":{"phase":"connected"}}"#,
            #"{"schema":1,"id":1,"result":{"phase":"connected"},"failure":"operation_failed"}"#,
            #"{"schema":1,"id":1,"failure":"SYNTHETIC-raw-server-secret"}"#,
            #"{"schema":1,"id":1,"result":{"phase":"arbitrary"}}"#
        ] { #expect(throws: Error.self) { try NativeCalendarProcess.decode(Data(reply.utf8), expectedID: 1) } }
        #expect(throws: NativeCalendarFailure.sessionExpired) { try NativeCalendarProcess.decode(Data(#"{"schema":1,"id":1,"failure":"session_expired"}"#.utf8), expectedID: 1) }
    }
    func reply(start: Int64 = 1791417600, event: String) -> Data {
        Data("{\"schema\":1,\"id\":1,\"result\":{\"phase\":\"connected\",\"start\":\(start),\"end\":1792022400,\"calendars\":[{\"id\":\"cal\",\"name\":\"Synthetic calendar\",\"color\":0}],\"events\":[\(event)]}}".utf8)
    }
    let event = #"{"id":"occurrence","calendarID":"cal","title":"Synthetic repeated event","location":"Synthetic room","notes":"Synthetic notes","start":1791453600,"end":1791457200,"zone":"UTC","allDay":false,"recurring":true}"#
    @Test func validatesRangeIdentityRecurrenceAndWrongCalendars() throws {
        let decoded = try NativeCalendarProcess.decode(reply(event: event), expectedID: 1)
        let snapshot = try decoded.snapshot(for: range)
        #expect(snapshot.events.count == 1 && snapshot.events[0].recurring)
        #expect(throws: Error.self) { try NativeCalendarProcess.decode(reply(start: 1, event: event), expectedID: 1).snapshot(for: range) }
        #expect(throws: Error.self) { try NativeCalendarProcess.decode(reply(event: event.replacingOccurrences(of: #""calendarID":"cal""#, with: #""calendarID":"other""#)), expectedID: 1).snapshot(for: range) }
        #expect(throws: Error.self) { try NativeCalendarProcess.decode(reply(event: event.replacingOccurrences(of: "1791453600", with: "1792453600").replacingOccurrences(of: "1791457200", with: "1792457200")), expectedID: 1).snapshot(for: range) }
    }
    @Test func liveSourceHasNoWritePath() async throws {
        let runner = CalendarRejectingRunner()
        let source = NativeCalendarDataSource(runner: runner)
        let r = CalendarEventRecord(id: "synthetic", calendarID: "cal", title: "Synthetic", time: .timed(start: .now, end: .now.addingTimeInterval(60), timeZoneID: "UTC"))
        await #expect(throws: NativeCalendarFailure.readOnly) { try await source.save(r, expectedRevision: nil) }
        await #expect(throws: NativeCalendarFailure.readOnly) { try await source.delete(id: r.id, expectedRevision: 0) }
        #expect(await runner.requests == 0)
    }
}
private actor CalendarRejectingRunner: NativeCalendarRunning {
    private(set) var requests = 0
    func request(_ command: NativeCalendarCommand) throws -> NativeCalendarResult { requests += 1; throw NativeCalendarFailure.operationFailed }
    nonisolated func cancelAll() {}
}

@Suite struct NativeCalendarPipeTests {
    @Test func credentialsChallengesAndEmptyAccountStayOnPrivatePipe() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarPipe." + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("synthetic-helper.sh")
        let program = #"""
        #!/bin/sh
        set -eu
        [ "$#" -eq 0 ]
        [ -n "$PROTONX_CALENDAR_DIR" ]
        [ -z "${SYNTHETIC_CALENDAR_SECRET+x}" ]
        IFS= read -r login
        case "$login" in *'"password":"synthetic-password"'*) ;; *) exit 1 ;; esac
        case "$login" in *'"method":"login"'*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"schema":1,"id":1,"result":{"phase":"totp"}}'
        IFS= read -r totp
        case "$totp" in *'"code":"123456"'*) ;; *) exit 1 ;; esac
        case "$totp" in *'"method":"totp"'*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"schema":1,"id":2,"result":{"phase":"connected"}}'
        IFS= read -r snapshot
        case "$snapshot" in *'"start":1791417600'*) ;; *) exit 1 ;; esac
        case "$snapshot" in *'"end":1792022400'*) ;; *) exit 1 ;; esac
        case "$snapshot" in *'"method":"snapshot"'*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"schema":1,"id":3,"result":{"phase":"connected","start":1791417600,"end":1792022400,"calendars":[],"events":[]}}'
        """#
        try Data(program.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = NativeCalendarProcess(executable: script, directory: dir.appendingPathComponent("profile"))
        defer { runner.cancelAll() }
        #expect(try await runner.request(NativeCalendarCommand("login", username: "synthetic@example.com", password: "synthetic-password")).phase == "totp")
        #expect(try await runner.request(NativeCalendarCommand("totp", code: "123456")).phase == "connected")
        let range = CalendarQueryRange(start: Date(timeIntervalSince1970:1791417600), end: Date(timeIntervalSince1970:1792022400), timeZoneID:"UTC")
        let snapshot = try await NativeCalendarDataSource(runner:runner).snapshot(in:range)
        #expect(snapshot.calendars.isEmpty && snapshot.events.isEmpty)
    }
    @Test func allDayWireRequiresExactCivilDateBounds() throws {
        let range = CalendarQueryRange(start: Date(timeIntervalSince1970:1791417600), end: Date(timeIntervalSince1970:1792022400), timeZoneID:"UTC")
        let event = #"{"id":"day","calendarID":"cal","title":"Synthetic","location":"","notes":"","start":1791417600,"end":1791504000,"zone":"UTC","allDay":true,"recurring":false,"startDay":{"year":2026,"month":10,"day":8},"endDay":{"year":2026,"month":10,"day":9}}"#
        let f = NativeCalendarTests()
        #expect(try NativeCalendarProcess.decode(f.reply(event:event), expectedID:1).snapshot(for:range).events.count == 1)
        #expect(throws: Error.self) { try NativeCalendarProcess.decode(f.reply(event:event.replacingOccurrences(of:"1791417600",with:"1791417601")),expectedID:1).snapshot(for:range) }
    }
}
