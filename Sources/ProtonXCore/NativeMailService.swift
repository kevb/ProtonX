import Foundation
import Darwin

public enum NativeMailPhase: String, Codable, Sendable {
    case welcome, locked, connected, totp, mailboxPassword = "mailbox_password", securityKey = "security_key"
}
public struct NativeMailFolder: Codable, Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let name: String
    public let count: UInt64
    public init(id: UInt64, name: String, count: UInt64 = 0) { self.id = id; self.name = name; self.count = count }
}
public struct NativeMailMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let subject: String
    public let sender: String
    public let senderName: String
    public let recipient: String
    public let date: UInt64
    public let unread: Bool
    public let attachments: Int
    public let isDraft: Bool?
    public let canReply: Bool?
    public let isScheduled: Bool?
    public init(id: UInt64, subject: String, sender: String, senderName: String = "", recipient: String = "", date: UInt64 = 0, unread: Bool = false, attachments: Int = 0, isDraft: Bool = false, canReply: Bool = true, isScheduled: Bool = false) {
        self.id = id; self.subject = subject; self.sender = sender; self.senderName = senderName
        self.recipient = recipient; self.date = date; self.unread = unread; self.attachments = attachments; self.isDraft = isDraft; self.canReply = canReply; self.isScheduled = isScheduled
    }
}
public struct NativeMailResult: Codable, Sendable {
    public var phase: NativeMailPhase?
    public var folders: [NativeMailFolder]?
    public var folder: UInt64?
    public var messages: [NativeMailMessage]?
    public var loading: Bool?
    public var email: String?
    public var id: UInt64?
    public var body: String?
    public var attachments: Int?
    public var draft: NativeMailDraft?
    public var token: UInt64?
    public var sendState: NativeMailSendState?
    public var closed: Bool?
    public var cacheFirst: Bool?
    public var fresh: Bool?
    public var refreshFailed: Bool?
    public init(phase: NativeMailPhase? = nil, folders: [NativeMailFolder]? = nil, folder: UInt64? = nil, messages: [NativeMailMessage]? = nil, loading: Bool? = nil, email: String? = nil, id: UInt64? = nil, body: String? = nil, attachments: Int? = nil, draft: NativeMailDraft? = nil, token: UInt64? = nil, sendState: NativeMailSendState? = nil, closed: Bool? = nil, cacheFirst: Bool? = nil, fresh: Bool? = nil, refreshFailed: Bool? = nil) {
        self.phase = phase; self.folders = folders; self.folder = folder; self.messages = messages
        self.loading = loading; self.email = email; self.id = id; self.body = body; self.attachments = attachments
        self.draft = draft; self.token = token; self.sendState = sendState; self.closed = closed
        self.cacheFirst = cacheFirst; self.fresh = fresh; self.refreshFailed = refreshFailed
    }
}
public enum NativeMailFailure: String, Codable, Error, LocalizedError, Sendable {
    case initializationFailed = "initialization_failed", invalidState = "invalid_state", invalidInput = "invalid_input"
    case incorrectCode = "incorrect_code", mailboxPasswordRejected = "mailbox_password_rejected"
    case signInRejected = "sign_in_rejected", signInFailed = "sign_in_failed", accountUnavailable = "account_unavailable"
    case verificationRequired = "verification_required", passwordChangeRequired = "password_change_required"
    case sessionFailed = "session_failed", sessionExpired = "session_expired", signOutFailed = "sign_out_failed"
    case invalidSelection = "invalid_selection", messageFailed = "message_failed", decryptionFailed = "decryption_failed"
    case messageTooLarge = "message_too_large", snapshotFailed = "snapshot_failed", pageLimit = "page_limit"
    case draftFailed = "draft_failed", draftUnsupported = "draft_unsupported", senderUnavailable = "sender_unavailable"
    case sendUncertain = "send_uncertain", sendRejected = "send_rejected"
    case storageUnavailable = "storage_unavailable", storageKeyMissing = "storage_key_missing", storageUpgradeRequired = "storage_upgrade_required"
    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: "Mail’s local storage could not open safely. Your saved files have been retained. Close other ProtonX copies and check Keychain access."
        case .storageKeyMissing: "Mail’s storage key is missing from this Mac’s Keychain. Your saved files have been retained; a replacement key will not be created."
        case .storageUpgradeRequired: "This experimental build requires an encrypted Mail database. Existing storage has been retained. Continue using your current build until the storage upgrade is ready."
        case .draftFailed: "Your draft could not complete this operation. Your text is still in the composer."
        case .draftUnsupported: "This draft contains content this composer cannot safely edit. Use the official client."
        case .senderUnavailable: "That sending address is unavailable. Check your Gmail connection or select an enabled address."
        case .sendRejected: "Proton could not queue this message. Check your sender and recipients before trying again."
        case .sendUncertain: "Sending could not be confirmed. Check Sent and Drafts before sending again; ProtonX will not retry automatically."
        case .initializationFailed: "Mail could not open its secure local session. Check Keychain access and try again."
        case .incorrectCode: "That verification code was rejected. Try a fresh code."
        case .mailboxPasswordRejected: "Mail could not unlock your account keys with that mailbox password."
        case .signInRejected: "Proton could not complete sign-in. Check your credentials and try again."
        case .signInFailed: "Mail sign-in could not finish. Check your connection and try again."
        case .accountUnavailable: "This account cannot open Mail. Proton’s account and product limits still apply."
        case .verificationRequired: "Proton requires human verification. This native build cannot complete that challenge yet. Cancel and use the official client for now."
        case .passwordChangeRequired: "This account requires a password change. Complete it with Proton before signing in here."
        case .sessionExpired: "Your Mail session needs sign-in again."
        case .sessionFailed: "Mail could not restore its session. Try again or sign in again."
        case .signOutFailed: "Sign-out could not be confirmed. Your saved session has been retained; retry when connected."
        case .decryptionFailed: "Proton’s Mail core could not decrypt this message."
        case .messageTooLarge: "This message exceeds the reader’s current size limit."
        case .messageFailed: "The message could not load. Try selecting it again."
        case .snapshotFailed: "Your inbox could not refresh. Retry when connected."
        case .pageLimit: "This window has loaded 1,000 messages. Further paging will be available in a later update."
        case .invalidInput: "Check the information you entered and try again."
        case .invalidSelection, .invalidState: "Mail’s state changed. Unlock or refresh and try again."
        }
    }
}

public struct NativeMailCommand: Encodable, Sendable {
    public let method: String
    public var username: String?
    public var password: String?
    public var code: String?
    public var folder: UInt64?
    public var item: UInt64?
    public var more: Bool?
    public var mode: String?
    public var token: UInt64?
    public var content: NativeMailComposeContent?
    public init(_ method: String, username: String? = nil, password: String? = nil, code: String? = nil, folder: UInt64? = nil, item: UInt64? = nil, more: Bool? = nil, mode: String? = nil, token: UInt64? = nil, content: NativeMailComposeContent? = nil) {
        self.method = method; self.username = username; self.password = password; self.code = code
        self.folder = folder; self.item = item; self.more = more
        self.mode = mode; self.token = token; self.content = content
    }
}
public protocol NativeMailRunning: Sendable {
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult
    func cancelAll()
}

/// One private, serial helper connection per unlocked Mail window. No secret-bearing argv or logs.
public final class NativeMailProcess: NativeMailRunning, @unchecked Sendable {
    private struct Connection: Sendable { let process: Process; let input: FileHandle; let output: FileHandle }
    private let executable: URL
    private let directory: URL
    private let deadline: Duration
    private let lock = NSLock()
    private let gate = CommandGate()
    private var connection: Connection?
    private var generation: UInt64 = 0
    private var nextID: UInt64 = 0
    public init(executable: URL, directory: URL, deadline: Duration = .seconds(120)) { self.executable = executable; self.directory = directory; self.deadline = deadline }
    public func cancelAll() {
        let previous = lock.withLock { generation &+= 1; let old = connection; connection = nil; return old }
        if let previous { Self.stop(previous) }
    }
    private func cancelGeneration(_ captured: UInt64) {
        let previous = lock.withLock { () -> Connection? in
            guard generation == captured else { return nil }
            generation &+= 1; let old = connection; connection = nil; return old
        }
        if let previous { Self.stop(previous) }
    }
    deinit { cancelAll() }
    private static func stop(_ connection: Connection) {
        try? connection.input.close()
        if connection.process.isRunning {
            connection.process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if connection.process.isRunning { kill(connection.process.processIdentifier, SIGKILL) }
            }
        }
    }
    private func connect(captured: UInt64) throws -> Connection {
        try lock.withLock {
            guard generation == captured else { throw CancellationError() }
            if let connection, connection.process.isRunning { return connection }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ProtonXError.helperMissing }
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = executable; process.arguments = []
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PROTONX_MAIL_DIR": directory.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let created = Connection(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
            connection = created
            return created
        }
    }
    public func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        let captured = lock.withLock { generation }
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let channel = try connect(captured: captured)
            let id = lock.withLock { nextID &+= 1; return nextID }
            struct Packet: Encodable { let schema = 1; let id: UInt64; let command: NativeMailCommand }
            var data = try JSONEncoder().encode(Packet(id: id, command: command)); data.append(10)
            let packetData = data
            guard packetData.count <= 64 * 1024 else { throw ProtonXError.outputTooLarge }
            let watchdog = Task.detached { [deadline] in
                try? await Task.sleep(for: deadline)
                if !Task.isCancelled { Self.stop(channel) }
            }
            defer { watchdog.cancel() }
            let output: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { try channel.input.write(contentsOf: packetData); continuation.resume(returning: try Self.readLine(channel.output)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            guard lock.withLock({ generation == captured }) else { throw CancellationError() }
            let result = try Self.decode(output, expectedID: id)
            await gate.release()
            return result
        } catch {
            // A typed request failure leaves the SDK flow alive (e.g. retrying a TOTP).
            // A consumed response from a deselected item leaves framing intact.
            // An older failed request must not cancel a newly unlocked generation.
            if !(error is NativeMailFailure) && !(error is CancellationError) { cancelGeneration(captured) }
            await gate.release()
            throw error
        }
    }
    private static func readLine(_ handle: FileHandle) throws -> Data {
        var result = Data()
        while true {
            var bytes = [UInt8](repeating: 0, count: 32768)
            var count: Int
            repeat { count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
            guard count > 0 else { throw ProtonXError.invalidResponse }
            result.append(contentsOf: bytes.prefix(count))
            guard result.count <= 8 * 1024 * 1024 else { throw ProtonXError.outputTooLarge }
            if let newline = result.firstIndex(of: 10) {
                guard newline == result.index(before: result.endIndex) else { throw ProtonXError.invalidResponse }
                return Data(result.prefix(upTo: newline))
            }
        }
    }
    public static func decode(_ data: Data, expectedID: UInt64) throws -> NativeMailResult {
        struct Reply: Decodable { let schema: Int; let id: UInt64; let result: NativeMailResult?; let failure: NativeMailFailure? }
        guard data.count <= 8 * 1024 * 1024 else { throw ProtonXError.outputTooLarge }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.schema == 1, reply.id == expectedID, (reply.result == nil) != (reply.failure == nil) else { throw ProtonXError.invalidResponse }
        if let failure = reply.failure { throw failure }
        guard let result = reply.result, (result.messages?.count ?? 0) <= 1000, (result.folders?.count ?? 0) <= 1024, (result.body?.utf8.count ?? 0) <= 2 * 1024 * 1024 else { throw ProtonXError.invalidResponse }
        guard result.fresh != true || (result.loading != true && result.refreshFailed != true) else { throw ProtonXError.invalidResponse }
        if let messages = result.messages { guard Set(messages.map(\.id)).count == messages.count else { throw ProtonXError.invalidResponse } }
        if let draft = result.draft {
            guard draft.token > 0, draft.senders.count <= 256, Set(draft.senders).count == draft.senders.count,
                  draft.senders.contains(draft.sender), draft.quote.utf8.count <= 2 * 1024 * 1024,
                  draft.attachments >= 0 else { throw ProtonXError.invalidResponse }
            try draft.content.validate(senders: draft.senders, sending: false)
        }
        return result
    }
}
