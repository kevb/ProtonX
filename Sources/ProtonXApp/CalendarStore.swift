// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI
import ProtonXCore

@MainActor final class CalendarEditor: ObservableObject {
    let id: String, expectedRevision: Int?
    let writeToken: String?
    @Published var title = ""
    @Published var calendarID: String
    @Published var location = ""
    @Published var notes = ""
    @Published var start: Date
    @Published var end: Date
    @Published var allDay = false
    @Published var timeZoneID: String
    init(event: CalendarEventRecord?, calendarID: String, date: Date, timeZoneID: String) {
        writeToken = event?.writeToken
        id = event?.id ?? UUID().uuidString; expectedRevision = event?.revision
        self.calendarID = event?.calendarID ?? calendarID; self.timeZoneID = timeZoneID
        start = date; end = date.addingTimeInterval(3600)
        guard let event else { return }
        title = event.title; location = event.location; notes = event.notes
        switch event.time {
        case .timed(let s,let e,let zone): start = s; end = e; self.timeZoneID = zone
        case .allDay(let s,let e):
            allDay = true; let math = CalendarDateMath(timeZoneID:timeZoneID)
            start = math.date(s)!; end = math.addingDays(-1,to:math.date(e)!)
        }
    }
    func record() -> CalendarEventRecord {
        let math = CalendarDateMath(timeZoneID:timeZoneID)
        let time: CalendarEventTime = allDay
            ? .allDay(start:math.day(start),endExclusive:math.day(math.addingDays(1,to:end)))
            : .timed(start:start,end:end,timeZoneID:timeZoneID)
        var result = CalendarEventRecord(id:id,calendarID:calendarID,title:title.trimmingCharacters(in:.whitespacesAndNewlines),location:location,notes:notes,time:time,revision:expectedRevision ?? 0)
        result.writeToken = writeToken; return result
    }
    func changeAllDay(_ value: Bool) {
        let math = CalendarDateMath(timeZoneID:timeZoneID)
        if value {
            let oldEnd = end; start = math.calendar.startOfDay(for:start)
            end = math.calendar.startOfDay(for:oldEnd)
            if oldEnd == end && end > start { end = math.addingDays(-1,to:end) }
        } else {
            start = math.calendar.date(bySettingHour:9,minute:0,second:0,of:start)!
            end = max(start.addingTimeInterval(3600),math.calendar.date(bySettingHour:10,minute:0,second:0,of:end)!)
        }
        allDay = value
    }
}

@MainActor final class CalendarStore: ObservableObject {
    enum ViewMode: String, CaseIterable { case week = "Week", month = "Month", agenda = "Agenda" }
    enum Phase { case welcome, preview, signingIn, locked, totp, mailboxPassword, connected }
    @Published private(set) var phase: Phase = .welcome
    @Published private(set) var calendars: [CalendarCollection] = []
    @Published private(set) var events: [CalendarEventRecord] = []
    @Published var visibleCalendarIDs: Set<String> = []
    @Published var date: Date { didSet { rangeChanged() } }
    @Published var timeZoneID = TimeZone.current.identifier { didSet { rangeChanged() } }
    @Published var mode: ViewMode = .week { didSet { rangeChanged() } }
    @Published var query = ""
    @Published var selectedEventID: String?
    @Published private(set) var editor: CalendarEditor?
    @Published private(set) var busy = false
    @Published private(set) var writeBlocked = false
    @Published var error: String?
    @Published private(set) var notice: String?
    private var source: (any CalendarDataSource)?
    private var operation: Task<Void,Never>?
    private var epoch = SessionEpoch()
    let localAuthentication: LocalUnlockAuthentication
    let previewOnly: Bool
    private let defaults: UserDefaults
    private let runner: any NativeCalendarRunning
    private var hasSession = false
    private var needsRangeReload = false
    private var loadedRange: CalendarQueryRange?
    private var debounce: Task<Void,Never>?
    private let now: () -> Date
    private let makeSource: (() throws -> any CalendarDataSource)?
    init(previewOnly: Bool = false, now: @escaping () -> Date = Date.init, makeSource: (() throws -> any CalendarDataSource)? = nil,
         runner: (any NativeCalendarRunning)? = nil, defaults: UserDefaults = .standard,
         localUnlock: (@MainActor @Sendable () async throws -> Bool)? = nil) {
        self.now = now; self.makeSource = makeSource; date = now()
        self.previewOnly = previewOnly; self.defaults = defaults
        self.localAuthentication = LocalUnlockAuthentication(evaluate: localUnlock)
        self.runner = runner ?? NativeCalendarProcess(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/protonx-calendar"), directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ProtonX/Calendar"))
        hasSession = !previewOnly && defaults.bool(forKey: "nativeCalendarConnected")
        if hasSession { phase = .locked }
        if previewOnly { enterPreview() }
    }
    var math: CalendarDateMath { .init(timeZoneID:timeZoneID) }
    var selectedEvent: CalendarEventRecord? { events.first { $0.id == selectedEventID } }
    var filteredEvents: [CalendarEventRecord] {
        events.filter { visibleCalendarIDs.contains($0.calendarID) && (query.isEmpty || ($0.title + " " + $0.location).localizedCaseInsensitiveContains(query)) }
    }
    func events(on date: Date) -> [CalendarEventRecord] {
        filteredEvents.filter { math.contains($0,on:date) }.sorted {
            let a = math.bounds($0)!.0, b = math.bounds($1)!.0
            if isAllDay($0) != isAllDay($1) { return isAllDay($0) }; return (a,$0.id) < (b,$1.id)
        }
    }
    func isAllDay(_ event: CalendarEventRecord) -> Bool { if case .allDay = event.time { return true }; return false }
    func toggleCalendar(_ id: String) {
        if visibleCalendarIDs.contains(id) { visibleCalendarIDs.remove(id) } else { visibleCalendarIDs.insert(id) }
    }
    func enterPreview() {
        guard !busy else { return }
        do { source = try makeSource?() ?? PreviewCalendarDataSource(snapshot: Self.samples(now:now(),zone:timeZoneID)) }
        catch { self.error = "Calendar preview could not start."; return }
        runner.cancelAll(); localAuthentication.cancel(); phase = .preview; load(initial:true)
    }
    func refresh() { guard phase == .preview || phase == .connected, !busy else { return }; needsRangeReload = false; load(initial:false) }
    private func load(initial: Bool) {
        guard let source else { return }
        let requestedRange = requestRange
        perform { [self] in
            let snapshot = try await source.snapshot(in: requestedRange); try snapshot.validate()
            return { [self] in
                if phase == .connected && requestedRange != requestRange { needsRangeReload = true; return }
                let previousIDs = Set(calendars.map(\.id))
                calendars = snapshot.calendars; events = snapshot.events; writeBlocked = false; loadedRange = requestedRange
                if phase == .connected { notice = snapshot.omitted > 0 ? "\(snapshot.omitted) event occurrences could not be decrypted or displayed. The visible range may be incomplete." : "Connected to Proton" }
                if initial { visibleCalendarIDs = Set(calendars.map(\.id)) }
                else { visibleCalendarIDs.formIntersection(Set(calendars.map(\.id))); visibleCalendarIDs.formUnion(Set(calendars.map(\.id)).subtracting(previousIDs)) }
                if !events.contains(where: { $0.id == selectedEventID }) { selectedEventID = nil }
            }
        }
    }
    func select(_ event: CalendarEventRecord) { guard editor == nil, events.contains(event) else { return }; selectedEventID = event.id; error = nil }
    func beginEvent(_ event: CalendarEventRecord? = nil, on day: Date? = nil) {
        guard canEdit, !busy, editor == nil, let first = editableCalendars.first else { return }
        if let event { guard events.contains(event), canEditEvent(event) else { return } }
        let day = day ?? date
        let start = math.calendar.date(bySettingHour:10,minute:0,second:0,of:day)!
        editor = CalendarEditor(event:event,calendarID:first.id,date:start,timeZoneID:timeZoneID); error = nil
    }
    func cancelEditor() { guard !busy else { return }; editor = nil; error = nil }
    func saveEditor() {
        guard canEdit, !busy, let editor, let source else { return }
        let record = editor.record()
        do { try record.validate(in:calendars) } catch { self.error = error.localizedDescription; return }
        perform { [self] in
            let saved = try await source.save(record,expectedRevision:editor.expectedRevision)
            try saved.validate(in:calendars)
            return { [self] in
                events.removeAll { $0.id == saved.id || $0.id == editor.id }; events.append(saved); self.editor = nil
                selectedEventID = saved.id; visibleCalendarIDs.insert(saved.calendarID); date = math.bounds(saved)!.0
                notice = phase == .preview ? "Event saved in preview" : "Event saved to Proton"
            }
        }
    }
    struct DeleteIntent { let id: String; let revision: Int; let epoch: UInt64; let title: String }
    func deleteIntent() -> DeleteIntent? {
        guard phase == .preview, editor == nil, !busy, let event = selectedEvent else { return nil }
        return .init(id:event.id,revision:event.revision,epoch:epoch.value,title:event.title)
    }
    func delete(_ intent: DeleteIntent) {
        guard !busy, editor == nil, phase == .preview, epoch.accepts(intent.epoch),
              let source, events.contains(where: { $0.id == intent.id && $0.revision == intent.revision }) else { return }
        perform { [self] in
            try await source.delete(id:intent.id,expectedRevision:intent.revision)
            return { [self] in events.removeAll { $0.id == intent.id }; selectedEventID = nil; notice = "Event removed from preview" }
        }
    }
    private func perform(_ work: @escaping @MainActor () async throws -> (@MainActor () -> Void)) {
        busy = true; error = nil; notice = nil; let ticket = epoch.value
        operation = Task { [weak self] in
            do {
                let apply = try await work()
                guard let self, !Task.isCancelled, self.epoch.accepts(ticket), (self.phase == .preview || self.phase == .connected || self.phase == .signingIn || self.phase == .locked || self.phase == .totp || self.phase == .mailboxPassword) else { return }; apply()
            } catch {
                guard let self, !Task.isCancelled, self.epoch.accepts(ticket) else { return }
                if error as? NativeCalendarFailure == .writeUncertain { self.writeBlocked = true }
                if let failure = error as? NativeCalendarFailure, failure == .sessionExpired {
                    self.lock(); self.hasSession = false; self.defaults.set(false, forKey: "nativeCalendarConnected"); self.phase = .welcome
                } else if self.phase == .signingIn || self.phase == .totp || self.phase == .mailboxPassword { self.runner.cancelAll(); self.phase = self.hasSession ? .locked : .welcome }
                self.error = (error as? NativeCalendarFailure)?.localizedDescription ?? (error as? CalendarFailure)?.localizedDescription ?? CalendarFailure.unavailable.localizedDescription
            }
            if let self, self.epoch.accepts(ticket) {
                self.busy = false
                if self.needsRangeReload && self.phase == .connected { self.needsRangeReload = false; self.refresh() }
            }
        }
    }
    func lock() {
        epoch.invalidate(); operation?.cancel(); operation = nil; source = nil; debounce?.cancel(); debounce = nil
        runner.cancelAll(); localAuthentication.cancel(); loadedRange = nil; needsRangeReload = false
        editor = nil; selectedEventID = nil; events = []; calendars = []; visibleCalendarIDs = []
        writeBlocked = false; query = ""; error = nil; notice = nil; busy = false; phase = hasSession ? .locked : .welcome
    }
    var isWorkspaceOpen: Bool { phase == .preview || phase == .connected }
    var editableCalendars: [CalendarCollection] { calendars.filter { phase == .preview || $0.writable == true } }
    var canEdit: Bool { phase == .preview || (phase == .connected && !writeBlocked && !editableCalendars.isEmpty) }
    func canEditEvent(_ event: CalendarEventRecord) -> Bool { canEdit && (phase == .preview || (!event.recurring && event.writeToken != nil && editableCalendars.contains { $0.id == event.calendarID })) }
    var requestRange: CalendarQueryRange {
        let days = mode == .month ? math.month(date) : mode == .week ? math.week(date) : (0..<14).map { math.addingDays($0,to:date) }
        let start = math.calendar.startOfDay(for:days.first!), end = math.addingDays(1,to:math.calendar.startOfDay(for:days.last!))
        return .init(start:start,end:end,timeZoneID:timeZoneID)
    }
    private func rangeChanged() {
        guard phase == .connected, loadedRange != requestRange else { return }
        if busy { needsRangeReload = true; return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(180))
            guard !Task.isCancelled, let self, self.phase == .connected else { return }
            if self.busy { self.needsRangeReload = true } else { self.refresh() }
        }
    }
    /// No target credentials are stored until both the source lease and the
    /// staged child account/key identity have been checked after async work.
    func connectAccount(produce: @escaping @MainActor () async throws -> AccountHandoff,
                        sourceIsValid: @escaping @MainActor () -> Bool) {
        guard !previewOnly, !hasSession, phase == .welcome, !busy, sourceIsValid() else { return }
        phase = .signingIn
        let ticket = epoch.value
        perform { [self] in
            let handoff = try await produce()
            guard !Task.isCancelled, epoch.accepts(ticket), sourceIsValid() else { throw CancellationError() }
            let staged = try await runner.request(NativeCalendarCommand("account_handoff", handoff: handoff))
            guard !Task.isCancelled, epoch.accepts(ticket), sourceIsValid() else { throw CancellationError() }
            if staged.phase == "locked" {
                return { [self] in hasSession = true; defaults.set(true,forKey:"nativeCalendarConnected"); runner.cancelAll(); phase = .locked }
            }
            guard staged.phase == "handoff_ready" else { throw ProtonXError.invalidResponse }
            let result = try await runner.request(NativeCalendarCommand("commit_handoff"))
            guard result.phase == "connected", !Task.isCancelled, epoch.accepts(ticket), sourceIsValid() else { throw CancellationError() }
            return { [self] in
                hasSession = true; defaults.set(true,forKey:"nativeCalendarConnected")
                source = NativeCalendarDataSource(runner:runner); phase = .connected
                visibleCalendarIDs = []; needsRangeReload = true
            }
        }
    }
    func signIn(username: String, password: String) {
        guard !previewOnly, !busy, [.welcome,.locked].contains(phase) else { return }
        do {
            let command = try NativeCalendarCommand("login",username:username.trimmingCharacters(in:.whitespacesAndNewlines),password:password)
            phase = .signingIn
            authenticate(command)
        } catch { self.error = error.localizedDescription }
    }
    func submitChallenge(_ value: String) {
        guard !previewOnly, !busy, phase == .totp || phase == .mailboxPassword else { return }
        do { authenticate(try NativeCalendarCommand(phase == .totp ? "totp" : "mailbox_password",password:phase == .mailboxPassword ? value : nil,code:phase == .totp ? value.trimmingCharacters(in:.whitespacesAndNewlines) : nil)) }
        catch { self.error = error.localizedDescription }
    }
    private func authenticate(_ command: NativeCalendarCommand) {
        let ticket = epoch.value
        perform { [self] in
            let result = try await runner.request(command)
            guard epoch.accepts(ticket), !Task.isCancelled else { throw CancellationError() }
            return { [self] in
                switch result.phase {
                case "totp": phase = .totp
                case "mailbox_password": phase = .mailboxPassword
                case "connected":
                    hasSession = true; defaults.set(true,forKey:"nativeCalendarConnected")
                    source = NativeCalendarDataSource(runner:runner); phase = .connected
                    visibleCalendarIDs = []; needsRangeReload = true
                default: error = "Calendar returned an unexpected sign-in state."
                }
            }
        }
    }
    func unlock(mode: LocalUnlockAuthentication.Mode = .system) {
        guard !previewOnly, phase == .locked, !busy else { return }
        let ticket = epoch.value
        perform { [self] in
            let allowed = try await localAuthentication.authenticate(mode,reason:"Unlock ProtonX Calendar on this Mac")
            guard allowed, epoch.accepts(ticket), !Task.isCancelled else { throw CancellationError() }
            let result = try await runner.request(NativeCalendarCommand("restore"))
            guard result.phase == "connected" else { throw ProtonXError.invalidResponse }
            return { [self] in source = NativeCalendarDataSource(runner:runner); phase = .connected; needsRangeReload = true }
        }
    }
    func cancelLocalUnlock() { if phase == .locked && busy { lock() } }
    func signOut() {
        guard !previewOnly, phase == .connected, !busy else { return }
        perform { [self] in
            let result = try await runner.request(NativeCalendarCommand("sign_out"))
            guard result.phase == "welcome" else { throw ProtonXError.invalidResponse }
            return { [self] in hasSession = false; defaults.set(false,forKey:"nativeCalendarConnected"); lock() }
        }
    }
    func today() { date = now() }
    func navigate(_ direction: Int) {
        let component: Calendar.Component = mode == .month ? .month : .day
        if let next = math.calendar.date(byAdding:component,value:direction * (mode == .month ? 1 : 7),to:date), (1901...2199).contains(math.day(next).year) { date = next }
    }
    static func samples(now: Date, zone: String) -> CalendarSnapshot {
        let math = CalendarDateMath(timeZoneID:zone), week = math.week(now)
        let calendars = [CalendarCollection(id:"personal",name:"Personal",color:0),CalendarCollection(id:"work",name:"Work",color:1)]
        func timed(_ id: String,_ title: String,_ day: Int,_ hour: Int,_ duration: Int,_ cal: String = "personal",location: String = "") -> CalendarEventRecord {
            let start = math.calendar.date(bySettingHour:hour,minute:0,second:0,of:week[day])!
            return .init(id:id,calendarID:cal,title:title,location:location,notes:"Synthetic preview event. No account data.",time:.timed(start:start,end:start.addingTimeInterval(Double(duration)*60),timeZoneID:zone),revision:1)
        }
        return .init(calendars:calendars,events:[
            timed("coffee","Coffee with Sam",0,10,60,location:"Corner café"), timed("planning","Weekly planning",1,9,90,"work"),
            timed("focus","Focus time",2,10,120,"work"), timed("catchup","Project catch-up",2,11,60,"work"),
            timed("walk","Afternoon walk",3,15,60),timed("review","Design review",4,11,60,"work"),
            timed("dinner","Dinner with friends",5,19,120),
            .init(id:"trip",calendarID:"personal",title:"Weekend away",location:"By the coast",notes:"Synthetic all-day event",time:.allDay(start:math.day(week[5]),endExclusive:math.day(math.addingDays(2,to:week[5]))),revision:1)
        ])
    }
}
