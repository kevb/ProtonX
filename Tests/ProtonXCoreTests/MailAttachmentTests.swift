import Foundation
import Testing
@testable import ProtonXCore

@Test func attachmentProtocolBoundsNamesAndRoundTripsBinaryChunks() throws {
    let bytes = Data((0...255).map(UInt8.init))
    #expect(MailAttachmentPolicy.decode(MailAttachmentPolicy.encode(bytes)) == bytes)
    for input in ["f", "gg", "FF", String(repeating: "aa", count: MailAttachmentPolicy.chunkBytes + 1)] { #expect(MailAttachmentPolicy.decode(input) == nil) }
    #expect(MailAttachmentPolicy.filename("../../x\\y:test\n.txt") == "xytest.txt")
    #expect(MailAttachmentPolicy.filename("...") == "attachment")
    #expect(MailAttachmentPolicy.filename("report\u{202e}fdp.exe") == "reportfdp.exe")
    #expect(MailAttachmentPolicy.filename("👩‍💻.txt").contains("👩‍💻"))
    #expect(MailAttachmentPolicy.filename(String(repeating: "👩", count: 500)).utf8.count <= 240)
    let file = NativeMailAttachment(id: 1, name: "Synthetic.pdf", size: 12)
    try file.validate()
    #expect(throws: ProtonXError.self) { try MailAttachmentPolicy.validateList([file, file]) }
    #expect(throws: ProtonXError.self) { try NativeMailAttachment(id: .max, name: "Synthetic", size: 0).validate() }
    #expect(throws: ProtonXError.self) { try NativeMailAttachment(id: 1, name: "../outside.txt", size: 0).validate() }
    #expect(throws: ProtonXError.self) { try NativeMailTransfer(token: 1, size: MailAttachmentPolicy.maxBytes + 1, offset: 0).validate() }
    #expect(throws: ProtonXError.self) { try NativeMailTransfer(token: 1, size: 2, offset: 3).validate() }
}
@Test func attachmentRequestsCarryBytesWithoutSourceOrDestinationPaths() throws {
    let command = NativeMailCommand("upload_chunk", token: 5, transfer: 9, offset: 0, data: "00ff")
    let encoded = try JSONEncoder().encode(command)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == ["method", "token", "transfer", "offset", "data"])
    #expect(object["data"] as? String == "00ff")
    let reply = Data(#"{"schema":1,"id":1,"result":{"id":12,"attachmentList":[{"id":2,"name":"Synthetic.txt","size":0,"mime":"text/plain","state":"available"}]}}"#.utf8)
    #expect(try NativeMailProcess.decode(reply, expectedID: 1).attachmentList?.first?.name == "Synthetic.txt")
}
