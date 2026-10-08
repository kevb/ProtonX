// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProtonXCore
@Suite struct CalendarDraftTests {
    func event() -> CalendarEventRecord { .init(id:"synthetic",calendarID:"cal",title:"Synthetic",time:.timed(start:Date(timeIntervalSince1970:1791453600.5),end:Date(timeIntervalSince1970:1791457200.5),timeZoneID:"UTC")) }
    @Test func closedDraftRejectsMixedCommandsInvalidTokensAndUnsupportedDates() throws {
        let draft = try NativeCalendarDraft(event(),token:nil)
        #expect(draft.start == 1791453600)
        #expect(throws:Error.self) { try NativeCalendarCommand("restore",draft:draft) }
        #expect(throws:Error.self) { try NativeCalendarCommand("save_event",password:"synthetic",draft:draft) }
        #expect(throws:Error.self) { try NativeCalendarDraft(event(),token:"invalid") }
        var r = event(); r.title = "Synthetic\nInjected"; #expect(throws:Error.self) { try NativeCalendarDraft(r,token:nil) }
        r = event(); r.notes = String(repeating:"a",count:3001); #expect(throws:Error.self) { try NativeCalendarDraft(r,token:nil) }
        r = event(); r.calendarID = "../other"; #expect(throws:Error.self) { try NativeCalendarDraft(r,token:nil) }
        r = event(); r.time = .timed(start:Date(timeIntervalSince1970:2145916800),end:Date(timeIntervalSince1970:2145920400),timeZoneID:"UTC"); #expect(throws:Error.self) { try NativeCalendarDraft(r,token:nil) }
    }
    @Test func allDayDraftUsesCivilUTCBoundsIndependentOfViewingZone() throws {
        var r = event(); r.time = .allDay(start:.init(year:2026,month:10,day:8),endExclusive:.init(year:2026,month:10,day:10))
        let draft = try NativeCalendarDraft(r,token:nil)
        #expect(draft.allDay && draft.zone == "UTC" && draft.end-draft.start == 2*86400)
        let command = try NativeCalendarCommand("save_event",draft:draft)
        let json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(command)) as! [String:Any]
        #expect(json["draft"] != nil && json["password"] == nil && json["start"] == nil)
    }
}
