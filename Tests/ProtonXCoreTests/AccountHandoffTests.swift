// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProtonXCore

@Suite struct AccountHandoffTests {
    func handoff(selector:String = "synthetic-selector", account:String = "synthetic-account", key:String = "73796e746865746963", offset:Int64 = 120) -> AccountHandoff {
        .init(selector:selector,accountID:account,keyPassHex:key,expires:Int64(Date().timeIntervalSince1970)+offset)
    }
    @Test func expiryPathIdentityAndKeyBoundsAreCheckedBeforeHelperAccess() throws {
        try handoff().validate()
        for value in [handoff(selector:"../escape"),handoff(selector:"synthetic?token=value"),handoff(account:""),handoff(account:"other/account"),handoff(key:"z1"),handoff(key:"abc"),handoff(key:String(repeating:"ab",count:4097)),handoff(offset:0),handoff(offset:121)] {
            #expect(throws:(any Error).self) { try value.validate() }
        }
        #expect(String(describing:handoff()) == "AccountHandoff(redacted)")
        #expect(String(reflecting:handoff()) == "AccountHandoff(redacted)")
    }
    @Test func handoffTravelsOnlyInsideClosedCalendarCommand() throws {
        let command = try NativeCalendarCommand("account_handoff",handoff:handoff())
        let json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(command)) as? [String:Any])
        #expect(json["password"] == nil && json["username"] == nil)
        let payload = try #require(json["handoff"] as? [String:Any])
        #expect(Set(payload.keys) == ["selector","accountID","keyPassHex","expires"])
        for method in ["login","snapshot","restore","sign_out","commit_handoff"] {
            #expect(throws:(any Error).self) { try NativeCalendarCommand(method,handoff:handoff()) }
        }
    }
    @Test func mailProtocolRecognizesOnlyBoundedHandoffAndClosedFailure() throws {
        let value = NativeMailResult(handoff:handoff())
        struct Reply:Encodable { let schema = 1; let id = 1; let result:NativeMailResult }
        let decoded = try NativeMailProcess.decode(JSONEncoder().encode(Reply(result:value)),expectedID:1)
        #expect(decoded.handoff?.accountID == "synthetic-account")
        #expect(throws:(any Error).self) { try NativeMailProcess.decode(JSONEncoder().encode(Reply(result:.init(handoff:handoff(offset:-1)))),expectedID:1) }
        #expect(throws:NativeMailFailure.handoffUnavailable) { try NativeMailProcess.decode(Data(#"{"schema":1,"id":1,"failure":"handoff_unavailable"}"#.utf8),expectedID:1) }
    }
}
private actor PassHandoffRunner:HelperRunning {
    private(set) var commands:[HelperCommand] = []
    func run(_ command:HelperCommand,challenge:ChallengeHandler?)async throws->Data {
        commands.append(command)
        return try JSONEncoder().encode(AccountHandoff(selector:"synthetic-selector",accountID:"synthetic-account",keyPassHex:"73796e746865746963",expires:Int64(Date().timeIntervalSince1970)+120))
    }
    nonisolated func cancelAll(){}
}
@Test func passHandoffCommandHasNoSecretsOrChildOverridesInArguments()async throws {
    let runner = PassHandoffRunner(), service = PassService(runner:runner)
    let handoff = try await service.calendarHandoff()
    #expect(handoff.accountID == "synthetic-account")
    let calls = await runner.commands
    #expect(calls == [HelperCommand(["native-calendar-handoff"])])
}
