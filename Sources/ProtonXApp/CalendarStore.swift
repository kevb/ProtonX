// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI
import ProtonXCore

@MainActor final class CalendarEditor: ObservableObject {
    let id: String, expectedRevision: Int?
    @Published var title = ""
    @Published var calendarID: String
    @Published var location = ""
    @Published var notes = ""
    @Published var start: Date
    @Published var end: Date
    @Published var allDay = false
    @Published var timeZoneID: String
    init(event: CalendarEventRecord?, calendarID: String, date: Date, timeZoneID: String) {
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
        return .init(id:id,calendarID:calendarID,title:title.trimmingCharacters(in:.whitespacesAndNewlines),location:location,notes:notes,time:time,revision:expectedRevision ?? 0)
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
    enum Phase { case welcome, preview }
    @Published private(set) var phase: Phase = .welcome
    @Published private(set) var calendars: [CalendarCollection] = []
    @Published private(set) var events: [CalendarEventRecord] = []
    @Published var visibleCalendarIDs: Set<String> = []
    @Published var date: Date
    @Published var timeZoneID = TimeZone.current.identifier
    @Published var mode: ViewMode = .week
    @Published var query = ""
    @Published var selectedEventID: String?
    @Published private(set) var editor: CalendarEditor?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var notice: String?
    private var source: (any CalendarDataSource)?
    private var operation: Task<Void,Never>?
    private var epoch = SessionEpoch()
    private let now: () -> Date
    private let makeSource: (() throws -> any CalendarDataSource)?
    init(previewOnly: Bool = false, now: @escaping () -> Date = Date.init, makeSource: (() throws -> any CalendarDataSource)? = nil) {
        self.now = now; self.makeSource = makeSource; date = now()
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
        phase = .preview; load(initial:true)
    }
    func refresh() { guard phase == .preview, !busy else { return }; load(initial:false) }
    private func load(initial: Bool) {
        guard let source else { return }
        perform { [self] in
            let snapshot = try await source.snapshot(); try snapshot.validate()
            return { [self] in
                calendars = snapshot.calendars; events = snapshot.events
                if initial { visibleCalendarIDs = Set(calendars.map(\.id)) }
                else { visibleCalendarIDs.formIntersection(Set(calendars.map(\.id))) }
                if !events.contains(where: { $0.id == selectedEventID }) { selectedEventID = nil }
            }
        }
    }
    func select(_ event: CalendarEventRecord) { guard editor == nil, events.contains(event) else { return }; selectedEventID = event.id; error = nil }
    func beginEvent(_ event: CalendarEventRecord? = nil, on day: Date? = nil) {
        guard phase == .preview, !busy, editor == nil, let first = calendars.first else { return }
        if let event { guard events.contains(event) else { return } }
        let day = day ?? date
        let start = math.calendar.date(bySettingHour:10,minute:0,second:0,of:day)!
        editor = CalendarEditor(event:event,calendarID:first.id,date:start,timeZoneID:timeZoneID); error = nil
    }
    func cancelEditor() { guard !busy else { return }; editor = nil; error = nil }
    func saveEditor() {
        guard !busy, let editor, let source else { return }
        let record = editor.record()
        do { try record.validate(in:calendars) } catch { self.error = error.localizedDescription; return }
        perform { [self] in
            let saved = try await source.save(record,expectedRevision:editor.expectedRevision)
            try saved.validate(in:calendars)
            return { [self] in
                events.removeAll { $0.id == saved.id }; events.append(saved); self.editor = nil
                selectedEventID = saved.id; visibleCalendarIDs.insert(saved.calendarID); date = math.bounds(saved)!.0
                notice = "Event saved in preview"
            }
        }
    }
    struct DeleteIntent { let id: String; let revision: Int; let epoch: UInt64; let title: String }
    func deleteIntent() -> DeleteIntent? {
        guard editor == nil, !busy, let event = selectedEvent else { return nil }
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
                guard let self, !Task.isCancelled, self.epoch.accepts(ticket), self.phase == .preview else { return }; apply()
            } catch {
                guard let self, !Task.isCancelled, self.epoch.accepts(ticket) else { return }
                self.error = (error as? CalendarFailure)?.localizedDescription ?? CalendarFailure.unavailable.localizedDescription
            }
            if let self, self.epoch.accepts(ticket) { self.busy = false }
        }
    }
    func lock() {
        epoch.invalidate(); operation?.cancel(); operation = nil; source = nil
        editor = nil; selectedEventID = nil; events = []; calendars = []; visibleCalendarIDs = []
        query = ""; error = nil; notice = nil; busy = false; phase = .welcome
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
