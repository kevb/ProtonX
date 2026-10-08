// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProtonXCore

@Suite struct CalendarTests {
    let math = CalendarDateMath(timeZoneID: "UTC")
    let collections = [CalendarCollection(id: "personal", name: "Personal", color: 0)]
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func event(_ id: String, _ start: String, _ end: String) -> CalendarEventRecord {
        .init(id: id, calendarID: "personal", title: "Synthetic event", time: .timed(start: date(start), end: date(end), timeZoneID: "UTC"), revision: 1)
    }
    @Test func civilDatesRejectNormalizationAndAllDayEndsAreExclusive() throws {
        #expect(math.date(.init(year: 2026, month: 2, day: 30)) == nil)
        #expect(math.date(.init(year: 1899, month: 1, day: 1)) == nil)
        let record = CalendarEventRecord(id: "trip", calendarID: "personal", title: "Synthetic trip", time: .allDay(start: .init(year: 2026, month: 10, day: 8), endExclusive: .init(year: 2026, month: 10, day: 10)))
        try record.validate(in: collections)
        for zone in ["Europe/Istanbul", "America/Los_Angeles", "Asia/Tokyo"] {
            let local = CalendarDateMath(timeZoneID: zone)
            #expect(local.contains(record, on: local.date(.init(year: 2026, month: 10, day: 9))!))
            #expect(!local.contains(record, on: local.date(.init(year: 2026, month: 10, day: 10))!))
        }
    }
    @Test func weekAndMonthUseMondayAndCivilDaysAcrossDST() {
        let local = CalendarDateMath(timeZoneID: "Europe/London")
        let sunday = local.date(.init(year: 2026, month: 3, day: 29))!
        #expect(local.addingDays(1, to: sunday).timeIntervalSince(sunday) == 23 * 3600)
        let week = local.week(sunday)
        #expect(week.count == 7 && local.day(week[0]).day == 23 && local.day(week[6]).day == 29)
        let month = local.month(sunday)
        #expect(month.count == 42 && local.calendar.component(.weekday, from: month[0]) == 2)
        let autumn = local.date(.init(year: 2026, month: 10, day: 25))!
        #expect(local.addingDays(1, to: autumn).timeIntervalSince(autumn) == 25 * 3600)
    }
    @Test func timedMidnightAndMultiDaySegmentsHaveHalfOpenBounds() {
        let record = event("night", "2026-10-08T23:00:00Z", "2026-10-10T00:00:00Z")
        let first = math.timedSegments([record], on: date("2026-10-08T00:00:00Z"))[0]
        #expect(first.startMinute == 1380 && first.endMinute == 1440 && !first.continuesBefore && first.continuesAfter)
        let second = math.timedSegments([record], on: date("2026-10-09T00:00:00Z"))[0]
        #expect(second.startMinute == 0 && second.endMinute == 1440 && second.continuesBefore && !second.continuesAfter)
        #expect(math.timedSegments([record], on: date("2026-10-10T00:00:00Z")).isEmpty)
        let ny = CalendarDateMath(timeZoneID: "America/New_York")
        let shifted = event("shift", "2026-10-08T01:00:00Z", "2026-10-08T02:00:00Z")
        #expect(ny.contains(shifted, on: ny.date(.init(year: 2026, month: 10, day: 7))!))
    }
    @Test func overlappingAndAdjacentEventsArePackedIndependently() {
        let records = [event("a", "2026-10-08T10:00:00Z", "2026-10-08T11:00:00Z"), event("b", "2026-10-08T10:30:00Z", "2026-10-08T11:30:00Z"), event("c", "2026-10-08T11:00:00Z", "2026-10-08T12:00:00Z"), event("d", "2026-10-08T12:00:00Z", "2026-10-08T13:00:00Z")]
        let packed = math.timedSegments(records.reversed(), on: date("2026-10-08T00:00:00Z"))
        #expect(packed.map(\.columnCount) == [2,2,2,1])
        #expect(packed.map(\.column) == [0,1,0,0])
    }
    @Test func invalidDataIsRejectedBeforeDateOrRevisionArithmetic() throws {
        var record = event("bad", "2026-10-08T10:00:00Z", "2026-10-08T11:00:00Z")
        record.time = .timed(start: Date(timeIntervalSince1970: 1e100), end: Date(timeIntervalSince1970: 1e101), timeZoneID: "UTC")
        #expect(throws: CalendarFailure.invalidEvent) { try record.validate(in: collections) }
        record.time = .timed(start: .now, end: .now.addingTimeInterval(100), timeZoneID: "Imaginary/Zone")
        #expect(throws: CalendarFailure.invalidEvent) { try record.validate(in: collections) }
        record.time = .allDay(start: .init(year: 2026, month: 1, day: 3), endExclusive: .init(year: 2026, month: 1, day: 3))
        #expect(throws: CalendarFailure.invalidEvent) { try record.validate(in: collections) }
        #expect(throws: CalendarFailure.unavailable) { try CalendarSnapshot(calendars: collections + collections, events: []).validate() }
        #expect(throws: CalendarFailure.unavailable) { try CalendarSnapshot(calendars: collections, events: [record,record]).validate() }
    }
    @Test func previewMutationsArePerEventAndRejectStaleRevisions() async throws {
        let original = event("one", "2026-10-08T10:00:00Z", "2026-10-08T11:00:00Z"), other = event("other", "2026-10-08T12:00:00Z", "2026-10-08T13:00:00Z")
        let source = try PreviewCalendarDataSource(snapshot: .init(calendars: collections, events: [original, other]))
        var edit = original; edit.title = "Changed synthetic title"
        let saved = try await source.save(edit, expectedRevision: 1)
        #expect(saved.revision == 2)
        await #expect(throws: CalendarFailure.conflict) { try await source.save(original, expectedRevision: 1) }
        await #expect(throws: CalendarFailure.conflict) { try await source.delete(id: saved.id, expectedRevision: 1) }
        let afterEdit = await source.snapshot()
        #expect(afterEdit.events == [saved,other])
        try await source.delete(id: saved.id, expectedRevision: 2)
        let afterDelete = await source.snapshot()
        #expect(afterDelete.events == [other])
        var new = original; new.title = "New synthetic event"
        let created = try await source.save(new, expectedRevision: nil)
        let count = await source.snapshot().events.count
        #expect(created.revision == 1 && count == 2)
    }
}
