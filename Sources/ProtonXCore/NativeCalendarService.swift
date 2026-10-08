// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public enum NativeCalendarFailure: String, Codable, Error, LocalizedError, Sendable {
    case conflict = "conflict", writeUncertain = "write_uncertain"
    case handoffUnavailable = "handoff_unavailable"
    case invalidInput = "invalid_input", invalidState = "invalid_state", operationFailed = "operation_failed"
    case sessionExpired = "session_expired", storageUnavailable = "storage_unavailable", verificationRequired = "verification_required", tooLarge = "too_large", readOnly = "read_only"
    public var errorDescription: String? {
        switch self {
        case .handoffUnavailable: "Proton could not connect Calendar from this account session. Try an unlocked Mail account, or sign in separately."
        case .sessionExpired: "Your Calendar session ended. Sign in again."
        case .storageUnavailable: "Calendar could not access its saved Keychain session. Your existing credentials have been retained."
        case .verificationRequired: "This sign-in requires verification that Calendar does not support yet. CAPTCHA and security-key-only sign-in are not available."
        case .tooLarge: "This Calendar range exceeds the current safety limits. Choose a smaller date range."
        case .readOnly: "This event or calendar cannot be edited yet. Recurring events, invitations and shared calendars remain read-only."
        case .conflict: "This event changed. Your draft is retained. Refresh Calendar, then reopen the latest event before editing it again."
        case .writeUncertain: "The save could not be confirmed. Your draft is retained. Refresh Calendar before trying again; check whether the event already saved."
        case .invalidInput: "Check the Calendar sign-in details or date range and try again."
        case .invalidState: "Unlock Calendar before continuing."
        case .operationFailed: "Calendar could not complete this operation. Check your connection and sign-in details, then try again."
        }
    }
}
public struct NativeCalendarCommand: Encodable, Sendable {
    public let draft: NativeCalendarDraft?
    public let handoff: AccountHandoff?
    public let method: String
    public let username: String?, password: String?, code: String?
    public let start: Int64?, end: Int64?, zone: String?
    public init(_ method: String, username: String? = nil, password: String? = nil, code: String? = nil, range: CalendarQueryRange? = nil, handoff: AccountHandoff? = nil, draft: NativeCalendarDraft? = nil) throws {
        self.draft = draft; self.handoff = handoff; self.method = method; self.username = username; self.password = password; self.code = code
        if let range { try range.validate() }
        start = range.map { Int64($0.start.timeIntervalSince1970) }; end = range.map { Int64($0.end.timeIntervalSince1970) }; zone = range?.timeZoneID
        try validate()
    }
    public func validate() throws {
        guard method == "account_handoff" || handoff == nil else { throw NativeCalendarFailure.invalidInput }
        guard method == "save_event" || draft == nil else { throw NativeCalendarFailure.invalidInput }
        let noRange = start == nil && end == nil && zone == nil
        switch method {
        case "login":
            guard let username, !username.isEmpty, username.utf8.count <= 320, !username.contains(where: { $0.isNewline }),
                  let password, !password.isEmpty, password.utf8.count <= 4096, code == nil, noRange else { throw NativeCalendarFailure.invalidInput }
        case "totp":
            guard let code, (6...8).contains(code.utf8.count), code.utf8.allSatisfy({ (48...57).contains($0) }), username == nil, password == nil, noRange else { throw NativeCalendarFailure.invalidInput }
        case "mailbox_password":
            guard let password, !password.isEmpty, password.utf8.count <= 4096, username == nil, code == nil, noRange else { throw NativeCalendarFailure.invalidInput }
        case "save_event":
            guard let draft, username == nil, password == nil, code == nil, noRange else { throw NativeCalendarFailure.invalidInput }; try draft.validate()
        case "snapshot":
            guard let start, let end, let zone, username == nil, password == nil, code == nil else { throw NativeCalendarFailure.invalidInput }
            try CalendarQueryRange(start: Date(timeIntervalSince1970: Double(start)), end: Date(timeIntervalSince1970: Double(end)), timeZoneID: zone).validate()
        case "account_handoff":
            guard let handoff, username == nil, password == nil, code == nil, noRange else { throw NativeCalendarFailure.invalidInput }; try handoff.validate()
        case "restore", "sign_out", "commit_handoff": guard username == nil, password == nil, code == nil, noRange else { throw NativeCalendarFailure.invalidInput }
        default: throw NativeCalendarFailure.invalidInput
        }
    }
}
/// Closed event write payload; secrets travel only over the helper's private stdin.
public struct NativeCalendarDraft: Encodable, Sendable {
    public let id: String, calendarID: String, token: String?, title: String, location: String, notes: String
    public let start: Int64, end: Int64, zone: String, allDay: Bool
    public init(_ event: CalendarEventRecord, token: String?) throws {
        id = event.id; calendarID = event.calendarID; self.token = token
        title = event.title; location = event.location; notes = event.notes
        switch event.time {
        case .timed(let s, let e, let z):
            guard s.timeIntervalSince1970.isFinite, e.timeIntervalSince1970.isFinite,
                  s.timeIntervalSince1970 >= 0, e.timeIntervalSince1970 <= 2145916800 else { throw CalendarFailure.invalidEvent }
            start = Int64(s.timeIntervalSince1970); end = Int64(e.timeIntervalSince1970); zone = z; allDay = false
        case .allDay(let s,let e):
            let math = CalendarDateMath(timeZoneID: "UTC")
            guard let a = math.date(s), let b = math.date(e) else { throw CalendarFailure.invalidEvent }
            start = Int64(a.timeIntervalSince1970); end = Int64(b.timeIntervalSince1970); zone = "UTC"; allDay = true
        }
        try validate()
    }
    public func validate() throws {
        func identifier(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 128 && s.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }
        guard identifier(id), identifier(calendarID), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 255, title.utf8.count <= 512, location.count <= 255, location.utf8.count <= 1024,
              notes.count <= 3000, notes.utf8.count <= 16384, !title.contains(where: { $0.isNewline }), !title.contains("\0"), !location.contains("\0"), !notes.contains("\0"),
              start >= 0, end > start, end <= 2145916800, end-start <= 366*86400, TimeZone(identifier:zone) != nil,
              !allDay || (zone == "UTC" && start % 86400 == 0 && end % 86400 == 0) else { throw CalendarFailure.invalidEvent }
        if let token { guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CalendarFailure.invalidEvent } }
    }
}
public struct NativeCalendarEvent: Decodable, Sendable {
    let id: String, calendarID: String, title: String, location: String, notes: String
    let start: Int64, end: Int64, zone: String
    let allDay: Bool, recurring: Bool
    let startDay: CalendarDay?, endDay: CalendarDay?
    let writeToken: String?
    func record() throws -> CalendarEventRecord {
        guard start >= 0, end > start, end <= 7289654400 else { throw ProtonXError.invalidResponse }
        let time: CalendarEventTime
        if allDay {
            guard let startDay, let endDay else { throw ProtonXError.invalidResponse }
            let math = CalendarDateMath(timeZoneID: "UTC")
            guard math.date(startDay)?.timeIntervalSince1970 == Double(start),
                  math.date(endDay)?.timeIntervalSince1970 == Double(end) else { throw ProtonXError.invalidResponse }
            time = .allDay(start: startDay, endExclusive: endDay)
        } else {
            guard startDay == nil, endDay == nil else { throw ProtonXError.invalidResponse }
            time = .timed(start: Date(timeIntervalSince1970: Double(start)), end: Date(timeIntervalSince1970: Double(end)), timeZoneID: zone)
        }
        var r = CalendarEventRecord(id: id, calendarID: calendarID, title: title, location: location, notes: notes, time: time)
        if let writeToken { guard !recurring, writeToken.utf8.count == 64, writeToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ProtonXError.invalidResponse } }
        r.recurring = recurring; r.writeToken = writeToken; return r
    }
}
public struct NativeCalendarResult: Decodable, Sendable {
    public let phase: String?
    public let event: NativeCalendarEvent?
    public let calendars: [CalendarCollection]?, events: [NativeCalendarEvent]?
    public let start: Int64?, end: Int64?, omitted: Int?
    public init(phase: String) { self.phase = phase; event = nil; calendars = nil; events = nil; start = nil; end = nil; omitted = nil }
    public func snapshot(for range: CalendarQueryRange) throws -> CalendarSnapshot {
        guard phase == "connected", let calendars, let events, start == Int64(range.start.timeIntervalSince1970), end == Int64(range.end.timeIntervalSince1970) else { throw ProtonXError.invalidResponse }
        let snapshot = CalendarSnapshot(calendars: calendars, events: try events.map { try $0.record() }, omitted: omitted ?? 0)
        try snapshot.validate()
        let math = CalendarDateMath(timeZoneID: range.timeZoneID)
        guard snapshot.events.allSatisfy({ event in
            guard let (s,e) = math.bounds(event) else { return false }; return s < range.end && e > range.start
        }) else { throw ProtonXError.invalidResponse }
        return snapshot
    }
}
public protocol NativeCalendarRunning: Sendable {
    func request(_ command: NativeCalendarCommand) async throws -> NativeCalendarResult
    func cancelAll()
}
public final class NativeCalendarProcess: NativeCalendarRunning, @unchecked Sendable {
    private struct Connection: Sendable { let process: Process; let input: FileHandle; let output: FileHandle }
    private let executable: URL
    private let directory: URL
    private let deadline: Duration
    private let lock = NSLock()
    private let gate = CommandGate()
    private var connection: Connection?
    private var generation: UInt64 = 0
    private var nextID: UInt64 = 0
    public init(executable: URL, directory: URL, deadline: Duration = .seconds(120)) { self.executable = executable; self.directory = directory; self.deadline = deadline }
    public func cancelAll() {
        let previous = lock.withLock { generation &+= 1; let old = connection; connection = nil; return old }
        if let previous { Self.stop(previous) }
    }
    private func cancelGeneration(_ captured: UInt64) {
        let previous = lock.withLock { () -> Connection? in
            guard generation == captured else { return nil }
            generation &+= 1; let old = connection; connection = nil; return old
        }
        if let previous { Self.stop(previous) }
    }
    deinit { cancelAll() }
    private static func stop(_ connection: Connection) {
        try? connection.input.close()
        if connection.process.isRunning {
            connection.process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if connection.process.isRunning { kill(connection.process.processIdentifier, SIGKILL) }
            }
        }
    }
    private func connect(captured: UInt64) throws -> Connection {
        try lock.withLock {
            guard generation == captured else { throw CancellationError() }
            if let connection, connection.process.isRunning { return connection }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ProtonXError.helperMissing }
            let process = Process(), input = Pipe(), output = Pipe()
            try PrivatePipe.prepareWriting(input.fileHandleForWriting)
            process.executableURL = executable; process.arguments = []
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PROTONX_CALENDAR_DIR": directory.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let created = Connection(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
            connection = created
            return created
        }
    }
    public func request(_ command: NativeCalendarCommand) async throws -> NativeCalendarResult {
        try command.validate()
        let captured = lock.withLock { generation }
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let channel = try connect(captured: captured)
            let id = lock.withLock { nextID &+= 1; return nextID }
            struct Packet: Encodable { let schema = 1; let id: UInt64; let command: NativeCalendarCommand }
            var data = try JSONEncoder().encode(Packet(id: id, command: command)); data.append(10)
            let packetData = data
            guard packetData.count <= 64 * 1024 else { throw ProtonXError.outputTooLarge }
            let watchdog = Task.detached { [deadline] in
                try? await Task.sleep(for: deadline)
                if !Task.isCancelled { Self.stop(channel) }
            }
            defer { watchdog.cancel() }
            let output: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { try channel.input.write(contentsOf: packetData); continuation.resume(returning: try Self.readLine(channel.output)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            guard lock.withLock({ generation == captured }) else { throw CancellationError() }
            let result = try Self.decode(output, expectedID: id)
            await gate.release()
            return result
        } catch {
            // A typed request failure leaves the framed helper connection alive.
            // Lock/cancelAll explicitly terminates a suspended authentication flow.
            // An older failed request must not cancel a newly unlocked generation.
            if !(error is NativeCalendarFailure) && !(error is CancellationError) { cancelGeneration(captured) }
            await gate.release()
            throw error
        }
    }
    private static func readLine(_ handle: FileHandle) throws -> Data {
        var result = Data()
        while true {
            var bytes = [UInt8](repeating: 0, count: 32768)
            var count: Int
            repeat { count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
            guard count > 0 else { throw ProtonXError.invalidResponse }
            result.append(contentsOf: bytes.prefix(count))
            guard result.count <= 8 * 1024 * 1024 else { throw ProtonXError.outputTooLarge }
            if let newline = result.firstIndex(of: 10) {
                guard newline == result.index(before: result.endIndex) else { throw ProtonXError.invalidResponse }
                return Data(result.prefix(upTo: newline))
            }
        }
    }
    public static func decode(_ data: Data, expectedID: UInt64) throws -> NativeCalendarResult {
        struct Reply: Decodable { let schema: Int; let id: UInt64; let result: NativeCalendarResult?; let failure: NativeCalendarFailure? }
        guard data.count <= 8*1024*1024 else { throw ProtonXError.outputTooLarge }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.schema == 1, reply.id == expectedID, (reply.result == nil) != (reply.failure == nil) else { throw ProtonXError.invalidResponse }
        if let failure = reply.failure { throw failure }
        guard let result = reply.result, ["welcome","connected","totp","mailbox_password","handoff_ready","locked"].contains(result.phase ?? ""),
              (result.calendars?.count ?? 0) <= 64, (result.events?.count ?? 0) <= 5000,
              (result.omitted ?? 0) >= 0, (result.omitted ?? 0) <= 100000 else { throw ProtonXError.invalidResponse }
        return result
    }
}
public actor NativeCalendarDataSource: CalendarDataSource {
    private let runner: any NativeCalendarRunning
    private var baseline: CalendarSnapshot?
    private var writeBlocked = false
    public init(runner: any NativeCalendarRunning) { self.runner = runner }
    public func snapshot() throws -> CalendarSnapshot { throw NativeCalendarFailure.invalidInput }
    public func snapshot(in range: CalendarQueryRange) async throws -> CalendarSnapshot {
        let result = try await runner.request(NativeCalendarCommand("snapshot", range: range))
        let snapshot = try result.snapshot(for: range)
        baseline = snapshot; writeBlocked = false
        return snapshot
    }
    public func save(_ event: CalendarEventRecord, expectedRevision: Int?) async throws -> CalendarEventRecord {
        guard !writeBlocked else { throw NativeCalendarFailure.writeUncertain }
        guard let baseline, baseline.calendars.contains(where: { $0.id == event.calendarID && $0.writable == true }) else { throw NativeCalendarFailure.readOnly }
        try event.validate(in: baseline.calendars)
        if let expectedRevision {
            guard let current = baseline.events.first(where: { $0.id == event.id }), current.revision == expectedRevision,
                  current.calendarID == event.calendarID, !current.recurring, let token = current.writeToken, token == event.writeToken else { throw NativeCalendarFailure.conflict }
        } else { guard !event.recurring, event.writeToken == nil, !baseline.events.contains(where: { $0.id == event.id }) else { throw NativeCalendarFailure.conflict } }
        let command = try NativeCalendarCommand("save_event", draft: NativeCalendarDraft(event,token:expectedRevision == nil ? nil : event.writeToken))
        writeBlocked = true
        do {
            let result = try await runner.request(command)
            guard result.phase == "connected", let response = result.event else { throw ProtonXError.invalidResponse }
            var saved = try response.record()
            try saved.validate(in: baseline.calendars)
            guard saved.calendarID == event.calendarID, saved.title == event.title, saved.location == event.location, saved.notes == event.notes,
                  saved.writeToken != nil, !saved.recurring else { throw ProtonXError.invalidResponse }
            let echoed = try NativeCalendarDraft(saved,token:nil)
            guard echoed.start == command.draft?.start, echoed.end == command.draft?.end, echoed.allDay == command.draft?.allDay, echoed.zone == command.draft?.zone else { throw ProtonXError.invalidResponse }
            guard (expectedRevision ?? 0) < Int.max else { throw ProtonXError.invalidResponse }
            saved.revision = (expectedRevision ?? 0) + 1
            self.baseline = CalendarSnapshot(calendars:baseline.calendars,events:baseline.events.filter { $0.id != event.id && $0.id != saved.id } + [saved],omitted:baseline.omitted)
            writeBlocked = false
            return saved
        } catch let failure as NativeCalendarFailure where [.readOnly,.invalidInput,.invalidState,.conflict,.sessionExpired,.storageUnavailable,.tooLarge].contains(failure) {
            writeBlocked = false; throw failure
        } catch { throw NativeCalendarFailure.writeUncertain }
    }
    public func delete(id: String, expectedRevision: Int) throws { throw NativeCalendarFailure.readOnly }
}
