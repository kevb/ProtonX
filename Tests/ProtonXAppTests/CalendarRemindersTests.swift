// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@MainActor private final class CalendarReminderSink: DesktopNotifying {
    var allowed: NotificationPermission = .authorized
    var notices: [DesktopNotice] = []
    var removed: [String] = []
    var dock: UInt64?
    func permission() async -> NotificationPermission { allowed }
    func authorize() async throws -> Bool { allowed == .authorized }
    func add(_ notice: DesktopNotice) async throws { notices.append(notice) }
    func remove(_ ids: [String]) { removed += ids; notices.removeAll { ids.contains($0.id) } }
    func clear() { notices = [] }
    func badge(_ count: UInt64?) { dock = count }
}

@Suite("CalendarRemindersTests")
@MainActor
struct CalendarRemindersTests {
    private static let baseNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(_ sink: CalendarReminderSink) async -> NativeNotifications {
        let name = "ProtonX.cal.reminders." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let controller = NativeNotifications(backend: sink, defaults: defaults)
        await controller.refreshPermission()
        controller.updateCalendar { $0.enabled = true; $0.leadMinutes = 15 }
        controller.beginCalendar()
        defaults.removePersistentDomain(forName: name)
        return controller
    }

    @Test func privateByDefaultSchedulesAtLeadTimeAndRoutesOpaqueClickTickets() async {
        let sink = CalendarReminderSink()
        let controller = await fixture(sink)
        var openedEventID: String?
        controller.openCalendar = { openedEventID = $0 }

        let start = Self.baseNow.addingTimeInterval(3600)
        let event = CalendarEventRecord(
            id: "evt-secret-1",
            calendarID: "work",
            title: "Confidential Planning",
            location: "Room 4B",
            notes: "",
            time: .timed(start: start, end: start.addingTimeInterval(1800), timeZoneID: "UTC"),
            revision: 1
        )
        let past = CalendarEventRecord(
            id: "evt-past",
            calendarID: "work",
            title: "Past Meeting",
            location: "",
            notes: "",
            time: .timed(start: Self.baseNow.addingTimeInterval(-600), end: Self.baseNow.addingTimeInterval(-60), timeZoneID: "UTC"),
            revision: 1
        )
        let farFuture = CalendarEventRecord(
            id: "evt-far",
            calendarID: "work",
            title: "Next Week",
            location: "",
            notes: "",
            time: .timed(start: Self.baseNow.addingTimeInterval(72 * 3600), end: Self.baseNow.addingTimeInterval(73 * 3600), timeZoneID: "UTC"),
            revision: 1
        )
        let allDay = CalendarEventRecord(
            id: "evt-allday",
            calendarID: "work",
            title: "Holiday",
            location: "",
            notes: "",
            time: .allDay(start: CalendarDay(year: 2027, month: 1, day: 15), endExclusive: CalendarDay(year: 2027, month: 1, day: 16)),
            revision: 1
        )

        await controller.syncCalendarReminders([event, past, farFuture, allDay], now: Self.baseNow)
        #expect(sink.notices.count == 1)
        let notice = sink.notices[0]
        #expect(notice.id.hasPrefix("cal-"))
        #expect(!notice.id.contains("evt-secret-1"))
        #expect(notice.title == "Upcoming Calendar event")
        #expect(!notice.body.contains("Confidential"))
        #expect(!notice.body.contains("Room 4B"))
        #expect(notice.deliverAt == start.addingTimeInterval(-15 * 60))

        controller.clicked(notice.id)
        #expect(openedEventID == "evt-secret-1")
        // Second click on consumed ticket does not re-open stale event ID.
        openedEventID = "unchanged"
        controller.clicked(notice.id)
        #expect(openedEventID == nil)
    }

    @Test func previewsShowSanitizedTitleAndClearCalendarPreservesMailAlerts() async {
        let sink = CalendarReminderSink()
        let controller = await fixture(sink)
        controller.update { $0.enabled = true }
        controller.beginMail()
        await controller.receive([NativeMailNotification(id: 5, folder: 1, sender: "Sam", subject: "Hello")], unread: 1)
        #expect(sink.notices.count == 1)

        controller.updateCalendar { $0.previews = true; $0.leadMinutes = 10; $0.sound = false }
        let start = Self.baseNow.addingTimeInterval(1800)
        let event = CalendarEventRecord(
            id: "evt-2",
            calendarID: "personal",
            title: "Dentist\u{0007} visit",
            location: "Main St",
            notes: "",
            time: .timed(start: start, end: start.addingTimeInterval(1800), timeZoneID: "UTC"),
            revision: 1
        )
        await controller.syncCalendarReminders([event], now: Self.baseNow)
        let calNotice = sink.notices.first { $0.id.hasPrefix("cal-") }
        #expect(calNotice?.title == "Dentist visit")
        #expect(calNotice?.body.contains("Main St") == true)
        #expect(calNotice?.sound == false)
        #expect(calNotice?.deliverAt == start.addingTimeInterval(-10 * 60))

        // Locking Calendar removes Calendar reminders without wiping Mail notifications.
        controller.clearCalendar()
        #expect(sink.notices.count == 1)
        #expect(!sink.notices[0].id.hasPrefix("cal-"))
    }

    @Test func reminderCountIsBoundedTo32UpcomingEvents() async {
        let sink = CalendarReminderSink()
        let controller = await fixture(sink)
        let events = (1...50).map { i in
            let start = Self.baseNow.addingTimeInterval(TimeInterval(i * 1800))
            return CalendarEventRecord(
                id: "evt-\(i)",
                calendarID: "work",
                title: "Event \(i)",
                location: "",
                notes: "",
                time: .timed(start: start, end: start.addingTimeInterval(900), timeZoneID: "UTC"),
                revision: 1
            )
        }
        await controller.syncCalendarReminders(events, now: Self.baseNow)
        #expect(sink.notices.count == 32)
    }
}
