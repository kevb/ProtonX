import Foundation

public enum NativeMailSendState: String, Codable, Sendable { case editing, queued, sent, failed, unknown }
public struct NativeMailComposeContent: Codable, Equatable, Sendable {
    public var sender: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var text: String
    public init(sender: String, to: [String] = [], cc: [String] = [], bcc: [String] = [], subject: String = "", text: String = "") {
        self.sender = sender; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject; self.text = text
    }
    public func validate(senders: [String], sending: Bool) throws {
        let recipients = to + cc + bcc
        guard (try JSONEncoder().encode(self)).count <= 60 * 1024 else { throw NativeMailFailure.invalidInput }
        guard senders.contains(sender), MailDraft.validAddress(sender), recipients.count <= 100,
              (!sending || !recipients.isEmpty), recipients.allSatisfy(MailDraft.validAddress),
              Set(recipients.map { $0.lowercased() }).count == recipients.count,
              subject.utf8.count <= 998, !subject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              text.utf8.count <= 32 * 1024 else { throw NativeMailFailure.invalidInput }
    }
    public static func parseRecipients(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
public struct NativeMailDraft: Codable, Identifiable, Equatable, Sendable {
    public var id: UInt64 { token }
    public let token: UInt64
    public var sender: String
    public let senders: [String]
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let text: String
    public let quote: String
    public var state: NativeMailSendState
    public let warning: String?
    public var attachmentList: [NativeMailAttachment]?
    public let attachments: Int
    public init(token: UInt64, sender: String, senders: [String], to: [String] = [], cc: [String] = [], bcc: [String] = [], subject: String = "", text: String = "", quote: String = "", state: NativeMailSendState = .editing, warning: String? = nil, attachments: Int = 0, attachmentList: [NativeMailAttachment]? = nil) {
        self.token = token; self.sender = sender; self.senders = senders; self.to = to; self.cc = cc; self.bcc = bcc
        self.subject = subject; self.text = text; self.quote = quote; self.state = state; self.warning = warning; self.attachments = attachments; self.attachmentList = attachmentList
    }
    public var content: NativeMailComposeContent { .init(sender: sender, to: to, cc: cc, bcc: bcc, subject: subject, text: text) }
}
