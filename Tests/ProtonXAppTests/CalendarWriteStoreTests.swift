// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private actor EventWriteRunner: NativeCalendarRunning {
    private(set) var writes: [NativeCalendarDraft] = []
    private var rows: [[String:Any]] = []
    private var failure: NativeCalendarFailure?
    private var hold = false
    private var held: CheckedContinuation<Void,Never>?
    func configure(_ failure: NativeCalendarFailure? = nil, hold: Bool = false) { self.failure = failure; self.hold = hold }
    func release() { held?.resume(); held = nil }
    func request(_ command: NativeCalendarCommand) async throws -> NativeCalendarResult {
        if command.method == "save_event" {
            let draft = command.draft!; writes.append(draft)
            if hold { await withCheckedContinuation { held = $0 }; hold = false }
            if let failure { throw failure }
            var event = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String:Any]
            event["id"] = "saved-event"; event["recurring"] = false; event["token"] = nil
            event["writeToken"] = String(format:"%064d",writes.count)
            if draft.allDay {
                let math = CalendarDateMath(timeZoneID:"UTC")
                event["startDay"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(math.day(Date(timeIntervalSince1970:Double(draft.start)))))
                event["endDay"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(math.day(Date(timeIntervalSince1970:Double(draft.end)))))
            }
            rows = [event]
            return try decode(["phase":"connected","event":event])
        }
        if command.method == "snapshot" { return try decode(["phase":"connected","start":command.start!,"end":command.end!,"calendars":[["id":"cal","name":"Synthetic calendar","color":0,"writable":true]],"events":rows]) }
        return .init(phase:"connected")
    }
    private func decode(_ value: [String:Any]) throws -> NativeCalendarResult {
        try NativeCalendarProcess.decode(JSONSerialization.data(withJSONObject:["schema":1,"id":1,"result":value]),expectedID:1)
    }
    nonisolated func cancelAll() {}
}
@Suite @MainActor struct CalendarWriteStoreTests {
    private func connected(_ runner: EventWriteRunner) async throws -> CalendarStore {
        let store = CalendarStore(now:{ Date(timeIntervalSince1970:1791453600) },runner:runner,defaults:UserDefaults(suiteName:"CalendarWriteTests."+UUID().uuidString)!)
        store.timeZoneID = "UTC"; store.signIn(username:"synthetic@example.com",password:"synthetic")
        try await wait { !store.busy }; return store
    }
    private func wait(_ condition: ()async->Bool) async throws {
        let limit = ContinuousClock.now.advanced(by:.seconds(5))
        while !(await condition()) && ContinuousClock.now < limit { try await Task.sleep(for:.milliseconds(10)) }
        #expect(await condition())
    }
    @Test func connectedCreateEditAndAllDaySaveThroughPrivateEventCommand() async throws {
        let runner = EventWriteRunner(), store = try await connected(runner)
        #expect(store.canEdit); store.beginEvent()
        let draft = try #require(store.editor); draft.title = "Synthetic event"; draft.notes = "Synthetic notes"; draft.location = "Synthetic room"
        store.saveEditor(); try await wait { !store.busy }
        #expect(store.editor == nil && store.selectedEvent?.title == "Synthetic event" && store.error == nil)
        let created = try #require(store.selectedEvent); #expect(created.writeToken != nil && store.canEditEvent(created))
        store.beginEvent(created); let edit = try #require(store.editor); edit.title = "Synthetic edited event"; edit.changeAllDay(true)
        store.saveEditor(); try await wait { !store.busy }
        #expect(store.error == nil && store.editor == nil && store.events.count == 1 && store.selectedEvent?.title == "Synthetic edited event")
        #expect(store.deleteIntent() == nil)
        let calls = await runner.writes; #expect(calls.count == 2 && calls[0].token == nil && calls[1].token == created.writeToken && calls[1].allDay && calls[1].zone == "UTC")
    }
    @Test func correctedFiveMinuteEventClearsStaleValidationAndSavesInIstanbul() async throws {
        let runner = EventWriteRunner(), store = try await connected(runner)
        store.timeZoneID = "Europe/Istanbul"; store.refresh(); try await wait { !store.busy }
        store.beginEvent()
        let editor = try #require(store.editor)
        editor.title = "Synthetic five-minute event"
        let math = CalendarDateMath(timeZoneID: "Europe/Istanbul")
        let day = try #require(math.date(.init(year: 2026, month: 10, day: 9)))
        editor.start = try #require(math.calendar.date(bySettingHour: 11, minute: 30, second: 0, of: day))
        editor.end = editor.start.addingTimeInterval(-300)
        store.saveEditor()
        #expect(store.error != nil && !store.busy && store.editor === editor)
        #expect(store.error == "The end time must be after the start time.")
        #expect(await runner.writes.isEmpty)
        editor.end = editor.start.addingTimeInterval(300)
        #expect(store.error == nil)
        store.saveEditor(); try await wait { !store.busy }
        #expect(store.error == nil && store.editor == nil)
        let writes = await runner.writes
        #expect(writes.count == 1 && writes[0].zone == "Europe/Istanbul" && writes[0].end - writes[0].start == 300)
    }
    @Test func uncertainSaveKeepsDraftBlocksRetryUntilRefreshAndKeepsCreateIdentity() async throws {
        let runner = EventWriteRunner(), store = try await connected(runner)
        store.beginEvent(); let editor = try #require(store.editor); editor.title = "Synthetic event"; let id = editor.id
        await runner.configure(.operationFailed); store.saveEditor(); try await wait { !store.busy }
        #expect(store.writeBlocked && store.editor === editor && store.error != nil)
        store.saveEditor(); #expect(await runner.writes.count == 1)
        await runner.configure(); store.refresh(); try await wait { !store.busy }
        #expect(!store.writeBlocked && store.editor?.id == id)
        store.saveEditor(); try await wait { !store.busy }
        #expect(store.editor == nil && store.error == nil && store.events.count == 1)
        let calls = await runner.writes; #expect(calls.count == 2 && calls[0].id == calls[1].id)
    }
    @Test func conflictPreservesDraftAndCancelAllowsFreshEdit() async throws {
        let runner = EventWriteRunner(), store = try await connected(runner)
        store.beginEvent(); store.editor?.title = "Synthetic event"; store.saveEditor(); try await wait { !store.busy }
        store.beginEvent(try #require(store.selectedEvent)); store.editor?.title = "Synthetic unsaved changes"
        await runner.configure(.conflict); store.saveEditor(); try await wait { !store.busy }
        #expect(store.editor?.title == "Synthetic unsaved changes" && !store.busy && store.error != nil)
        let conflictMessage = store.error
        store.editor?.notes = "Synthetic corrected notes"
        #expect(store.error == conflictMessage)
        store.cancelEditor(); await runner.configure(); store.refresh(); try await wait { !store.busy }
        store.beginEvent(try #require(store.selectedEvent)); #expect(store.editor?.title == "Synthetic event")
    }
    @Test func invalidNativeTextDoesNotBlameDatesOrDispatchAndClearsWhenEdited() async throws {
        let runner = EventWriteRunner(), store = try await connected(runner)
        store.beginEvent(); let editor = try #require(store.editor)
        editor.title = "Synthetic event"; editor.notes = String(repeating: "x", count: 3001)
        store.saveEditor()
        #expect(store.error != nil && !store.error!.contains("end time") && !store.busy && !store.writeBlocked)
        #expect(await runner.writes.isEmpty)
        editor.notes = "Synthetic shorter notes"
        #expect(store.error == nil)
        store.saveEditor(); try await wait { !store.busy }
        let count = await runner.writes.count
        #expect(store.error == nil && store.editor == nil && count == 1)
    }
    @Test func lateSaveCannotReopenLockedCalendar() async throws {
        let runner = EventWriteRunner(), store = try await connected(runner)
        store.beginEvent(); store.editor?.title = "Synthetic event"; await runner.configure(hold:true)
        store.saveEditor(); try await wait { await runner.writes.count == 1 }
        store.lock(); await runner.release(); for _ in 0..<20 { await Task.yield() }
        #expect(store.phase == .locked && store.events.isEmpty && store.editor == nil)
    }
}
