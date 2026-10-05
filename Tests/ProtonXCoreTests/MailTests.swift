import Foundation
import Testing
@testable import ProtonXCore

@Test func mailHeaderInjectionIsRejected() {
    var draft = MailDraft(); draft.to = "person@example.com"; draft.subject = "Hello\r\nBcc: injected@example.com"
    #expect(throws: ProtonXError.self) { try draft.encoded(from: "sender@example.com") }
    for address in ["a@example.com\r\nBcc:x", "a@example.com,b@example.com", "<a@example.com>", "bad", "a@", "a@.com"] { #expect(!MailDraft.validAddress(address)) }
}
@Test func mailUsesLoopbackTLSAndEncodesMailbox() throws {
    let config = MailConfiguration(username: "test@example.com", password: "synthetic", certificatePEM: "-----BEGIN CERTIFICATE-----\nsynthetic\n-----END CERTIFICATE-----")
    #expect(try config.url(mailbox: "Folders/A;B") == "imap://127.0.0.1:1143/Folders%2FA%3BB")
    #expect(throws: ProtonXError.self) { try config.url(mailbox: "INBOX\r\nDELETE") }
}
@Test func MIMEPlainTextIsDecodedWithoutLoadingHTML() throws {
    let source = "From: =?UTF-8?B?U8O2eg==?= <soz@example.com>\r\nSubject: Hello\r\nContent-Type: multipart/alternative; boundary=\"example\"\r\n\r\n--example\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nCaf=C3=A9\r\n--example\r\nContent-Type: text/html\r\n\r\n<img src=\"https://tracker.example.com/pixel\">\r\n--example--\r\n"
    let result = try MailParser.message(Data(source.utf8), uid: 1)
    #expect(result.sender.hasPrefix("Söz")); #expect(result.body == "Café"); #expect(!result.body.contains("img")); #expect(!result.htmlOnly)
}
@Test func htmlOnlyMessagesAreExplicit() throws {
    let result = try MailParser.message(Data("Subject: HTML\nContent-Type: text/html\n\n<script>alert(1)</script>".utf8), uid: 1)
    #expect(result.htmlOnly); #expect(!result.body.contains("script"))
}
@Test func SMTPPayloadPreservesUnicodeAndDotLeadingLines() throws {
    var draft = MailDraft(); draft.to = "person@example.com"; draft.subject = "Café"; draft.body = ".\nA synthetic line\nİstanbul"
    let result = try #require(String(data: draft.encoded(from: "sender@example.com"), encoding: .utf8))
    #expect(result.contains("Content-Transfer-Encoding: base64")); #expect(result.contains("Subject: =?UTF-8?B?Q2Fmw6k=?="))
    let body = result.components(separatedBy: "\r\n\r\n")[1]
    #expect(String(data: try #require(Data(base64Encoded: body, options: .ignoreUnknownCharacters)), encoding: .utf8) == ".\r\nA synthetic line\r\nİstanbul")
}
@Test func searchAndMailboxParsingHandlesEmptyAndQuotedNames() throws {
    #expect(try MailParser.uids(Data("* SEARCH 5 1 5 0\r\nA OK search\r\n".utf8)) == [1, 5])
    #expect(try MailParser.uids(Data("* SEARCH\r\n".utf8)).isEmpty)
    #expect(try MailParser.mailboxes(Data("* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST () \"/\" \"Folders/Hello World\"\r\n".utf8)) == ["INBOX", "Folders/Hello World"])
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["PROTONX_BRIDGE_TEST_CONFIG"] != nil, "Use scripts/test-bridge.sh to start the disposable TLS fixture.")) func syntheticBridgeRoundTrip() async throws {
    guard let path = ProcessInfo.processInfo.environment["PROTONX_BRIDGE_TEST_CONFIG"] else { return }
    let config = try JSONDecoder().decode(MailConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let service = BridgeMailService()
    #expect(try await service.mailboxes(config).contains("INBOX"))
    let messages = try await service.list(config, mailbox: "INBOX")
    #expect(messages.count == 2); #expect(messages.first?.uid == 2)
    let message = try await service.message(config, mailbox: "INBOX", uid: 1)
    #expect(message.body.contains("Synthetic mail body"))
    var draft = MailDraft(); draft.to = "synthetic@example.com"; draft.subject = "Synthetic round trip"; draft.body = "Synthetic SMTP payload"
    try await service.send(draft, config: config)
    if let certificate = ProcessInfo.processInfo.environment["PROTONX_UNTRUSTED_CERT"] {
        var untrusted = config; untrusted.certificatePEM = try String(contentsOfFile: certificate, encoding: .utf8)
        await #expect(throws: Error.self) { try await service.mailboxes(untrusted) }
    }
    var invalid = config; invalid.password = "wrong"
    await #expect(throws: Error.self) { try await service.mailboxes(invalid) }
}
