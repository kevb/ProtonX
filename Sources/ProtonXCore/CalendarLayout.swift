// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct CalendarDateMath: Sendable {
    public let calendar: Calendar
    public init(timeZoneID: String) {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; calendar = c
    }
    public func day(_ date: Date) -> CalendarDay {
        let c = calendar.dateComponents([.year,.month,.day], from: date)
        return .init(year: c.year!, month: c.month!, day: c.day!)
    }
    public func date(_ day: CalendarDay) -> Date? {
        guard (1900...2200).contains(day.year), (1...12).contains(day.month), (1...31).contains(day.day),
              let value = calendar.date(from: .init(year:day.year,month:day.month,day:day.day)), self.day(value) == day else { return nil }
        return value
    }
    public func addingDays(_ count: Int, to date: Date) -> Date { calendar.date(byAdding:.day,value:count,to:date)! }
    public func week(_ date: Date) -> [Date] {
        let start = calendar.dateInterval(of:.weekOfYear,for:date)!.start
        return (0..<7).map { addingDays($0,to:start) }
    }
    public func month(_ date: Date) -> [Date] {
        let first = calendar.dateInterval(of:.month,for:date)!.start
        let start = week(first)[0]
        return (0..<42).map { addingDays($0,to:start) }
    }
    public func bounds(_ event: CalendarEventRecord) -> (Date,Date)? {
        switch event.time {
        case .timed(let s,let e,_): return (s,e)
        case .allDay(let s,let e): guard let a = date(s), let b = date(e) else { return nil }; return (a,b)
        }
    }
    public func contains(_ event: CalendarEventRecord, on date: Date) -> Bool {
        guard let (s,e) = bounds(event) else { return false }
        let begin = calendar.startOfDay(for:date), end = addingDays(1,to:begin)
        return s < end && e > begin
    }
    public func minutes(_ date: Date) -> Double {
        let c = calendar.dateComponents([.hour,.minute,.second],from:date)
        return Double(c.hour! * 60 + c.minute!) + Double(c.second!) / 60
    }
    public func timedSegments(_ events: [CalendarEventRecord], on date: Date) -> [CalendarEventSegment] {
        let begin = calendar.startOfDay(for:date), end = addingDays(1,to:begin)
        var segments = events.compactMap { event -> CalendarEventSegment? in
            guard case .timed(let s,let e,_) = event.time, s < end, e > begin else { return nil }
            let start = s <= begin ? 0 : minutes(s), finish = e >= end ? 1440 : minutes(e)
            // DST fall-back can map absolute end before start on a wall-clock grid.
            return .init(event:event,startMinute:start,endMinute:min(1440,max(start + 1,finish)),continuesBefore:s < begin,continuesAfter:e > end)
        }.sorted { ($0.startMinute,$0.endMinute,$0.event.id) < ($1.startMinute,$1.endMinute,$1.event.id) }
        var group: [Int] = [], laneEnds: [Double] = [], groupEnd = -1.0
        func finishGroup() {
            for index in group { segments[index].columnCount = max(1,laneEnds.count) }
            group = []; laneEnds = []
        }
        for index in segments.indices {
            if segments[index].startMinute >= groupEnd { finishGroup() }
            let lane = laneEnds.firstIndex(where: { $0 <= segments[index].startMinute }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(segments[index].endMinute) } else { laneEnds[lane] = segments[index].endMinute }
            segments[index].column = lane; group.append(index)
            groupEnd = group.count == 1 ? segments[index].endMinute : max(groupEnd,segments[index].endMinute)
        }
        finishGroup(); return segments
    }
}
public struct CalendarEventSegment: Identifiable, Sendable {
    public var id: String { event.id }
    public let event: CalendarEventRecord
    public let startMinute: Double, endMinute: Double
    public let continuesBefore: Bool, continuesAfter: Bool
    public var column = 0, columnCount = 1
}
