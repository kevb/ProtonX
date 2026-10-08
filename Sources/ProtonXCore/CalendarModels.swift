// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Civil dates stay independent of UTC offsets. All-day ends are exclusive.
public struct CalendarDay: Equatable, Hashable, Sendable {
    public let year: Int, month: Int, day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
}
public enum CalendarEventTime: Equatable, Sendable {
    case timed(start: Date, end: Date, timeZoneID: String)
    case allDay(start: CalendarDay, endExclusive: CalendarDay)
}
public struct CalendarCollection: Identifiable, Equatable, Sendable {
    public let id: String, name: String
    public let color: Int
    public init(id: String, name: String, color: Int) { self.id = id; self.name = name; self.color = color }
}
public struct CalendarEventRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public var calendarID: String, title: String, location: String, notes: String
    public var time: CalendarEventTime
    public var revision: Int
    public init(id: String, calendarID: String, title: String, location: String = "", notes: String = "", time: CalendarEventTime, revision: Int = 0) {
        self.id = id; self.calendarID = calendarID; self.title = title; self.location = location; self.notes = notes; self.time = time; self.revision = revision
    }
    public func validate(in calendars: [CalendarCollection]) throws {
        guard !id.isEmpty, id.utf8.count <= 128, revision >= 0,
              calendars.contains(where: { $0.id == calendarID }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 512, location.utf8.count <= 1024, notes.utf8.count <= 16_384,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw CalendarFailure.invalidEvent }
        let math = CalendarDateMath(timeZoneID: "UTC")
        switch time {
        case .timed(let start, let end, let zone):
            guard TimeZone(identifier: zone) != nil, start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
                  start.timeIntervalSince1970 >= -2208988800, end.timeIntervalSince1970 <= 7289654400,
                  start < end, end.timeIntervalSince(start) <= 366 * 86400,
                  (1900...2200).contains(math.day(start).year), (1900...2200).contains(math.day(end).year) else { throw CalendarFailure.invalidEvent }
        case .allDay(let start, let end):
            guard let s = math.date(start), let e = math.date(end), s < e, e.timeIntervalSince(s) <= 366 * 86400 else { throw CalendarFailure.invalidEvent }
        }
    }
}
public enum CalendarFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidEvent, conflict, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidEvent: "Check the title, calendar and dates. The end must be after the start."
        case .conflict: "This event changed. Refresh Calendar before editing it again."
        case .unavailable: "Calendar could not complete this operation. Refresh before trying again."
        }
    }
}
public struct CalendarSnapshot: Sendable {
    public let calendars: [CalendarCollection], events: [CalendarEventRecord]
    public init(calendars: [CalendarCollection], events: [CalendarEventRecord]) { self.calendars = calendars; self.events = events }
    public func validate() throws {
        guard calendars.count <= 64, events.count <= 5000, Set(calendars.map(\.id)).count == calendars.count,
              Set(events.map(\.id)).count == events.count,
              calendars.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && !$0.name.isEmpty && $0.name.utf8.count <= 512 && (0...5).contains($0.color) }) else { throw CalendarFailure.unavailable }
        try events.forEach { try $0.validate(in: calendars) }
    }
}

/// Data boundary deliberately accepts events, never credentials or Mail sessions.
public protocol CalendarDataSource: Sendable {
    func snapshot() async throws -> CalendarSnapshot
    func save(_ event: CalendarEventRecord, expectedRevision: Int?) async throws -> CalendarEventRecord
    func delete(id: String, expectedRevision: Int) async throws
}

/// Synthetic only: no network, disk storage, Keychain, or external calendar export.
public actor PreviewCalendarDataSource: CalendarDataSource {
    private let calendars: [CalendarCollection]
    private var events: [CalendarEventRecord]
    public init(snapshot: CalendarSnapshot) throws { try snapshot.validate(); calendars = snapshot.calendars; events = snapshot.events }
    public func snapshot() -> CalendarSnapshot { .init(calendars: calendars, events: events) }
    public func save(_ event: CalendarEventRecord, expectedRevision: Int?) throws -> CalendarEventRecord {
        try event.validate(in: calendars)
        var saved = event
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            guard expectedRevision == events[index].revision, events[index].revision < Int.max else { throw CalendarFailure.conflict }
            saved.revision = events[index].revision + 1; events[index] = saved
        } else {
            guard expectedRevision == nil, events.count < 5000 else { throw CalendarFailure.conflict }
            saved.revision = 1; events.append(saved)
        }
        return saved
    }
    public func delete(id: String, expectedRevision: Int) throws {
        guard let index = events.firstIndex(where: { $0.id == id }), events[index].revision == expectedRevision else { throw CalendarFailure.conflict }
        events.remove(at: index)
    }
}
