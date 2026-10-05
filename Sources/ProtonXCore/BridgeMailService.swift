import Foundation
import CBridgeTransport

private final class BridgeTransfer: @unchecked Sendable {
    let pointer: OpaquePointer
    init() { pointer = px_transfer_new()! }
    deinit { px_transfer_free(pointer) }
    func cancel() { px_transfer_cancel(pointer) }
}

public struct BridgeError: Error, LocalizedError, Sendable {
    public let code: Int32
    public var errorDescription: String? {
        switch code {
        case 7: "Proton Bridge is not accepting connections. Start Bridge and check its ports."
        case 60, 77: "The Bridge TLS certificate could not be verified. Export its current public certificate and reconnect."
        case 67: "Bridge rejected these credentials. Use the password shown in Bridge, rather than your Proton account password."
        case 28: "Bridge timed out. If this was a send operation, check Sent before retrying."
        case 42: "The Bridge operation was cancelled. If sending, check Sent before retrying."
        default: "Bridge could not complete the operation (\(code)). If sending, check Sent before retrying."
        }
    }
}

public final class BridgeMailService: @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [UUID: BridgeTransfer] = [:]
    private let gate = CommandGate()
    public init() {}
    public func cancelAll() { lock.withLock { Array(transfers.values) }.forEach { $0.cancel() } }
    private func request(_ config: MailConfiguration, url: String, command: String = "", draft: MailDraft? = nil) async throws -> Data {
        try config.validate()
        let body = try draft?.encoded(from: config.username)
        await gate.acquire()
        let transfer = BridgeTransfer(), id = UUID()
        lock.withLock { transfers[id] = transfer }
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await Task.detached {
                    let bytes = body ?? Data()
                    return try bytes.withUnsafeBytes { buffer -> Data in
                        let result = px_mail_request(transfer.pointer, url, config.username, config.password, config.certificatePEM,
                                                     command.isEmpty ? nil : command, draft == nil ? nil : config.username,
                                                     draft?.to, draft == nil ? nil : buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count)
                        defer { px_result_free(result) }
                        guard result.status == 0 else { throw BridgeError(code: result.status) }
                        return result.length == 0 ? Data() : Data(bytes: result.data!, count: result.length)
                    }
                }.value
            } onCancel: { transfer.cancel() }
            lock.withLock { _ = transfers.removeValue(forKey: id) }
            await gate.release()
            try Task.checkCancellation()
            return result
        } catch {
            lock.withLock { _ = transfers.removeValue(forKey: id) }
            await gate.release(); throw error
        }
    }
    public func mailboxes(_ config: MailConfiguration) async throws -> [String] {
        try MailParser.mailboxes(await request(config, url: config.url(), command: "LIST \"\" \"*\""))
    }
    public func list(_ config: MailConfiguration, mailbox: String, limit: Int = 25) async throws -> [MailMessage] {
        let data = try await request(config, url: config.url(mailbox: mailbox), command: "UID SEARCH ALL")
        let ids = try MailParser.uids(data).suffix(max(1, min(limit, 100))).reversed()
        var messages: [MailMessage] = []
        for id in ids {
            try Task.checkCancellation()
            let data = try await request(config, url: config.url(mailbox: mailbox, uid: id, headerOnly: true))
            messages.append(try MailParser.message(data, uid: id))
        }
        return messages
    }
    public func message(_ config: MailConfiguration, mailbox: String, uid: UInt64) async throws -> MailMessage {
        try MailParser.message(await request(config, url: config.url(mailbox: mailbox, uid: uid)), uid: uid)
    }
    public func send(_ draft: MailDraft, config: MailConfiguration) async throws {
        _ = try await request(config, url: config.url(smtp: true), draft: draft)
    }
}
