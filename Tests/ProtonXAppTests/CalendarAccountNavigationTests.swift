// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp
private actor SuiteAccountMailRunner: NativeMailRunning {
    private(set) var methods:[String] = []
    var failHandoff = false
    var holdSnapshot = false
    private var snapshotContinuation:CheckedContinuation<Void,Never>?
    func configureSnapshotHold(){holdSnapshot = true}
    func releaseSnapshot(){snapshotContinuation?.resume();snapshotContinuation = nil}
    func configureFailure(){failHandoff = true}
    func request(_ c:NativeMailCommand)async throws->NativeMailResult {
        methods.append(c.method)
        switch c.method {
        case "login","restore":return .init(phase:.connected)
        case "snapshot":
            if holdSnapshot { await withCheckedContinuation { snapshotContinuation = $0 };holdSnapshot = false }
            return .init(folders:[.init(id:1,name:"Inbox")],folder:1,messages:[],loading:false,email:"synthetic@example.com")
        case "calendar_handoff":
            if failHandoff { throw NativeMailFailure.handoffUnavailable }
            return .init(handoff:.init(selector:"synthetic-selector",accountID:"synthetic-account",keyPassHex:"73796e746865746963",expires:Int64(Date().timeIntervalSince1970)+120))
        default:throw ProtonXError.invalidResponse
        }
    }
    nonisolated func cancelAll(){}
}
private actor SuiteAccountCalendarRunner:NativeCalendarRunning {
    private(set) var methods:[String] = []
    private var continuation:CheckedContinuation<Void,Never>?
    var hold = false
    func configureHold(){hold = true}
    func release(){continuation?.resume();continuation = nil}
    func request(_ c:NativeCalendarCommand)async throws->NativeCalendarResult {
        methods.append(c.method)
        if c.method == "account_handoff" {
            if hold { await withCheckedContinuation { continuation = $0 } }
            return .init(phase:"handoff_ready")
        }
        if c.method == "commit_handoff" { return .init(phase:"connected") }
        if c.method == "snapshot" {
            return try NativeCalendarProcess.decode(Data("{\"schema\":1,\"id\":1,\"result\":{\"phase\":\"connected\",\"start\":\(c.start!),\"end\":\(c.end!),\"calendars\":[],\"events\":[]}}".utf8),expectedID:1)
        }
        throw ProtonXError.invalidResponse
    }
    nonisolated func cancelAll(){}
}
@Suite @MainActor struct CalendarAccountNavigationTests {
    func defaults()->UserDefaults { UserDefaults(suiteName:"SuiteAccountTests."+UUID().uuidString)! }
    func wait(_ condition:()async->Bool)async throws {
        let limit = ContinuousClock.now.advanced(by:.seconds(5))
        while !(await condition()) && ContinuousClock.now < limit { try await Task.sleep(for:.milliseconds(10)) }
        #expect(await condition())
    }
    private func suite(_ d:UserDefaults,_ mail:SuiteAccountMailRunner,_ calendar:SuiteAccountCalendarRunner)->SuiteWorkspace {
        SuiteWorkspace(defaults:d,previewOnly:false,makePass:{PassStore(previewOnly:true)},
                       makeMail:{NativeMailStore(runner:mail,defaults:d,previewOnly:false,localUnlock:{true})},
                       makeCalendar:{CalendarStore(runner:calendar,defaults:d)})
    }
    @Test func unlockedMailAutomaticallyConnectsCalendarWithoutAnotherLogin()async throws {
        let d = defaults(), m = SuiteAccountMailRunner(), c = SuiteAccountCalendarRunner(), s = suite(d,m,c)
        s.select(.mail);s.mail!.signIn(username:"synthetic@example.com",password:"SYNTHETIC")
        try await wait { s.mail?.busy == false }
        let mail = s.mail!;mail.query = "retained search"
        s.select(.calendar);try await wait { s.calendar?.phase == .connected && s.calendar?.busy == false }
        #expect(await m.methods == ["login","snapshot","calendar_handoff"])
        #expect(await c.methods == ["account_handoff","commit_handoff","snapshot"])
        s.select(.mail);#expect(s.mail === mail && mail.query == "retained search")
        s.select(.calendar);#expect(await m.methods.count == 3)
    }
    @Test func savedAccountOffersLocalUnlockAndReturnsToCalendar()async throws {
        let d = defaults();d.set(true,forKey:"nativeMailConnected")
        let m = SuiteAccountMailRunner(), c = SuiteAccountCalendarRunner(), s = suite(d,m,c)
        s.select(.calendar)
        #expect(s.mail?.phase == .locked && s.calendarAccounts.count == 1 && s.calendarAccounts[0].needsUnlock)
        #expect(await m.methods.isEmpty);#expect(await c.methods.isEmpty)
        s.connectCalendar(using:.mail);#expect(s.selected == .mail)
        s.mail?.unlock();try await wait { s.selected == .calendar && s.calendar?.phase == .connected }
        #expect(await m.methods == ["restore","snapshot","calendar_handoff"])
    }
    @Test(arguments:[false,true]) func calendarWaitsForMailAndRespectsAnotherAccountChoice(_ cancel:Bool)async throws {
        let d = defaults(), m = SuiteAccountMailRunner(), c = SuiteAccountCalendarRunner();await m.configureSnapshotHold()
        let s = suite(d,m,c);s.select(.mail)
        s.mail!.signIn(username:"synthetic@example.com",password:"SYNTHETIC")
        try await wait { await m.methods.contains("snapshot") };s.select(.calendar)
        #expect(s.calendarAccounts.count == 1 && !s.calendarAccounts[0].canContinue)
        #expect(await c.methods.isEmpty)
        if cancel { s.cancelCalendarAccountIntent() }
        await m.releaseSnapshot()
        if cancel { try await wait { s.mail?.busy == false };#expect(s.calendar?.phase == .welcome) }
        else { try await wait { s.calendar?.phase == .connected } }
        #expect(await m.methods.filter{$0 == "calendar_handoff"}.count == (cancel ? 0 : 1))
    }
    @Test func cancellingUnlockNavigationDoesNotHijackSelection()async throws {
        let d = defaults();d.set(true,forKey:"nativeMailConnected")
        let m = SuiteAccountMailRunner(), c = SuiteAccountCalendarRunner(), s = suite(d,m,c)
        s.select(.calendar);s.connectCalendar(using:.mail);s.select(nil)
        s.mail?.unlock();try await wait { s.mail?.busy == false }
        #expect(s.selected == nil && s.calendar?.phase == .welcome)
        #expect(await c.methods.isEmpty)
    }
    @Test func lockingSourceWhileChildIsStagedCancelsPublication()async throws {
        let d = defaults(), m = SuiteAccountMailRunner(), c = SuiteAccountCalendarRunner();await c.configureHold()
        let s = suite(d,m,c)
        s.select(.mail);s.mail!.signIn(username:"synthetic@example.com",password:"SYNTHETIC")
        try await wait { s.mail?.busy == false };s.select(.calendar)
        try await wait { await c.methods.count == 1 };s.mail?.lock()
        try await wait { s.calendar?.phase == .welcome };await c.release()
        try await wait { s.calendar?.busy == false }
        #expect(!d.bool(forKey:"nativeCalendarConnected"));#expect(await c.methods == ["account_handoff"])
    }
    @Test func failureOffersRetryWithoutRepeatedForksAndDemoHasNoAccounts()async throws {
        let d = defaults(), m = SuiteAccountMailRunner(), c = SuiteAccountCalendarRunner();await m.configureFailure()
        let s = suite(d,m,c)
        s.select(.mail);s.mail!.signIn(username:"synthetic@example.com",password:"SYNTHETIC")
        try await wait { s.mail?.busy == false };s.select(.calendar);try await wait { s.calendar?.busy == false }
        #expect(s.calendar?.phase == .welcome && s.calendar?.error != nil && !d.bool(forKey:"nativeCalendarConnected"))
        s.mail?.query = "another query";for _ in 0..<10 { await Task.yield() }
        #expect(await m.methods.filter{$0 == "calendar_handoff"}.count == 1);#expect(await c.methods.isEmpty)
        let demo = SuiteWorkspace(defaults:defaults(),previewOnly:true)
        demo.select(.mail);demo.select(.pass);#expect(demo.calendarAccounts.isEmpty)
    }
}
