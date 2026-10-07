import Foundation

/// A selected SDK conversation, not an inferred subject/participant match.
public struct NativeMailThread: Codable, Equatable, Sendable {
    public let anchor: UInt64
    public let conversationID: UInt64
    public let messages: [NativeMailMessage]
    public init(anchor: UInt64, conversationID: UInt64, messages: [NativeMailMessage]) {
        self.anchor = anchor; self.conversationID = conversationID; self.messages = messages
    }
    public func validate() throws {
        guard anchor > 0, conversationID > 0, !messages.isEmpty, messages.count <= 200,
              messages.contains(where: { $0.id == anchor }),
              Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ $0.id > 0 && $0.conversationID == conversationID }),
              zip(messages, messages.dropFirst()).allSatisfy({ pair in pair.0.date <= pair.1.date }) else {
            throw ProtonXError.invalidResponse
        }
    }
}

/// Groups only loaded summaries. Counts are loaded messages, not server totals.
public struct NativeMailConversation: Identifiable, Equatable, Sendable {
    public var id: UInt64 { representative.id }
    public var representative: NativeMailMessage { messages[0] }
    public let messages: [NativeMailMessage]
    public var unread: Bool { messages.contains(where: \.unread) }
    private enum Key: Hashable { case conversation(UInt64), message(UInt64) }
    public static func group(_ messages: [NativeMailMessage]) -> [Self] {
        var groups: [[NativeMailMessage]] = [], indices: [Key: Int] = [:]
        for message in messages {
            let key = message.conversationID.flatMap { $0 > 0 ? Key.conversation($0) : nil } ?? .message(message.id)
            if let index = indices[key] { groups[index].append(message) }
            else { indices[key] = groups.count; groups.append([message]) }
        }
        return groups.map(Self.init(messages:))
    }
    public static func individual(_ messages: [NativeMailMessage]) -> [Self] { messages.map { Self(messages: [$0]) } }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || messages.contains { $0.subject.localizedStandardContains(query) || $0.sender.localizedStandardContains(query) || $0.senderName.localizedStandardContains(query) }
    }
    public func selectionID(_ current: UInt64?) -> UInt64 {
        if let current, messages.contains(where: { $0.id == current }) { return current }
        return id
    }
}
