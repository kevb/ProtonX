// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

private actor CalendarSnapshotGate: CalendarDataSource {
    private var continuation: CheckedContinuation<CalendarSnapshot, Never>?
    private(set) var started = false
    func snapshot() async -> CalendarSnapshot {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ snapshot: CalendarSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
    func save(_ event: CalendarEventRecord, expectedRevision: Int?) throws -> CalendarEventRecord { throw CalendarFailure.unavailable }
    func delete(id: String, expectedRevision: Int) throws { throw CalendarFailure.unavailable }
}
@Suite @MainActor struct CalendarStoreTests {
    let fixed = Date(timeIntervalSince1970: 1791453600)
    func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await predicate())
    }
    @Test func normalCalendarDoesNotLoadOrAccessAnAccount() {
        var starts = 0
        let store = CalendarStore(now: { fixed }, makeSource: { starts += 1; throw CalendarFailure.unavailable })
        #expect(store.phase == .welcome && store.events.isEmpty && starts == 0)
    }
    @Test func previewCreateEditDeleteAndRefreshRetainOtherEvents() async throws {
        let store = CalendarStore(previewOnly: true, now: { fixed })
        try await wait { !store.busy }
        let original = store.events
        store.beginEvent(); let editor = try #require(store.editor); editor.title = "Synthetic new event"
        store.saveEditor(); try await wait { !store.busy }
        let created = try #require(store.selectedEvent)
        #expect(store.editor == nil && store.events.count == original.count + 1)
        store.beginEvent(created); store.editor?.title = "Synthetic edit"; store.saveEditor(); try await wait { !store.busy }
        #expect(store.selectedEvent?.revision == 2 && store.selectedEvent?.title == "Synthetic edit")
        let intent = try #require(store.deleteIntent()); store.delete(intent); try await wait { !store.busy }
        #expect(store.events == original)
        store.refresh(); try await wait { !store.busy }; #expect(store.events == original)
    }
    @Test func editorValidationAndAllDayEndConversion() async throws {
        let store = CalendarStore(previewOnly: true, now: { fixed }); try await wait { !store.busy }
        store.beginEvent(); store.saveEditor()
        #expect(store.error != nil && store.editor != nil && !store.busy)
        let editor = try #require(store.editor); editor.title = "Synthetic all-day event"; editor.changeAllDay(true)
        let math = CalendarDateMath(timeZoneID: editor.timeZoneID)
        if case .allDay(let start,let end) = editor.record().time {
            #expect(math.date(end) == math.addingDays(1, to: math.date(start)!))
        } else { Issue.record("All-day editor returned timed event") }
        store.saveEditor(); try await wait { !store.busy }; #expect(store.error == nil)
    }
    @Test func calendarAndMailEditorsSurviveSwitchesAndLockClearsBoth() async throws {
        let defaults = UserDefaults(suiteName: "CalendarSuiteTests." + UUID().uuidString)!
        let workspace = SuiteWorkspace(defaults: defaults, previewOnly: true, makeCalendar: { CalendarStore(previewOnly: true, now: { fixed }) })
        #expect(workspace.calendar == nil)
        workspace.select(.calendar); let calendar = try #require(workspace.calendar); try await wait { !calendar.busy }
        calendar.beginEvent(); let editor = try #require(calendar.editor); editor.title = "Synthetic unfinished event"
        calendar.query = "Synthetic"; calendar.mode = .month
        workspace.select(.mail); let mail = try #require(workspace.mail); mail.compose(); mail.editorState?.text = "Synthetic unfinished mail"
        workspace.select(.calendar)
        #expect(calendar.editor === editor && editor.title == "Synthetic unfinished event" && calendar.mode == .month && calendar.query == "Synthetic")
        #expect(mail.editorState?.text == "Synthetic unfinished mail")
        #expect(!workspace.canCreate)
        workspace.select(.pass); workspace.lock()
        #expect(calendar.phase == .welcome && calendar.editor == nil && calendar.events.isEmpty && calendar.query.isEmpty)
        #expect(mail.editorState == nil)
        #expect(!defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("Synthetic unfinished") == true })
    }
    @Test func lockRejectsLateSnapshotAndStaleDeleteIntent() async throws {
        let gate = CalendarSnapshotGate()
        let store = CalendarStore(now: { fixed }, makeSource: { gate })
        store.enterPreview(); try await wait { await gate.started }; store.lock()
        await gate.release(CalendarStore.samples(now: fixed, zone: "UTC"))
        for _ in 0..<10 { await Task.yield() }
        #expect(store.phase == .welcome && store.events.isEmpty && !store.busy)
        let preview = CalendarStore(previewOnly: true, now: { fixed }); try await wait { !preview.busy }
        preview.select(preview.events[0]); let intent = try #require(preview.deleteIntent()); preview.lock(); preview.enterPreview(); try await wait { !preview.busy }
        let count = preview.events.count; preview.delete(intent)
        #expect(!preview.busy && preview.events.count == count)
    }
    @Test func staleSaveKeepsUnfinishedEditorAndDoesNotReplay() async throws {
        let source = try PreviewCalendarDataSource(snapshot: CalendarStore.samples(now: fixed, zone: "UTC"))
        let store = CalendarStore(previewOnly: true, now: { fixed }, makeSource: { source })
        try await wait { !store.busy }
        let original = store.events[0]; store.beginEvent(original)
        let editor = try #require(store.editor); editor.title = "Synthetic unsaved conflict"
        var changed = original; changed.title = "Synthetic external change"
        _ = try await source.save(changed, expectedRevision: original.revision)
        store.saveEditor(); try await wait { !store.busy }
        #expect(store.editor === editor && editor.title == "Synthetic unsaved conflict" && store.error == CalendarFailure.conflict.localizedDescription)
        let snapshot = await source.snapshot()
        #expect(snapshot.events.first(where: { $0.id == original.id })?.title == "Synthetic external change")
        store.cancelEditor(); store.refresh(); try await wait { !store.busy }
        #expect(store.events.first(where: { $0.id == original.id })?.revision == 2)
    }
    @Test func calendarFiltersSearchAndStartupRouting() async throws {
        let defaults = UserDefaults(suiteName: "CalendarSuiteTests." + UUID().uuidString)!
        defaults.set("calendar", forKey: "suiteStartup")
        let workspace = SuiteWorkspace(defaults: defaults, previewOnly: false)
        #expect(workspace.selected == .calendar && workspace.calendar?.phase == .welcome && workspace.mail == nil && workspace.pass == nil)
        let store = CalendarStore(previewOnly: true, now: { fixed }); try await wait { !store.busy }
        store.query = "Weekly"; #expect(store.filteredEvents.map(\.id) == ["planning"])
        store.toggleCalendar("work"); #expect(store.filteredEvents.isEmpty)
        store.query = ""; #expect(store.filteredEvents.allSatisfy { $0.calendarID == "personal" })
    }
}
