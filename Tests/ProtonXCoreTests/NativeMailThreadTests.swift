import Foundation
import Testing
@testable import ProtonXCore

private func summary(_ id: UInt64, _ conversation: UInt64?, _ subject: String = "Same subject", date: UInt64 = 1, unread: Bool = false) -> NativeMailMessage {
    .init(id: id, subject: subject, sender: "synthetic\(id)@example.com", date: date, unread: unread, conversationID: conversation)
}
@Test func mailConversationGroupingUsesIdentityAndSearchesEveryLoadedMember() {
    let rows = NativeMailConversation.group([summary(11,70), summary(12,71), summary(13,70,"Different subject",unread: true)])
    #expect(rows.count == 2); #expect(rows[0].messages.map(\.id) == [11,13]); #expect(rows[1].id == 12)
    #expect(rows[0].unread); #expect(rows[0].matches("synthetic13")); #expect(rows[0].matches("Different"))
    #expect(!rows[1].matches("Different"))
}
@Test func oldMailHelpersAndMissingConversationIDsRemainIndividualMessages() throws {
    let rows = NativeMailConversation.group([summary(11,nil), summary(12,11), summary(13,nil), summary(14,0)])
    #expect(rows.count == 4) // A conversation ID cannot collide with a message fallback ID.
    #expect(NativeMailConversation.individual([summary(11,70),summary(12,70)]).count == 2)
    let message = try JSONDecoder().decode(NativeMailMessage.self, from: Data(#"{"id":1,"subject":"Synthetic","sender":"a@example.com","senderName":"","recipient":"","date":0,"unread":false,"attachments":0}"#.utf8))
    #expect(message.conversationID == nil)
}
@Test func threadPacketsRefuseMixedMembershipMissingAnchorDuplicateAndOversize() throws {
    struct Packet: Encodable { let schema = 1; let id = 1; let result: NativeMailResult }
    let valid = NativeMailThread(anchor: 11, conversationID: 70, messages: [summary(11,70),summary(13,70,date: 2)])
    #expect(try NativeMailProcess.decode(JSONEncoder().encode(Packet(result: .init(thread: valid))),expectedID: 1).thread == valid)
    for thread in [
        NativeMailThread(anchor: 11,conversationID: 70,messages: []),
        NativeMailThread(anchor: 11,conversationID: 70,messages: [summary(13,70)]),
        NativeMailThread(anchor: 11,conversationID: 70,messages: [summary(11,70),summary(13,71)]),
        NativeMailThread(anchor: 11,conversationID: 70,messages: [summary(11,70),summary(11,70)]),
        NativeMailThread(anchor: 11,conversationID: 70,messages: [summary(11,nil)]),
        NativeMailThread(anchor: 11,conversationID: 70,messages: [summary(11,70,date: 2),summary(13,70,date: 1)]),
        NativeMailThread(anchor: 11,conversationID: 70,messages: Array(repeating: summary(11,70),count: 201))
    ] {
        #expect(throws: ProtonXError.invalidResponse) { try NativeMailProcess.decode(JSONEncoder().encode(Packet(result: .init(thread: thread))), expectedID: 1) }
    }
}
