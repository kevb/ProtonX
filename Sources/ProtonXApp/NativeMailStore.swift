import SwiftUI
import LocalAuthentication
import ProtonXCore

@MainActor
final class NativeMailStore: ObservableObject {
    struct ListActionIntent {
        let action: NativeMailAction
        let item: UInt64
        let folder: UInt64
        let conversation: UInt64?
        let subject: String
        fileprivate let session: UInt64
        fileprivate let selection: UInt64?
        fileprivate let conversations: Bool
        var title: String { conversation == nil ? "Move message to Trash?" : "Move this whole conversation to Trash?" }
        var actionTitle: String {
            let scope = conversation == nil ? "message" : "conversation"
            switch action {
            case .read: return "Mark \(scope) as Read"
            case .unread: return "Mark \(scope) as Unread"
            case .archive: return "Move \(scope) to Archive"
            case .trash: return "Move \(scope) to Trash"
            case .spam: return "Move \(scope) to Spam"
            case .inbox: return "Move \(scope) to Inbox"
            }
        }
    }
    enum Phase: Equatable { case welcome, locked, signingIn, totp, mailboxPassword, securityKey, open }
    @Published private(set) var contacts: [ContactEntry] = []
    @Published private(set) var contactsLoaded = false
    @Published private(set) var contactsBusy = false
    @Published private(set) var contactsError: String?
    @Published private(set) var contactDetail: ContactDetail?
    @Published private(set) var contactDetailBusy = false
    @Published private(set) var contactDetailError: String?
    @Published var contactsQuery = ""
    @Published var selectedContact: String?
    private var contactsTask: Task<Void, Never>?, contactDetailTask: Task<Void, Never>?
    private var contactListEpoch = SessionEpoch(), contactDetailEpoch = SessionEpoch()
    var visibleContacts: [ContactEntry] { contacts.filter { $0.matches(contactsQuery) }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } }
    var currentContact: ContactEntry? { visibleContacts.first { $0.id == selectedContact } }
    @Published private(set) var phase: Phase = .welcome
    @Published private(set) var folders: [NativeMailFolder] = []
    @Published private(set) var messages: [NativeMailMessage] = []
    @Published private(set) var attachmentList: [NativeMailAttachment] = []
    @Published private(set) var attachmentBusy = false
    @Published private(set) var attachmentNeedsRefresh = false
    @Published private(set) var attachmentStatus: String?
    @Published private(set) var attachmentError: String?
    @Published var attachmentPreview: MailAttachmentPreview?
    private var attachmentTask: Task<Void, Never>?
    private var attachmentEpoch = SessionEpoch()
    private var draftAttachmentPolling: Task<Void, Never>?
    @Published private(set) var body: String?
    @Published private(set) var sanitizedHTML: String?
    @Published private(set) var thread: NativeMailThread?
    @Published private(set) var expandedThreadItem: UInt64?
    @Published private(set) var threadLoading = false
    @Published private(set) var threadError: String?
    @Published var conversationView = true
    @Published private(set) var email = ""
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    @Published private(set) var backgroundSyncing = false
    @Published private(set) var backgroundSyncActive = false
    @Published private(set) var showingSavedContent = false
    @Published private(set) var cacheRefreshFailed = false
    @Published private(set) var syncWarning: String?
    @Published private(set) var lastSynced: Date?
    @Published private(set) var demo = false
    @Published var selectedFolder: UInt64?
    @Published var selectedItem: UInt64?
    @Published var query = ""
    @Published private(set) var searchQuery: String?
    @Published private(set) var searchHasMore = false
    private var searchReturnFolder: UInt64?
    @Published var error: String?
    @Published private(set) var draft: NativeMailDraft? {
        didSet {
            guard let draft else { editorState = nil; attachmentNeedsRefresh = false; draftAttachmentPolling?.cancel(); return }
            if editorState?.token != draft.token { attachmentNeedsRefresh = false; editorState = MailEditorState(draft: draft) }
        }
    }
    @Published private(set) var editorState: MailEditorState?
    @Published private(set) var composeStatus: String?
    @Published private(set) var notice: String?
    @Published private(set) var messageActions: [NativeMailAction] = []
    @Published private(set) var mustRefreshBeforeActions = false
    @Published private(set) var undoToken: UInt64?
    private var undoExpiry: Date?
    private var undoExpiration: Task<Void, Never>?
    private var demoLocations: [UInt64: UInt64] = [:]
    private var demoUndo: (messages: [NativeMailMessage], locations: [UInt64: UInt64])?
    private var notificationTask: Task<Void, Never>?
    private var notificationEpoch = SessionEpoch()
    private var notifications: NativeNotifications?
    private var notificationInterval: Duration = .seconds(5)
    private var lastKnownUnread: UInt64?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var periodicRefreshTask: Task<Void, Never>?
    private var lockedSyncTask: Task<Void, Never>?
    private var lockedSyncEpoch = SessionEpoch()
    private var backgroundSyncInterval: Duration = .seconds(60)
    private(set) var lockedSyncEnabled = false
    private var helperSessionActive = false
    private var initialSyncPending = false
    private struct RetainedMailState {
        let folders: [NativeMailFolder]
        let messages: [NativeMailMessage]
        let selectedFolder: UInt64?
        let loadedFolder: UInt64?
        let selectedItem: UInt64?
        let email: String
        let lastSynced: Date?
        let contacts: [ContactEntry]
        let contactsLoaded: Bool
    }
    private var retainedState: RetainedMailState?
    private var sendPolling: Task<Void, Never>?
    let previewOnly: Bool
    var accountHandoffGeneration: UInt64? { phase == .open && !demo && !previewOnly ? epoch.value : nil }
    var canConnectCalendar: Bool { accountHandoffGeneration != nil && !busy }
    func calendarHandoff() async throws -> AccountHandoff {
        guard let ticket = accountHandoffGeneration else { throw NativeCalendarFailure.handoffUnavailable }
        let result = try await runner.request(NativeMailCommand("calendar_handoff"))
        guard accountHandoffGeneration == ticket, !Task.isCancelled, let handoff = result.handoff else { throw CancellationError() }
        try handoff.validate(); return handoff
    }
    private let runner: any NativeMailRunning
    private let defaults: UserDefaults
    let localAuthentication: LocalUnlockAuthentication
    private var epoch = SessionEpoch(), selectionEpoch = SessionEpoch()
    private var operation: Task<Void, Never>?, selection: Task<Void, Never>?, polling: Task<Void, Never>?
    private var hasSession: Bool
    private var loadedFolder: UInt64?
    private var cacheFirstActive = false
    private var demoMessages: [NativeMailMessage] = []
    private var demoHTML: [UInt64: String] = [:]
    private var demoBodies: [UInt64: String] = [:]
    init(runner: (any NativeMailRunning)? = nil, defaults: UserDefaults = .standard, previewOnly: Bool = false, localUnlock: (@MainActor @Sendable () async throws -> Bool)? = nil) {
        self.defaults = defaults; self.previewOnly = previewOnly; self.localAuthentication = LocalUnlockAuthentication(evaluate: localUnlock)
        self.runner = runner ?? NativeMailProcess(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/protonx-mail"), directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ProtonX/Mail"))
        hasSession = !previewOnly && defaults.bool(forKey: "nativeMailConnected")
        phase = hasSession ? .locked : .welcome
        if previewOnly { enterDemo() }
    }
    var visibleMessages: [NativeMailMessage] {
        if searchQuery != nil { return messages }
        return messages.filter { query.isEmpty || $0.subject.localizedStandardContains(query) || $0.sender.localizedStandardContains(query) || $0.senderName.localizedStandardContains(query) }
    }
    var visibleConversations: [NativeMailConversation] {
        let groups = conversationView ? NativeMailConversation.group(messages) : NativeMailConversation.individual(messages)
        return searchQuery == nil ? groups.filter { $0.matches(query) } : groups
    }
    var selectedAnchor: NativeMailMessage? { visibleConversations.flatMap(\.messages).first { $0.id == selectedItem } }
    var selectedMessage: NativeMailMessage? {
        guard let anchor = selectedAnchor else { return nil }
        if let thread { return thread.messages.first { $0.id == expandedThreadItem } }
        return anchor
    }
    var isLoadingList: Bool { phase == .open && !demo && (loading || (busy && (loadedFolder == nil || loadedFolder != selectedFolder))) }
    var initialListFailed: Bool { phase == .open && !demo && !busy && error != nil && (loadedFolder == nil || loadedFolder != selectedFolder) }
    var isSyncing: Bool { phase == .open && !demo && (busy || loading || backgroundSyncing || initialSyncPending) }
    var syncingStatusLabel: String {
        if showingSavedContent && isSyncing { return "Syncing saved mail…" }
        if initialSyncPending && messages.isEmpty { return "Checking for mail…" }
        return "Syncing…"
    }
    func signIn(username: String, password: String) {
        guard !previewOnly, !busy, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        if demo { lock(); demo = false }
        perform { [self] captured in
            phase = .signingIn
            let result = try await runner.request(NativeMailCommand("login", username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password))
            try check(captured); try await applyAuthentication(result, captured: captured)
        }
    }
    func submitChallenge(_ value: String) {
        guard !previewOnly, !busy else { return }
        let command: NativeMailCommand
        switch phase {
        case .totp: command = NativeMailCommand("totp", code: value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .mailboxPassword: command = NativeMailCommand("mailbox_password", password: value)
        default: return
        }
        perform { [self] captured in
            let result = try await runner.request(command)
            try check(captured); try await applyAuthentication(result, captured: captured)
        }
    }
    func unlock(mode: LocalUnlockAuthentication.Mode = .system) {
        if mode == .system && localAuthentication.state == .authenticating && localAuthentication.mode == .touchID { cancelLocalUnlock() }
        guard !busy, !previewOnly else { return }
        if demo { enterDemo(); return }
        perform { [self] captured in
            let allowed = try await localAuthentication.authenticate(mode, reason: "Unlock ProtonX Mail on this Mac")
            guard allowed else { throw ProtonXError.cancelled }
            try check(captured)
            if helperSessionActive {
                stopLockedBackgroundSync(keepHelper: true)
                do {
                    try await applyAuthentication(.init(phase: .connected, cacheFirst: cacheFirstActive), captured: captured, preserveDeliveredNotifications: true)
                    return
                } catch {
                    try check(captured)
                    if (error as? NativeMailFailure) == .sessionExpired { throw error }
                    helperSessionActive = false
                }
            }
            let result = try await runner.request(NativeMailCommand("restore"))
            try check(captured); try await applyAuthentication(result, captured: captured)
        }
    }
    /// Restores Mail's independent saved session after macOS local authentication
    /// already succeeded in a linked product (Calendar). Never runs in preview/demo or while suspended.
    func unlockLinked() {
        guard !busy, !previewOnly, !demo, phase == .locked, !localAuthentication.systemSuspended else { return }
        perform { [self] captured in
            if helperSessionActive {
                stopLockedBackgroundSync(keepHelper: true)
                do {
                    try await applyAuthentication(.init(phase: .connected, cacheFirst: cacheFirstActive), captured: captured, preserveDeliveredNotifications: true)
                    return
                } catch {
                    try check(captured)
                    if (error as? NativeMailFailure) == .sessionExpired { throw error }
                    helperSessionActive = false
                }
            }
            let result = try await runner.request(NativeMailCommand("restore"))
            try check(captured); try await applyAuthentication(result, captured: captured)
        }
    }
    private func applyAuthentication(_ result: NativeMailResult, captured: UInt64, preserveDeliveredNotifications: Bool = false) async throws {
        switch result.phase {
        case .totp: phase = .totp
        case .mailboxPassword: phase = .mailboxPassword
        case .securityKey: phase = .securityKey
        case .connected:
            hasSession = true; helperSessionActive = true; defaults.set(true, forKey: "nativeMailConnected"); phase = .open
            syncWarning = nil
            cacheFirstActive = result.cacheFirst == true
            if let retained = retainedState {
                retainedState = nil
                folders = retained.folders; messages = retained.messages
                selectedFolder = retained.selectedFolder; loadedFolder = retained.loadedFolder
                selectedItem = retained.selectedItem; email = retained.email
                lastSynced = retained.lastSynced
                contacts = retained.contacts; contactsLoaded = retained.contactsLoaded
                initialSyncPending = false
                restartNotifications(preserveDelivered: preserveDeliveredNotifications)
                startPeriodicRefresh()
                // Return immediately so the inbox renders in 0ms, then reload any selected
                // message body and run a non-blocking live sync in the background.
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.epoch.accepts(captured), self.phase == .open else { return }
                    if self.selectedItem != nil { self.select() }
                    self.backgroundRefresh()
                }
                return
            }
            initialSyncPending = true
            restartNotifications(preserveDelivered: preserveDeliveredNotifications)
            startPeriodicRefresh()
            try await load(captured: captured, mode: cacheFirstActive ? "local" : nil)
        default: throw ProtonXError.invalidResponse
        }
    }
    func searchAllMail() {
        let keywords = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .open, !busy, MailSearchPolicy.valid(keywords) else { return }
        if searchQuery == nil { searchReturnFolder = selectedFolder }
        query = keywords; searchQuery = keywords; searchHasMore = false
        clearActionUndo(); polling?.cancel(); clearThread(); selectedItem = nil; body = nil; sanitizedHTML = nil; messageActions = []
        selectionEpoch.invalidate(); selection?.cancel(); loadedFolder = nil; messages = []
        if demo {
            messages = demoMessages.filter { $0.subject.localizedStandardContains(keywords) || $0.sender.localizedStandardContains(keywords) || $0.senderName.localizedStandardContains(keywords) || $0.recipient.localizedStandardContains(keywords) }
            loadedFolder = selectedFolder; return
        }
        perform { [self] captured in try await load(captured: captured) }
    }
    func searchTextChanged() {
        if let searchQuery, query != searchQuery, !busy { endSearch() }
        reconcileSelection()
    }
    func endSearch() {
        guard searchQuery != nil, !busy else { return }
        let folder = searchReturnFolder
        searchQuery = nil; searchReturnFolder = nil; searchHasMore = false
        clearThread(); selectedItem = nil; body = nil; sanitizedHTML = nil; messageActions = []
        selectionEpoch.invalidate(); selection?.cancel(); messages = []; loadedFolder = nil; selectedFolder = folder
        if demo { messages = demoMessages.filter { demoLocations[$0.id] == selectedFolder }; loadedFolder = selectedFolder }
        else { refresh() }
    }
    func refresh(more: Bool = false) {
        guard phase == .open, !demo, !busy else { return }
        perform { [self] captured in
            let preferred = selectedMessage?.id
            try await load(captured: captured, more: more, mode: cacheFirstActive ? "refresh" : nil)
            if thread != nil { select(preferred: preferred, preservingContent: true) }
        }
    }
    private func load(captured: UInt64, more: Bool = false, mode: String? = nil) async throws {
        let folder = selectedFolder
        let mode = mode ?? (cacheFirstActive ? "refresh" : nil)
        let keywords = searchQuery
        let result = try await runner.request(NativeMailCommand("snapshot", folder: keywords == nil ? folder : nil, more: more, mode: keywords == nil ? mode : nil, keywords: keywords))
        try check(captured)
        guard selectedFolder == folder, searchQuery == keywords else { return }
        if let keywords {
            guard result.searchQuery == keywords, let nextMessages = result.messages, let nextFolder = result.folder, let moreResults = result.hasMore else { throw ProtonXError.invalidResponse }
            if !folders.contains(where: { $0.id == nextFolder }) { folders.append(.init(id: nextFolder, name: "All mail")) }
            messages = nextMessages; selectedFolder = nextFolder; loadedFolder = nextFolder
            searchHasMore = moreResults; loading = false; showingSavedContent = false; cacheRefreshFailed = false
            if let email = result.email { self.email = email }
            polling?.cancel(); reconcileSelection(); return
        }
        guard let nextFolders = result.folders, let nextMessages = result.messages, let nextFolder = result.folder, nextFolders.contains(where: { $0.id == nextFolder }) else { throw ProtonXError.invalidResponse }
        folders = nextFolders; messages = nextMessages; selectedFolder = nextFolder; loadedFolder = nextFolder
        email = result.email ?? ""; loading = result.loading ?? false
        showingSavedContent = cacheFirstActive && result.fresh != true
        cacheRefreshFailed = result.refreshFailed == true
        if cacheRefreshFailed {
            initialSyncPending = false
            syncWarning = "Offline · showing saved mail"
            error = "Could not refresh. Showing saved Mail content; retry when connected."
        }
        if cacheFirstActive ? result.fresh == true : !loading {
            lastSynced = Date(); mustRefreshBeforeActions = false; initialSyncPending = false; syncWarning = nil
        }
        reconcileSelection()
        // Read saved rows first, then refresh once. Later polls read status only.
        // Lock and folder changes invalidate any scheduled work.
        polling?.cancel()
        if loading || (cacheFirstActive && mode == "local") {
            let nextMode: String? = cacheFirstActive ? (mode == "local" ? "refresh" : "poll") : nil
            let expectedFolder = nextFolder
            polling = Task { [weak self] in
                try? await Task.sleep(for: self?.cacheFirstActive == true ? (mode == "local" ? .milliseconds(300) : .seconds(1)) : .seconds(3))
                while self?.busy == true && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                guard let self, !Task.isCancelled, self.epoch.accepts(captured), self.phase == .open else { return }
                guard self.selectedFolder == expectedFolder else { return }
                self.perform { [self] current in try await load(captured: current, mode: nextMode) }
            }
        }
    }
    func changeFolder() {
        guard selectedFolder != loadedFolder else { return }
        if searchQuery != nil { searchQuery = nil; searchHasMore = false; searchReturnFolder = nil; query = "" }
        clearThread(); body = nil; sanitizedHTML = nil; messageActions = []; selectedItem = nil; selectionEpoch.invalidate(); selection?.cancel()
        messages = []
        if demo { messages = demoMessages.filter { demoLocations[$0.id] == selectedFolder }; loadedFolder = selectedFolder; return }
        if cacheFirstActive {
            perform { [self] captured in try await load(captured: captured, mode: "local") }
        } else { refresh() }
    }
    func reconcileSelection() {
        if let selectedItem, !visibleConversations.contains(where: { $0.messages.contains(where: { $0.id == selectedItem }) }) {
            clearThread()
            self.selectedItem = nil; body = nil; sanitizedHTML = nil; messageActions = []; selectionEpoch.invalidate(); selection?.cancel()
        }
    }
    private func clearThread() { clearAttachments(); thread = nil; expandedThreadItem = nil; threadLoading = false; threadError = nil }
    func select(preferred: UInt64? = nil, preservingContent: Bool = false) {
        if !preservingContent { clearThread(); body = nil; sanitizedHTML = nil }
        messageActions = []; error = nil; threadError = nil; selectionEpoch.invalidate(); selection?.cancel()
        guard let anchor = selectedAnchor else { clearThread(); return }
        let item = anchor.id
        if demo {
            if conversationView, let conversation = anchor.conversationID {
                let members = demoMessages.filter { $0.conversationID == conversation && (selectedFolder == 4 ? demoLocations[$0.id] == 4 : demoLocations[$0.id] != 4) }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
                thread = NativeMailThread(anchor: item, conversationID: conversation, messages: members)
            } else { thread = nil }
            let chosen = preferred.flatMap { id in thread?.messages.contains(where: { $0.id == id }) == true ? id : nil } ?? item
            expandedThreadItem = chosen; setDemoAttachments(chosen); body = demoBodies[chosen]; sanitizedHTML = demoHTML[chosen]; setDemoActions(); return
        }
        guard let folder = selectedFolder, phase == .open else { return }
        threadLoading = conversationView && anchor.conversationID != nil
        let captured = epoch.value, selectedGeneration = selectionEpoch.value
        selection = Task { [self] in
            do {
                if conversationView, let conversation = anchor.conversationID {
                    do {
                        let result = try await runner.request(NativeMailCommand("thread", folder: folder, item: item))
                        try checkSelection(captured: captured, generation: selectedGeneration, anchor: item, folder: folder)
                        guard let next = result.thread, next.anchor == item, next.conversationID == conversation else { throw ProtonXError.invalidResponse }
                        try next.validate(); thread = next
                    } catch {
                        try checkSelection(captured: captured, generation: selectedGeneration, anchor: item, folder: folder)
                        if (error as? NativeMailFailure) == .sessionExpired { throw error }
                        thread = nil; threadError = safeError(error)
                    }
                } else { thread = nil }
                let chosen = preferred.flatMap { id in thread?.messages.contains(where: { $0.id == id }) == true ? id : nil } ?? item
                if expandedThreadItem != chosen { body = nil; sanitizedHTML = nil }
                expandedThreadItem = chosen; threadLoading = false
                try await loadBody(item: chosen, anchor: item, folder: folder, captured: captured, generation: selectedGeneration)
            } catch {
                if !Task.isCancelled && epoch.accepts(captured) && selectionEpoch.accepts(selectedGeneration) {
                    threadLoading = false
                    if (error as? NativeMailFailure) == .sessionExpired { expireSession() }
                    self.error = safeError(error)
                }
            }
        }
    }
    func expandThreadMessage(_ item: UInt64) {
        guard !threadLoading, thread?.messages.contains(where: { $0.id == item }) == true,
              let anchor = selectedItem, let folder = selectedFolder else { return }
        clearAttachments(); selectionEpoch.invalidate(); selection?.cancel(); messageActions = []; body = nil; sanitizedHTML = nil; error = nil
        if expandedThreadItem == item { expandedThreadItem = nil; return }
        expandedThreadItem = item
        if demo { setDemoAttachments(item); body = demoBodies[item]; sanitizedHTML = demoHTML[item]; setDemoActions(); return }
        let captured = epoch.value, generation = selectionEpoch.value
        selection = Task { [self] in
            do { try await loadBody(item: item, anchor: anchor, folder: folder, captured: captured, generation: generation) }
            catch {
                guard !Task.isCancelled, epoch.accepts(captured), selectionEpoch.accepts(generation) else { return }
                if (error as? NativeMailFailure) == .sessionExpired { expireSession() }
                self.error = safeError(error)
            }
        }
    }
    private func checkSelection(captured: UInt64, generation: UInt64, anchor: UInt64, folder: UInt64) throws {
        try check(captured)
        guard selectionEpoch.accepts(generation), selectedItem == anchor, selectedFolder == folder else { throw CancellationError() }
    }
    private func loadBody(item: UInt64, anchor: UInt64, folder: UInt64, captured: UInt64, generation: UInt64) async throws {
        let result = try await runner.request(NativeMailCommand("message", folder: folder, item: item))
        try checkSelection(captured: captured, generation: generation, anchor: anchor, folder: folder)
        guard expandedThreadItem == item, result.id == item, let next = result.body else { throw ProtonXError.invalidResponse }
        body = next; sanitizedHTML = result.sanitizedHTML; messageActions = result.actions ?? []; attachmentList = result.attachmentList ?? []; try MailAttachmentPolicy.validateList(attachmentList)
    }
    var canUndoAction: Bool { undoToken != nil && (undoExpiry ?? .distantPast) > Date() && !busy && !mustRefreshBeforeActions && draft == nil }
    // Menu presentation follows Proton WebClients' useLabelActions by SDK folder kind.
    // This is a UI hint; every write rechecks SDK capabilities and destinations.
    func listActions(for item: UInt64?) -> [NativeMailAction] {
        guard searchQuery == nil else { return [] }
        guard let item, let row = visibleConversations.first(where: { $0.messages.contains(where: { $0.id == item }) }),
              let folder = folders.first(where: { $0.id == selectedFolder }) else { return [] }
        let moves: [NativeMailAction]
        switch folder.kind ?? .other {
        case .inbox, .starred, .other: moves = [.trash, .archive, .spam]
        case .sent, .drafts, .pending: moves = [.trash, .archive]
        case .archive: moves = [.trash, .inbox, .spam]
        case .spam: moves = [.trash, .inbox]
        case .trash: moves = [.inbox, .archive]
        }
        return moves + [row.unread ? .read : .unread]
    }
    func trashIntent(for item: UInt64?) -> ListActionIntent? { listActionIntent(for: item, action: .trash) }
    func listActionIntent(for item: UInt64?, action: NativeMailAction) -> ListActionIntent? {
        guard phase == .open, !busy, !mustRefreshBeforeActions, draft == nil,
              let folder = selectedFolder, let item,
              listActions(for: item).contains(action),
              let message = visibleConversations.flatMap(\.messages).first(where: { $0.id == item }) else { return nil }
        return ListActionIntent(action: action, item: item, folder: folder, conversation: conversationView ? message.conversationID.flatMap { $0 > 0 ? $0 : nil } : nil,
                           subject: message.subject.isEmpty ? "(No subject)" : message.subject,
                           session: epoch.value, selection: selectedItem, conversations: conversationView)
    }
    func actFromList(_ intent: ListActionIntent) {
        guard epoch.accepts(intent.session), selectedItem == intent.selection,
              selectedFolder == intent.folder, conversationView == intent.conversations,
              let current = listActionIntent(for: intent.item, action: intent.action), current.conversation == intent.conversation else { return }
        clearActionUndo()
        selectionEpoch.invalidate(); selection?.cancel()
        if demo {
            let previous = (messages: demoMessages, locations: demoLocations)
            let items = demoMessages.filter { message in
                if let conversation = intent.conversation { return message.conversationID == conversation }
                return message.id == intent.item
            }
            let affected = Set(items.map(\.id))
            if intent.action == .read || intent.action == .unread || intent.action == .trash {
                demoMessages = demoMessages.map { message in
                    guard affected.contains(message.id) else { return message }
                    return NativeMailMessage(id: message.id, subject: message.subject, sender: message.sender, senderName: message.senderName, recipient: message.recipient, date: message.date, unread: intent.action == .unread, attachments: message.attachments, isDraft: message.isDraft ?? false, canReply: message.canReply ?? true, isScheduled: message.isScheduled ?? false, conversationID: message.conversationID)
                }
            }
            if intent.action != .read && intent.action != .unread {
                let location: UInt64 = intent.action == .trash ? 4 : (intent.action == .archive ? 3 : (intent.action == .spam ? 5 : 1))
                for message in items { demoLocations[message.id] = location }
            }
            messages = demoMessages.filter { demoLocations[$0.id] == selectedFolder }
            reconcileSelection(); if selectedAnchor != nil { select() }; setDemoActions()
            if intent.action != .read && intent.action != .unread { setActionUndo(1); demoUndo = previous }
            notice = intent.actionTitle + " · demo"; return
        }
        perform { [self] captured in
            mustRefreshBeforeActions = true
            let command = intent.conversation.map { NativeMailCommand("conversation_action", folder: intent.folder, item: intent.item, action: intent.action, conversation: $0) }
                ?? NativeMailCommand("message_action", folder: intent.folder, item: intent.item, action: intent.action)
            let result = try await runner.request(command)
            try check(captured)
            guard result.queued == true, result.id == intent.item,
                  result.conversationID == intent.conversation else { throw ProtonXError.invalidResponse }
            mustRefreshBeforeActions = false
            if let token = result.undoToken { setActionUndo(token) }
            notice = intent.actionTitle + " queued for sync"
            try await load(captured: captured)
            if selectedAnchor != nil && selectedFolder == intent.folder { select(preservingContent: true) }
        }
    }
    func canPerform(_ action: NativeMailAction) -> Bool {
        searchQuery == nil && phase == .open && !busy && !threadLoading && !mustRefreshBeforeActions && draft == nil && selectedMessage != nil && messageActions.contains(action)
    }
    func actOnMessage(_ action: NativeMailAction) {
        guard canPerform(action), let item = selectedMessage?.id, let folder = selectedFolder else { return }
        clearActionUndo()
        if demo {
            let previous = (messages: demoMessages, locations: demoLocations)
            if action == .read || action == .unread {
                demoMessages = demoMessages.map { message in
                    guard message.id == item else { return message }
                    return NativeMailMessage(id: message.id, subject: message.subject, sender: message.sender, senderName: message.senderName, recipient: message.recipient, date: message.date, unread: action == .unread, attachments: message.attachments, isDraft: message.isDraft ?? false, canReply: message.canReply ?? true, isScheduled: message.isScheduled ?? false, conversationID: message.conversationID)
                }
            } else { demoLocations[item] = action == .trash ? 4 : (action == .archive ? 3 : (action == .spam ? 5 : 1)) }
            messages = demoMessages.filter { demoLocations[$0.id] == selectedFolder }
            reconcileSelection(); if selectedAnchor != nil { select(preferred: item) }; setDemoActions()
            if action != .read && action != .unread { demoUndo = previous; setActionUndo(1) }
            notice = action.title + " · demo"
            return
        }
        perform { [self] captured in
            // Any interrupted dispatch may already have entered the durable SDK queue.
            mustRefreshBeforeActions = true
            let result = try await runner.request(NativeMailCommand("message_action", folder: folder, item: item, action: action))
            try check(captured)
            guard result.queued == true, result.id == item else { throw ProtonXError.invalidResponse }
            mustRefreshBeforeActions = false
            if let token = result.undoToken { setActionUndo(token) }
            notice = action.title + " queued for sync"
            try await load(captured: captured)
            if selectedAnchor != nil && selectedFolder == folder { select(preferred: item, preservingContent: true) }
        }
    }
    func undoMessageAction() {
        guard canUndoAction, let token = undoToken else { return }
        let preferred = selectedMessage?.id
        if demo, let previous = demoUndo {
            demoMessages = previous.messages; demoLocations = previous.locations
            messages = demoMessages.filter { demoLocations[$0.id] == selectedFolder }
            clearActionUndo(); if thread != nil { select(preferred: preferred) }; setDemoActions(); notice = "Change undone · demo"; return
        }
        clearActionUndo()
        perform { [self] captured in
            mustRefreshBeforeActions = true
            let result = try await runner.request(NativeMailCommand("undo_action", token: token))
            try check(captured)
            guard result.queued == true else { throw ProtonXError.invalidResponse }
            mustRefreshBeforeActions = false; notice = "Undo queued for sync"
            try await load(captured: captured)
            if thread != nil { select(preferred: preferred, preservingContent: true) }
        }
    }
    private func setActionUndo(_ token: UInt64) {
        undoToken = token; undoExpiry = Date().addingTimeInterval(30)
        let captured = epoch.value
        undoExpiration = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.epoch.accepts(captured), self.undoToken == token else { return }
            self.clearActionUndo()
        }
    }
    private func clearActionUndo() { undoExpiration?.cancel(); undoExpiration = nil; undoToken = nil; undoExpiry = nil; demoUndo = nil }
    func compose(_ mode: String = "new", recipients: [String] = []) {
        guard recipients.count <= 100, recipients.allSatisfy(ContactRecipients.valid) else { return }
        guard phase == .open, !busy, !threadLoading, draft == nil else { return }
        guard mode == "new" || selectedMessage != nil else { return }
        if mode == "open" { guard selectedMessage?.isDraft == true, selectedMessage?.isScheduled != true else { return } }
        if mode == "reply" || mode == "reply_all" { guard selectedMessage?.canReply != false else { return } }
        cancelAttachmentTransfer(); clearAttachmentPreview(); attachmentError = nil
        notice = nil; composeStatus = nil
        if demo {
            let reply = mode != "new" ? selectedMessage : nil
            let senders = [email, "alex.demo@gmail.com"]
            let ownMessage = reply.map { senders.contains($0.sender) } ?? false
            let sender = reply.flatMap { senders.contains($0.sender) ? $0.sender : (senders.contains($0.recipient) ? $0.recipient : nil) } ?? email
            let subject = reply.map { $0.subject.lowercased().hasPrefix("re:") ? $0.subject : "Re: " + $0.subject } ?? ""
            let quote = reply.map { "\n\n" + ($0.senderName.isEmpty ? $0.sender : $0.senderName) + " wrote:\n" + (demoBodies[$0.id] ?? "") } ?? "Alex"
            draft = NativeMailDraft(token: 1, sender: sender, senders: senders, to: reply.map { [ownMessage ? $0.recipient : $0.sender] } ?? [], subject: subject, quote: quote, state: .editing)
            editorState?.to = recipients.isEmpty ? (editorState?.to ?? "") : recipients.joined(separator: ", ")
            return
        }
        perform { [self] captured in
            let result = try await runner.request(NativeMailCommand("compose", folder: mode == "new" ? nil : selectedFolder, item: mode == "new" ? nil : selectedMessage?.id, mode: mode))
            try check(captured)
            guard let next = result.draft else { throw ProtonXError.invalidResponse }
            draft = next
            if !recipients.isEmpty { editorState?.to = recipients.joined(separator: ", ") }
            startDraftAttachmentPolling()
        }
    }
    func markDraftEdited() {
        if draft?.state == .editing { composeStatus = nil }
    }
    func saveDraft(_ content: NativeMailComposeContent, close: Bool = false) {
        guard phase == .open, !busy, !attachmentBusy, !attachmentNeedsRefresh, let draft, draft.state == .editing else { return }
        do { try content.validate(senders: draft.senders, sending: false) } catch { self.error = safeError(error); return }
        if demo { composeStatus = "Demo draft saved · no account accessed"; if close { self.draft = nil }; return }
        perform { [self] captured in
            let result = try await runner.request(NativeMailCommand("save_draft", token: draft.token, content: content))
            try check(captured)
            guard result.draft?.token == draft.token else { throw ProtonXError.invalidResponse }
            self.draft = result.draft; composeStatus = "Draft saved locally · syncing with Proton"
            if close {
                let closed = try await runner.request(NativeMailCommand("close_draft", token: draft.token))
                try check(captured); guard closed.closed == true else { throw ProtonXError.invalidResponse }
                self.draft = nil; notice = "Draft saved"; try await load(captured: captured)
            }
        }
    }
    func closePendingDraft() {
        guard phase == .open, !busy, let draft, draft.state != .editing else { return }
        sendPolling?.cancel()
        perform { [self] captured in
            do {
                let result = try await runner.request(NativeMailCommand("close_draft", token: draft.token))
                try check(captured); guard result.closed == true else { throw ProtonXError.invalidResponse }
            } catch {
                try check(captured)
                // A lost connection cannot cancel a queued send. Closing this local
                // composer never deletes a draft or creates another send action.
                self.error = safeError(error)
            }
            self.draft = nil; composeStatus = nil; notice = "Check Sent and Drafts · delivery was not confirmed"
        }
    }
    func discardDraft() {
        guard phase == .open, !busy, !attachmentBusy, !attachmentNeedsRefresh, let draft, draft.state == .editing else { return }
        if demo { self.draft = nil; return }
        perform { [self] captured in
            let result = try await runner.request(NativeMailCommand("discard_draft", token: draft.token))
            try check(captured); guard result.closed == true else { throw ProtonXError.invalidResponse }
            self.draft = nil; composeStatus = nil; try await load(captured: captured)
        }
    }
    func sendDraft(_ content: NativeMailComposeContent) {
        guard phase == .open, !busy, !attachmentBusy, !attachmentNeedsRefresh, let draft, draft.state == .editing else { return }
        guard (draft.attachmentList ?? []).allSatisfy({ $0.state == .uploaded }) else { error = NativeMailFailure.attachmentPending.localizedDescription; return }
        draftAttachmentPolling?.cancel()
        do { try content.validate(senders: draft.senders, sending: true) } catch { self.error = safeError(error); return }
        if demo { self.draft = nil; notice = "Demo message sent · nothing was delivered"; return }
        perform { [self] captured in
            // Sending is a deliberate user action. Once the IPC request starts,
            // an ambiguous outcome never becomes another send action automatically.
            self.draft?.state = .unknown; composeStatus = "Sending…"
            do {
                let result = try await runner.request(NativeMailCommand("send_draft", token: draft.token, content: content))
                try check(captured); try applySendResult(result, token: draft.token)
                if self.draft?.state == .queued { pollSend(token: draft.token, captured: captured) }
                if self.draft?.state == .sent { try await finishSent(token: draft.token, captured: captured) }
            } catch {
                if epoch.accepts(captured), !Task.isCancelled {
                    if [.sendRejected, .attachmentPending].contains(error as? NativeMailFailure) {
                        self.draft?.state = .editing; composeStatus = "Message was not queued. Correct the sender or recipients and try again."
                    } else {
                        composeStatus = "Sending could not be confirmed. Check Sent and Drafts before sending again."
                    }
                }
                throw error
            }
        }
    }
    private func applySendResult(_ result: NativeMailResult, token: UInt64) throws {
        guard result.token == token, let state = result.sendState, state != .editing, draft?.token == token else { throw ProtonXError.invalidResponse }
        draft?.state = state
        switch state {
        case .queued: composeStatus = "Sending · awaiting Proton’s confirmation"
        case .sent: composeStatus = "Sent"
        case .failed: composeStatus = "Proton reported a sending failure. Check the draft in the official client before trying again."
        case .unknown: composeStatus = "Sending could not be confirmed. Check Sent and Drafts before sending again."
        case .editing: break
        }
    }
    private func finishSent(token: UInt64, captured: UInt64) async throws {
        let result = try await runner.request(NativeMailCommand("close_draft", token: token))
        try check(captured); guard result.closed == true else { throw ProtonXError.invalidResponse }
        draft = nil; notice = "Message sent"; composeStatus = nil
        try await load(captured: captured)
    }
    private func pollSend(token: UInt64, captured: UInt64) {
        sendPolling?.cancel()
        sendPolling = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.epoch.accepts(captured), self.draft?.token == token else { return }
                do {
                    let result = try await self.runner.request(NativeMailCommand("draft_status", token: token))
                    try self.check(captured); try self.applySendResult(result, token: token)
                    if self.draft?.state == .sent { try await self.finishSent(token: token, captured: captured); return }
                    if self.draft?.state == .failed { return }
                } catch {
                    guard self.epoch.accepts(captured), !Task.isCancelled else { return }
                    self.draft?.state = .unknown; self.composeStatus = NativeMailFailure.sendUncertain.localizedDescription
                    if (error as? NativeMailFailure) == .sessionExpired { self.expireSession() }
                    return
                }
            }
            guard let self, self.epoch.accepts(captured), self.draft?.token == token else { return }
            self.draft?.state = .unknown; self.composeStatus = NativeMailFailure.sendUncertain.localizedDescription
        }
    }
    func checkSendStatus() {
        sendPolling?.cancel()
        guard phase == .open, !busy, let draft, draft.state != .editing else { return }
        perform { [self] captured in
            let result = try await runner.request(NativeMailCommand("draft_status", token: draft.token))
            try check(captured); try applySendResult(result, token: draft.token)
            if self.draft?.state == .sent { try await finishSent(token: draft.token, captured: captured) }
        }
    }
    func signOut() {
        guard !previewOnly, !demo, !busy, draft == nil else { return }
        perform { [self] captured in
            _ = try await runner.request(NativeMailCommand("sign_out")); try check(captured)
            hasSession = false; defaults.set(false, forKey: "nativeMailConnected"); lock(); phase = .welcome
        }
    }
    func configureNotifications(_ controller: NativeNotifications, interval: Duration = .seconds(5)) {
        notifications = controller; notificationInterval = interval
        controller.configurationChanged = { [weak self] in
            guard let self else { return }
            if self.phase == .open { self.restartNotifications() }
            else if self.phase == .locked && self.lockedSyncEnabled { self.startLockedBackgroundSync() }
        }
        if phase == .open { restartNotifications() }
        else if phase == .locked && lockedSyncEnabled { startLockedBackgroundSync() }
    }
    func configureBackgroundSync(whileLocked: Bool, interval: Duration = .seconds(60)) {
        let changed = lockedSyncEnabled != whileLocked || backgroundSyncInterval != interval
        lockedSyncEnabled = whileLocked
        backgroundSyncInterval = interval
        guard !previewOnly, !demo else { return }
        if phase == .open {
            if changed || periodicRefreshTask == nil { startPeriodicRefresh() }
        } else if phase == .locked && hasSession {
            if whileLocked {
                if !localAuthentication.systemSuspended { startLockedBackgroundSync() }
            } else {
                stopLockedBackgroundSync(keepHelper: false)
                notifications?.clearMail()
            }
        }
    }
    func setSystemSuspended(_ suspended: Bool) {
        let changed = localAuthentication.systemSuspended != suspended
        localAuthentication.systemSuspended = suspended
        guard changed, !previewOnly, !demo else { return }
        if suspended {
            // Pause background network/Keychain polling during sleep/screen lock without dropping UI state.
            lockedSyncEpoch.invalidate(); lockedSyncTask?.cancel(); lockedSyncTask = nil
            periodicRefreshTask?.cancel(); periodicRefreshTask = nil
        } else if phase == .locked && lockedSyncEnabled && hasSession {
            startLockedBackgroundSync()
        } else if phase == .open {
            startPeriodicRefresh()
            backgroundRefresh()
        }
    }
    func handleForegroundReturn() {
        guard phase == .open, !demo, !previewOnly else { return }
        if lastSynced == nil || Date().timeIntervalSince(lastSynced!) >= 30 {
            backgroundRefresh()
        }
    }
    func backgroundRefresh() {
        guard phase == .open, !demo, !previewOnly, !busy, !backgroundSyncing, !loading,
              draft == nil, searchQuery == nil, !mustRefreshBeforeActions else { return }
        let captured = epoch.value
        let folder = selectedFolder
        backgroundSyncing = true
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { [weak self] in
            defer {
                if let self, self.epoch.accepts(captured) { self.backgroundSyncing = false }
            }
            guard let self else { return }
            do {
                let mode = self.cacheFirstActive ? "refresh" : nil
                let result = try await self.runner.request(NativeMailCommand("snapshot", folder: folder, more: false, mode: mode))
                try self.check(captured)
                guard self.phase == .open, self.selectedFolder == folder, self.searchQuery == nil, self.draft == nil else { return }
                guard let nextFolders = result.folders, let nextMessages = result.messages, let nextFolder = result.folder,
                      nextFolders.contains(where: { $0.id == nextFolder }) else { throw ProtonXError.invalidResponse }
                self.folders = nextFolders; self.messages = nextMessages; self.selectedFolder = nextFolder; self.loadedFolder = nextFolder
                if let email = result.email { self.email = email }
                self.loading = result.loading ?? false
                self.showingSavedContent = self.cacheFirstActive && result.fresh != true
                self.cacheRefreshFailed = result.refreshFailed == true
                if self.cacheRefreshFailed {
                    self.initialSyncPending = false
                    self.syncWarning = "Offline · showing saved mail"
                } else if self.cacheFirstActive ? result.fresh == true : !self.loading {
                    self.lastSynced = Date(); self.mustRefreshBeforeActions = false; self.initialSyncPending = false; self.syncWarning = nil
                }
                self.reconcileSelection()
                if self.loading {
                    let expectedFolder = nextFolder
                    self.polling?.cancel()
                    self.polling = Task { [weak self] in
                        try? await Task.sleep(for: self?.cacheFirstActive == true ? .seconds(1) : .seconds(3))
                        guard let self, !Task.isCancelled, self.epoch.accepts(captured), self.phase == .open,
                              self.selectedFolder == expectedFolder, self.searchQuery == nil, self.draft == nil else { return }
                        if !self.busy && !self.backgroundSyncing {
                            self.pollBackgroundRefresh(captured: captured, expectedFolder: expectedFolder)
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled, self.epoch.accepts(captured), self.phase == .open else { return }
                if (error as? NativeMailFailure) == .sessionExpired { self.expireSession() }
                else if (error as? NativeMailFailure) == .invalidState || !(error is NativeMailFailure) {
                    // Recover cleanly if the background helper restarted while locked.
                    self.helperSessionActive = false
                    if let restored = try? await self.runner.request(NativeMailCommand("restore")),
                       !Task.isCancelled, self.epoch.accepts(captured), self.phase == .open, restored.phase == .connected {
                        self.helperSessionActive = true
                        self.cacheFirstActive = restored.cacheFirst == true
                        let mode = self.cacheFirstActive ? "refresh" : nil
                        if let retry = try? await self.runner.request(NativeMailCommand("snapshot", folder: folder, more: false, mode: mode)),
                           !Task.isCancelled, self.epoch.accepts(captured), self.phase == .open,
                           self.selectedFolder == folder, self.searchQuery == nil, self.draft == nil,
                           let nextFolders = retry.folders, let nextMessages = retry.messages, let nextFolder = retry.folder,
                           nextFolders.contains(where: { $0.id == nextFolder }) {
                            self.folders = nextFolders; self.messages = nextMessages; self.selectedFolder = nextFolder; self.loadedFolder = nextFolder
                            if let email = retry.email { self.email = email }
                            self.loading = retry.loading ?? false
                            self.showingSavedContent = self.cacheFirstActive && retry.fresh != true
                            self.cacheRefreshFailed = retry.refreshFailed == true
                            if !self.cacheRefreshFailed && (self.cacheFirstActive ? retry.fresh == true : !self.loading) {
                                self.lastSynced = Date(); self.mustRefreshBeforeActions = false; self.initialSyncPending = false; self.syncWarning = nil
                            }
                            self.reconcileSelection()
                            return
                        }
                    }
                    self.syncWarning = "Sync delayed"
                } else { self.syncWarning = "Sync delayed" }
            }
        }
    }
    private func pollBackgroundRefresh(captured: UInt64, expectedFolder: UInt64) {
        guard phase == .open, !demo, !previewOnly, !busy, !backgroundSyncing,
              selectedFolder == expectedFolder, searchQuery == nil, draft == nil else { return }
        backgroundSyncing = true
        backgroundRefreshTask = Task { [weak self] in
            defer {
                if let self, self.epoch.accepts(captured) { self.backgroundSyncing = false }
            }
            guard let self else { return }
            do {
                let mode = self.cacheFirstActive ? "poll" : nil
                let result = try await self.runner.request(NativeMailCommand("snapshot", folder: expectedFolder, more: false, mode: mode))
                try self.check(captured)
                guard self.phase == .open, self.selectedFolder == expectedFolder, self.searchQuery == nil, self.draft == nil else { return }
                guard let nextFolders = result.folders, let nextMessages = result.messages, let nextFolder = result.folder,
                      nextFolders.contains(where: { $0.id == nextFolder }) else { throw ProtonXError.invalidResponse }
                self.folders = nextFolders; self.messages = nextMessages; self.selectedFolder = nextFolder; self.loadedFolder = nextFolder
                self.loading = result.loading ?? false
                self.showingSavedContent = self.cacheFirstActive && result.fresh != true
                self.cacheRefreshFailed = result.refreshFailed == true
                if self.cacheRefreshFailed { self.initialSyncPending = false; self.syncWarning = "Offline · showing saved mail" }
                else if self.cacheFirstActive ? result.fresh == true : !self.loading {
                    self.lastSynced = Date(); self.mustRefreshBeforeActions = false; self.initialSyncPending = false; self.syncWarning = nil
                }
                self.reconcileSelection()
            } catch {
                guard !Task.isCancelled, self.epoch.accepts(captured), self.phase == .open else { return }
                if (error as? NativeMailFailure) == .sessionExpired { self.expireSession() }
                else { self.syncWarning = "Sync delayed" }
            }
        }
    }
    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel(); periodicRefreshTask = nil
        guard !previewOnly, !demo, phase == .open, !localAuthentication.systemSuspended else { return }
        let captured = epoch.value
        let interval = backgroundSyncInterval
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.epoch.accepts(captured), self.phase == .open else { return }
                if !self.localAuthentication.systemSuspended { self.backgroundRefresh() }
            }
        }
    }
    func startLockedBackgroundSync() {
        lockedSyncEpoch.invalidate(); lockedSyncTask?.cancel(); lockedSyncTask = nil
        guard lockedSyncEnabled, !previewOnly, !demo, hasSession, phase == .locked else {
            backgroundSyncActive = false; return
        }
        guard !localAuthentication.systemSuspended else { return }
        let ticket = lockedSyncEpoch.value
        backgroundSyncActive = true
        lockedSyncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.lockedSyncEpoch.accepts(ticket), self.phase == .locked, self.lockedSyncEnabled, !self.localAuthentication.systemSuspended else { return }
                do {
                    if !self.helperSessionActive {
                        let restored = try await self.runner.request(NativeMailCommand("restore"))
                        guard !Task.isCancelled, self.lockedSyncEpoch.accepts(ticket), self.phase == .locked, self.lockedSyncEnabled else { return }
                        guard restored.phase == .connected else { return }
                        self.helperSessionActive = true
                        self.cacheFirstActive = restored.cacheFirst == true
                    }
                    if let notifications = self.notifications {
                        await notifications.refreshPermission()
                        guard !Task.isCancelled, self.lockedSyncEpoch.accepts(ticket), self.phase == .locked, self.lockedSyncEnabled else { return }
                        if notifications.active {
                            let start = try await self.runner.request(NativeMailCommand("notifications_start"))
                            guard !Task.isCancelled, self.lockedSyncEpoch.accepts(ticket), self.phase == .locked, self.lockedSyncEnabled else { return }
                            notifications.beginLockedMail(preserveDelivered: true)
                            await notifications.receive(start.notifications ?? [], unread: start.unreadCount ?? 0)
                            while !Task.isCancelled {
                                try await Task.sleep(for: self.notificationInterval)
                                await notifications.refreshPermission()
                                guard !Task.isCancelled, self.lockedSyncEpoch.accepts(ticket), self.phase == .locked, self.lockedSyncEnabled, !self.localAuthentication.systemSuspended else { return }
                                if !notifications.active {
                                    _ = try? await self.runner.request(NativeMailCommand("notifications_stop"))
                                    notifications.clearMail()
                                    break
                                }
                                let poll = try await self.runner.request(NativeMailCommand("notifications_poll"))
                                guard !Task.isCancelled, self.lockedSyncEpoch.accepts(ticket), self.phase == .locked, self.lockedSyncEnabled else { return }
                                guard let batch = poll.notifications, let unread = poll.unreadCount else { throw ProtonXError.invalidResponse }
                                await notifications.receive(batch, unread: unread)
                            }
                        } else {
                            // Keep the helper alive for Proton's SDK event loop even when OS alerts are off.
                            try await Task.sleep(for: self.backgroundSyncInterval)
                        }
                    } else {
                        try await Task.sleep(for: self.backgroundSyncInterval)
                    }
                } catch {
                    if Task.isCancelled || !self.lockedSyncEpoch.accepts(ticket) || self.phase != .locked || !self.lockedSyncEnabled { return }
                    if (error as? NativeMailFailure) == .sessionExpired { self.expireSession(); return }
                    if !(error is NativeMailFailure) || (error as? NativeMailFailure) == .invalidState {
                        self.helperSessionActive = false
                    }
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }
    private func stopLockedBackgroundSync(keepHelper: Bool) {
        lockedSyncEpoch.invalidate(); lockedSyncTask?.cancel(); lockedSyncTask = nil
        backgroundSyncActive = false
        if !keepHelper {
            helperSessionActive = false
            runner.cancelAll()
        }
    }
    private func restartNotifications(preserveDelivered: Bool = false) {
        notificationEpoch.invalidate(); notificationTask?.cancel(); notificationTask = nil
        if preserveDelivered { notifications?.beginMail(preserveDelivered: true) }
        else { notifications?.clearMail() }
        guard !previewOnly, !demo, phase == .open, let notifications else { return }
        let session = epoch.value, generation = notificationEpoch.value
        notificationTask = Task { [weak self] in
            await notifications.refreshPermission()
            guard let self, !Task.isCancelled, self.epoch.accepts(session), self.notificationEpoch.accepts(generation) else { return }
            do {
                let result = try await self.runner.request(NativeMailCommand(notifications.active ? "notifications_start" : "notifications_stop"))
                guard !Task.isCancelled, self.epoch.accepts(session), self.notificationEpoch.accepts(generation), notifications.active else { return }
                notifications.beginMail(preserveDelivered: preserveDelivered)
                self.lastKnownUnread = result.unreadCount
                await notifications.receive(result.notifications ?? [], unread: result.unreadCount ?? 0)
                while !Task.isCancelled {
                    try await Task.sleep(for: self.notificationInterval)
                    await notifications.refreshPermission()
                    guard !Task.isCancelled, self.epoch.accepts(session), self.notificationEpoch.accepts(generation), notifications.active else { return }
                    do {
                        let result = try await self.runner.request(NativeMailCommand("notifications_poll"))
                        guard !Task.isCancelled, self.epoch.accepts(session), self.notificationEpoch.accepts(generation) else { return }
                        guard let batch = result.notifications, let unread = result.unreadCount else { throw ProtonXError.invalidResponse }
                        let unreadChanged = self.lastKnownUnread != nil && self.lastKnownUnread != unread
                        self.lastKnownUnread = unread
                        await notifications.receive(batch, unread: unread)
                        if !batch.isEmpty || unreadChanged {
                            self.backgroundRefresh()
                        }
                    } catch {
                        if Task.isCancelled || !self.epoch.accepts(session) || !self.notificationEpoch.accepts(generation) { return }
                        if (error as? NativeMailFailure) == .sessionExpired { self.expireSession(); return }
                        if (error as? NativeMailFailure) == .invalidState || !(error is NativeMailFailure) {
                            notifications.monitorUnavailable(); return
                        }
                        // Transient failures retain the loop; no replay of delivered alerts.
                    }
                }
            } catch {
                guard !Task.isCancelled, self.epoch.accepts(session), self.notificationEpoch.accepts(generation) else { return }
                if (error as? NativeMailFailure) == .sessionExpired { self.expireSession() }
                else { notifications.monitorUnavailable() }
            }
        }
    }
    func openNotification(folder: UInt64, item: UInt64) {
        guard phase == .open, !demo, !previewOnly else { return }
        // Navigation never replaces or discards an open composer.
        guard draft == nil else { notice = "New mail received. Save or close your draft to view it."; return }
        guard !busy else { notice = "New mail received. Refresh Mail when the current operation finishes."; return }
        searchQuery = nil; searchHasMore = false; searchReturnFolder = nil
        query = ""; selectedFolder = folder
        perform { [self] captured in
            try await load(captured: captured)
            guard messages.contains(where: { $0.id == item }) else { notice = "The message is outside the current page. Your mailbox is open; refresh or load more to find it."; return }
            selectedItem = item; select(preferred: item)
        }
    }
    private func autoSavePayload() -> (token: UInt64, content: NativeMailComposeContent)? {
        guard phase == .open, !demo, !previewOnly, !attachmentBusy, !attachmentNeedsRefresh,
              let draft, draft.state == .editing, let editorState else { return nil }
        var content = editorState.content
        let hasContent = !content.to.isEmpty || !content.cc.isEmpty || !content.bcc.isEmpty ||
            !content.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else { return nil }
        if (try? content.validate(senders: draft.senders, sending: false)) == nil {
            // Strip any half-typed invalid recipient token so the subject and message body still save as a draft.
            let cleanSubject = String(content.subject.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(998)
            content = NativeMailComposeContent(
                sender: draft.senders.contains(content.sender) ? content.sender : draft.sender,
                to: content.to.filter(ContactRecipients.valid),
                cc: content.cc.filter(ContactRecipients.valid),
                bcc: content.bcc.filter(ContactRecipients.valid),
                subject: String(cleanSubject),
                text: content.text
            )
            guard (try? content.validate(senders: draft.senders, sending: false)) != nil else { return nil }
        }
        return (draft.token, content)
    }
    var hasUnsavedEditingDraft: Bool { autoSavePayload() != nil }
    /// Best-effort bounded save of an open editing draft before quitting or closing the helper.
    func flushDraftBeforeShutdown() async {
        guard let pending = autoSavePayload() else { return }
        draft = nil; composeStatus = nil
        let runner = self.runner
        let saveTask = Task {
            _ = try? await runner.request(NativeMailCommand("save_draft", token: pending.token, content: pending.content))
            _ = try? await runner.request(NativeMailCommand("close_draft", token: pending.token))
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(3))
            saveTask.cancel()
        }
        await saveTask.value
        timeoutTask.cancel()
    }
    func cancelLocalUnlock() { if localAuthentication.state == .authenticating { lock(preserveBackgroundSync: lockedSyncEnabled) } }
    func terminate() { retainedState = nil; lock(preserveBackgroundSync: false) }
    func lock(preserveBackgroundSync: Bool = false) {
        let keepSync = preserveBackgroundSync && lockedSyncEnabled && hasSession && !previewOnly && !demo
        let pendingDraftSave = keepSync ? autoSavePayload() : nil
        let openDraftToken = keepSync ? draft?.token : nil
        if keepSync && phase == .open && !folders.isEmpty && searchQuery == nil {
            // Keep folder/message list metadata privately behind the lock gate for instant 0ms unlock.
            // Decrypted bodies, WKWebView, attachment previews, contact details and drafts are cleared.
            retainedState = RetainedMailState(
                folders: folders, messages: messages,
                selectedFolder: selectedFolder, loadedFolder: loadedFolder,
                selectedItem: selectedItem, email: email, lastSynced: lastSynced,
                contacts: contacts, contactsLoaded: contactsLoaded
            )
        } else if !keepSync {
            retainedState = nil
        }
        clearContacts()
        draftAttachmentPolling?.cancel(); clearAttachments()
        notificationEpoch.invalidate(); notificationTask?.cancel(); notificationTask = nil
        periodicRefreshTask?.cancel(); periodicRefreshTask = nil
        backgroundRefreshTask?.cancel(); backgroundRefreshTask = nil
        backgroundSyncing = false; initialSyncPending = false; syncWarning = nil; lastKnownUnread = nil
        epoch.invalidate(); selectionEpoch.invalidate(); operation?.cancel(); selection?.cancel(); polling?.cancel(); sendPolling?.cancel(); localAuthentication.cancel()
        searchQuery = nil; searchHasMore = false; searchReturnFolder = nil
        folders = []; messages = []; body = nil; sanitizedHTML = nil; selectedItem = nil; selectedFolder = nil; query = ""; email = ""; error = nil
        clearThread()
        draft = nil; composeStatus = nil; notice = nil; messageActions = []; mustRefreshBeforeActions = false; clearActionUndo()
        loading = false; lastSynced = nil; busy = false; demoBodies = [:]; demoHTML = [:]; demoMessages = []; loadedFolder = nil
        showingSavedContent = false; cacheRefreshFailed = false
        if keepSync {
            phase = .locked
            if let pendingDraftSave {
                let runner = self.runner
                Task {
                    _ = try? await runner.request(NativeMailCommand("save_draft", token: pendingDraftSave.token, content: pendingDraftSave.content))
                    _ = try? await runner.request(NativeMailCommand("close_draft", token: pendingDraftSave.token))
                }
            } else if let openDraftToken {
                let runner = self.runner
                Task { _ = try? await runner.request(NativeMailCommand("close_draft", token: openDraftToken)) }
            }
            notifications?.beginLockedMail(preserveDelivered: true)
            startLockedBackgroundSync()
        } else {
            stopLockedBackgroundSync(keepHelper: false)
            notifications?.clearMail()
            cacheFirstActive = false
            phase = hasSession ? .locked : .welcome
        }
    }
    func cancelSignIn() { lock() }
    func enterDemo() {
        lock(); demo = true; phase = .open; email = "alex@example.com"
        folders = [NativeMailFolder(id: 1, name: "Inbox", count: 2, kind: .inbox), NativeMailFolder(id: 2, name: "Sent", kind: .sent), NativeMailFolder(id: 3, name: "Archive", kind: .archive), NativeMailFolder(id: 4, name: "Trash", kind: .trash), NativeMailFolder(id: 5, name: "Spam", kind: .spam)]; selectedFolder = 1; loadedFolder = 1
        messages = [NativeMailMessage(id: 11, subject: "Welcome to your native inbox", sender: "hello@example.com", senderName: "ProtonX", recipient: "alex@example.com", date: 1791288000, unread: true, attachments: 1, conversationID: 1100), NativeMailMessage(id: 12, subject: "Coffee this weekend?", sender: "sam@example.com", senderName: "Sam", recipient: "alex.demo@gmail.com", date: 1791201600, conversationID: 1200)]
        demoMessages = messages; demoLocations = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, 1) })
        demoMessages += [
            NativeMailMessage(id: 13, subject: "Re: Coffee this weekend?", sender: "alex.demo@gmail.com", senderName: "Alex", recipient: "sam@example.com", date: 1791205200, conversationID: 1200),
            NativeMailMessage(id: 14, subject: "Re: Coffee this weekend?", sender: "alex.demo@gmail.com", senderName: "Alex", recipient: "sam@example.com", date: 1791208800, conversationID: 1200)
        ]
        demoLocations[13] = 2; demoLocations[14] = 2
        demoBodies = [11: "A native Mail window, with one shared menu-bar icon and Mac keyboard shortcuts.\n\nThis inbox is synthetic. No account has been accessed.\n\nThe direct Mail client uses Proton’s existing authentication and encryption core.", 12: "Hi Alex,\n\nCoffee on Saturday?\n\nSam"]
        demoHTML = [11: """
        <style>.demo-card { max-width:600px; margin:0 auto; padding:24px; background:#f6f5f9; border-radius:16px } .demo-card h1 {font-size:26px; line-height:1.25} .demo-card td,.demo-card th {padding:10px; text-align:left; border-bottom:1px solid #ddd} </style>
        <div class="demo-card"><h1>Welcome to your native inbox</h1><p>Hello <strong>Alex</strong>,</p><p>This newsletter is synthetic. No account has been accessed.</p><table style="width:100%"><tr><th>Product</th><th>Window</th></tr><tr><td>Mail</td><td>⌘2</td></tr><tr><td>Pass</td><td>⌘1</td></tr></table><h2>A comfortable place to read</h2><ul><li>Headings, lists and tables keep their structure.</li><li>The message stays light in dark appearance.</li></ul><p><a href="https://example.com/help">A synthetic help link</a></p><blockquote>Earlier reply: thanks for the update.</blockquote></div>
        """]
        demoBodies[11] = "Welcome to your native inbox\n\nHello Alex,\n\nThis newsletter is synthetic. No account has been accessed.\n\nProduct / Window\nMail / ⌘2\nPass / ⌘1\n\nA comfortable place to read\n• Headings, lists and tables keep their structure.\n• The message stays light in dark appearance.\n\nA synthetic help link: https://example.com/help\n\nEarlier reply: thanks for the update."
        demoBodies[13] = "Hi Sam,\n\nSaturday sounds good. Shall we meet at ten?\n\nAlex"
        demoBodies[14] = "One more thing — I’ll bring the book we talked about.\n\nSee you Saturday!\n\nAlex"
        if previewOnly {
            folders += [NativeMailFolder(id: 6, name: "Starred", kind: .starred), NativeMailFolder(id: 7, name: "Travel", kind: .other, isCustom: true)]
            let example = NativeMailMessage(id: 15, subject: "Fatura bilgilendirme", sender: "fatura@example.invalid", senderName: "Örnek Enerji", recipient: "alex@example.com", date: 1791289000, unread: true, conversationID: 1500)
            messages.append(example); demoMessages.append(example); demoLocations[15] = 1
            folders[0] = NativeMailFolder(id: 1, name: "Inbox", count: 3, kind: .inbox)
            demoBodies[15] = "Merhaba Deniz,\n\nElektrik faturanız hazırlanmıştır. Son ödeme tarihi 20 Ekim. Faturanızı incelemek için https://example.invalid/fatura bağlantısını kullanabilirsiniz.\n\nSorularınız için destek@example.invalid adresine yazabilirsiniz.\n\nİyi günler dileriz."
            demoHTML[15] = "<h2>Faturanız hazır</h2><p>Merhaba Deniz,</p><p>Elektrik faturanız hazırlanmıştır. Son ödeme tarihi <strong>20 Ekim</strong>.</p><p>Faturanızı incelemek için <a href='https://example.invalid/fatura'>bağlantıyı açın</a>.</p><p>Sorularınız için destek@example.invalid adresine yazabilirsiniz.</p><p>İyi günler dileriz.</p>"
        }
        selectedItem = 11; body = demoBodies[11]; sanitizedHTML = demoHTML[11]; setDemoAttachments(11); setDemoActions()
    }
    private func setDemoActions() {
        guard searchQuery == nil else { messageActions = []; return }
        guard let message = selectedMessage else { messageActions = []; return }
        messageActions = [message.unread ? .read : .unread]
        let location = demoLocations[message.id] ?? selectedFolder
        if location != 3 { messageActions.append(.archive) }
        if location != 4 { messageActions.append(.trash) }
        if location != 1 && location != 2 { messageActions.append(.inbox) }
        if location != 5 && location != 2 && location != 4 { messageActions.append(.spam) }
    }
    private func expireSession() {
        hasSession = false; defaults.set(false, forKey: "nativeMailConnected")
        lock(); demo = false; phase = .welcome
    }
    var filePanelContext: UInt64? { phase == .open ? epoch.value : nil }
    enum AttachmentAction { case preview, save(URL) }
    func clearAttachmentPreview() { attachmentPreview?.remove(); attachmentPreview = nil }
    private func clearAttachments() {
        if draft == nil { cancelAttachmentTransfer(); attachmentError = nil }
        clearAttachmentPreview(); attachmentList = []
    }
    func cancelAttachmentTransfer() {
        attachmentEpoch.invalidate(); attachmentTask?.cancel(); attachmentTask = nil
        attachmentBusy = false; attachmentStatus = nil
        if attachmentNeedsRefresh { attachmentError = "The attachment change may still complete. Refresh the list before adding, removing or sending." }
    }
    func refreshAttachments() {
        guard phase == .open, draft == nil, !busy, !attachmentBusy, let item = selectedMessage?.id, let folder = selectedFolder else { return }
        if demo { return }
        let captured = epoch.value, generation = selectionEpoch.value
        attachmentTask = Task { [self] in
            do {
                let result = try await runner.request(NativeMailCommand("attachment_list", folder: folder, item: item))
                try check(captured)
                guard selectionEpoch.accepts(generation), selectedMessage?.id == item, result.id == item, let list = result.attachmentList else { throw CancellationError() }
                try MailAttachmentPolicy.validateList(list); attachmentList = list; attachmentError = nil
            } catch { if epoch.accepts(captured), selectionEpoch.accepts(generation), !Task.isCancelled {
                if (error as? NativeMailFailure) == .sessionExpired { expireSession() } else { attachmentError = safeError(error) }
            } }
        }
    }
    func downloadAttachment(_ file: NativeMailAttachment, action: AttachmentAction) {
        guard phase == .open, draft == nil, !busy, !attachmentBusy, attachmentList.contains(file), let item = selectedMessage?.id, let folder = selectedFolder else { return }
        guard file.size <= MailAttachmentPolicy.maxBytes else { attachmentError = NativeMailFailure.attachmentTooLarge.localizedDescription; return }
        cancelAttachmentTransfer(); attachmentBusy = true; attachmentError = nil; attachmentStatus = "Downloading \(file.name)…"
        let captured = epoch.value, generation = attachmentEpoch.value, selected = selectionEpoch.value
        attachmentTask = Task { [self] in
            var ticket: UInt64?
            defer {
                if let ticket { Task { [weak self] in
                    guard let self, self.phase == .open, self.epoch.accepts(captured) else { return }
                    _ = try? await self.runner.request(NativeMailCommand("transfer_cancel", token: ticket))
                } }
                if attachmentEpoch.accepts(generation) { attachmentBusy = false; attachmentStatus = nil }
            }
            do {
                var bytes = Data()
                if demo { bytes = Data("ProtonX synthetic attachment\nNo account data.\n".utf8) }
                else {
                    let start = try await runner.request(NativeMailCommand("attachment_download", folder: folder, item: item, attachment: file.id))
                    ticket = start.transfer?.token
                    try checkAttachment(captured, generation)
                    guard let transfer = start.transfer, transfer.offset == 0 else { throw ProtonXError.invalidResponse }
                    try transfer.validate(); ticket = transfer.token
                    while true {
                        let result = try await runner.request(NativeMailCommand("attachment_chunk", folder: folder, item: item, token: transfer.token, attachment: file.id, offset: bytes.count))
                        try checkAttachment(captured, generation)
                        guard let chunk = result.transfer, chunk.token == transfer.token, chunk.size == transfer.size,
                              let encoded = chunk.data, let data = MailAttachmentPolicy.decode(encoded),
                              chunk.offset == bytes.count + data.count, chunk.offset <= transfer.size,
                              chunk.done == (chunk.offset == transfer.size), !data.isEmpty || chunk.done == true else { throw ProtonXError.invalidResponse }
                        bytes.append(data)
                        attachmentStatus = "Downloading \(file.name) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file))"
                        if chunk.done == true { break }
                    }
                }
                try checkAttachment(captured, generation)
                guard selectionEpoch.accepts(selected), selectedMessage?.id == item else { throw CancellationError() }
                switch action {
                case .preview:
                    guard MailAttachmentFiles.canPreview(file.name) else { throw NativeMailFailure.attachmentFailed }
                    clearAttachmentPreview(); attachmentPreview = try MailAttachmentPreview(name: file.name, bytes: bytes)
                case .save(let url):
                    try MailAttachmentFiles.save(bytes, to: url); notice = "Attachment saved"
                }
            } catch {
                if !Task.isCancelled, epoch.accepts(captured), attachmentEpoch.accepts(generation) {
                    if (error as? NativeMailFailure) == .sessionExpired { expireSession() }
                    else { attachmentError = safeError(error) }
                }
            }
        }
    }
    private func checkAttachment(_ captured: UInt64, _ generation: UInt64) throws {
        try check(captured); guard attachmentEpoch.accepts(generation), phase == .open else { throw CancellationError() }
    }
    func acceptDroppedFiles(_ providers: [NSItemProvider]) {
        guard let token = draft?.token, providers.count <= 100 else { return }
        let captured = epoch.value
        Task { [weak self] in
            var urls: [URL] = []
            for provider in providers {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in continuation.resume(returning: data) }
                }
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { urls.append(url) }
            }
            guard let self, self.epoch.accepts(captured), self.draft?.token == token else { return }
            self.addDraftAttachments(urls)
        }
    }
    func addDraftAttachments(_ urls: [URL]) {
        guard phase == .open, !busy, !attachmentBusy, !attachmentNeedsRefresh, let draft, draft.state == .editing, !urls.isEmpty, urls.count <= 100 else { return }
        cancelAttachmentTransfer(); attachmentBusy = true; attachmentError = nil
        let captured = epoch.value, generation = attachmentEpoch.value, owner = draft.token
        attachmentTask = Task { [self] in
            var ticket: UInt64?
            defer {
                if let ticket { Task { [weak self] in
                    guard let self, self.phase == .open, self.epoch.accepts(captured) else { return }
                    _ = try? await self.runner.request(NativeMailCommand("transfer_cancel", token: ticket))
                } }
                if attachmentEpoch.accepts(generation) { attachmentBusy = false; attachmentStatus = nil; startDraftAttachmentPolling() }
            }
            do {
                for url in urls {
                    try checkAttachment(captured, generation)
                    guard self.draft?.token == owner, url.isFileURL else { throw CancellationError() }
                    let name = MailAttachmentPolicy.filename(url.lastPathComponent)
                    attachmentStatus = "Attaching \(name)…"
                    let bytes = try await Task.detached(priority: .userInitiated) { try MailAttachmentFiles.readUpload(url) }.value
                    try checkAttachment(captured, generation)
                    if demo {
                        var list = self.draft?.attachmentList ?? []
                        list.append(.init(id: UInt64((list.map(\.id).max() ?? 0) + 1), name: name, size: UInt64(bytes.count), state: .uploaded))
                        self.draft?.attachmentList = list; continue
                    }
                    let start = try await runner.request(NativeMailCommand("upload_start", token: owner, name: name, size: bytes.count))
                    ticket = start.transfer?.token
                    try checkAttachment(captured, generation)
                    guard let transfer = start.transfer, transfer.size == bytes.count, transfer.offset == 0 else { throw ProtonXError.invalidResponse }
                    try transfer.validate(); ticket = transfer.token
                    var offset = 0
                    while offset < bytes.count {
                        let end = min(offset + MailAttachmentPolicy.chunkBytes, bytes.count)
                        let reply = try await runner.request(NativeMailCommand("upload_chunk", token: owner, transfer: transfer.token, offset: offset, data: MailAttachmentPolicy.encode(bytes.subdata(in: offset..<end))))
                        try checkAttachment(captured, generation)
                        guard let ack = reply.transfer, ack.token == transfer.token, ack.offset == end, ack.size == bytes.count else { throw ProtonXError.invalidResponse }
                        offset = end
                    }
                    attachmentNeedsRefresh = true
                    let result = try await runner.request(NativeMailCommand("upload_finish", token: owner, transfer: transfer.token))
                    try checkAttachment(captured, generation); ticket = nil
                    guard result.draft?.token == owner else { throw ProtonXError.invalidResponse }
                    self.draft = result.draft; attachmentNeedsRefresh = false; composeStatus = "Attachment added · syncing with Proton"
                }
            } catch {
                if !Task.isCancelled, epoch.accepts(captured), attachmentEpoch.accepts(generation) {
                    if (error as? NativeMailFailure) == .sessionExpired { expireSession() }
                    else { attachmentError = safeError(error) }
                }
            }
        }
    }
    func removeDraftAttachment(_ id: UInt64) {
        guard phase == .open, !busy, !attachmentBusy, !attachmentNeedsRefresh, let draft, draft.state == .editing, draft.attachmentList?.contains(where: { $0.id == id }) == true else { return }
        if demo { self.draft?.attachmentList?.removeAll { $0.id == id }; return }
        perform { [self] captured in
            attachmentNeedsRefresh = true
            let result = try await runner.request(NativeMailCommand("remove_attachment", token: draft.token, attachment: id))
            try check(captured); guard result.draft?.token == draft.token else { throw ProtonXError.invalidResponse }
            self.draft = result.draft; attachmentNeedsRefresh = false; attachmentError = nil; composeStatus = "Attachment removed · syncing with Proton"
        }
    }
    func refreshDraftAttachments() {
        guard phase == .open, !busy, !attachmentBusy, !demo, let draft else { return }
        perform { [self] captured in
            let result = try await runner.request(NativeMailCommand("draft_attachments", token: draft.token))
            try check(captured); guard result.draft?.token == draft.token else { throw ProtonXError.invalidResponse }
            self.draft = result.draft; attachmentNeedsRefresh = false; attachmentError = nil; startDraftAttachmentPolling()
        }
    }
    private func startDraftAttachmentPolling() {
        draftAttachmentPolling?.cancel()
        guard !demo, !attachmentNeedsRefresh, let draft, draft.state == .editing, draft.attachmentList?.contains(where: { $0.state == .pending || $0.state == .uploading || $0.state == .offline }) == true else { return }
        let captured = epoch.value, token = draft.token
        draftAttachmentPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.epoch.accepts(captured), !Task.isCancelled, self.draft?.token == token else { return }
                if self.busy || self.attachmentBusy { continue }
                do {
                    let result = try await self.runner.request(NativeMailCommand("draft_attachments", token: token))
                    try self.check(captured)
                    guard !self.busy, self.draft?.state == .editing, self.draft?.token == token, result.draft?.token == token else { return }
                    self.draft = result.draft
                    if result.draft?.attachmentList?.allSatisfy({ $0.state == .uploaded || $0.state == .failed }) == true { return }
                } catch {
                    if !Task.isCancelled, self.epoch.accepts(captured) {
                        if (error as? NativeMailFailure) == .sessionExpired { self.expireSession() }
                        else { self.attachmentError = self.safeError(error) }
                    }
                    return
                }
            }
        }
    }
    private func setDemoAttachments(_ item: UInt64) {
        attachmentList = (demoMessages.first { $0.id == item }?.attachments ?? 0) > 0
            ? [.init(id: 1, name: "ProtonX sample.txt", size: 44, mime: "text/plain")] : []
    }
    private func check(_ captured: UInt64) throws { try Task.checkCancellation(); guard epoch.accepts(captured) else { throw CancellationError() } }
    private func safeError(_ error: Error) -> String {
        if let failure = error as? NativeMailFailure { return failure.localizedDescription }
        if case ProtonXError.helperMissing = error { return "This build is missing the native Mail helper. Rebuild ProtonX with Mail support." }
        return "Mail could not complete this operation. Retry or unlock your session again."
    }
    private func perform(_ action: @escaping @MainActor (UInt64) async throws -> Void) {
        guard !busy else { return }
        backgroundRefreshTask?.cancel(); backgroundRefreshTask = nil; backgroundSyncing = false
        busy = true; error = nil
        let captured = epoch.value
        operation = Task { [self] in
            do { try await action(captured) }
            catch {
                if !Task.isCancelled && epoch.accepts(captured) {
                    initialSyncPending = false
                    let message = safeError(error)
                    let cancelled = (error as? ProtonXError) == .cancelled || [.userCancel, .appCancel, .systemCancel].contains((error as? LAError)?.code)
                    self.error = cancelled || error is LAError ? nil : message
                    if phase == .signingIn { phase = .welcome }
                    if (error as? NativeMailFailure) == .sessionExpired { expireSession(); self.error = message }
                }
            }
            if epoch.accepts(captured) { busy = false }
        }
    }
    private func clearContacts() {
        contactListEpoch.invalidate(); contactDetailEpoch.invalidate()
        contactsTask?.cancel(); contactDetailTask?.cancel()
        contacts = []; contactsLoaded = false; contactsBusy = false; contactsError = nil
        contactDetail = nil; contactDetailBusy = false; contactDetailError = nil; contactsQuery = ""; selectedContact = nil
    }
    func loadContacts(refreshDetails: Bool = true) {
        guard phase == .open, !contactsBusy else { return }
        if demo {
            contacts = [
                .init(localID: 10, name: "Sam Rivera", emails: [.init(contactID: 10, name: "Sam Rivera", email: "sam@example.com")]),
                .init(localID: 20, name: "Jamie Chen", emails: [.init(contactID: 20, name: "Jamie Chen", email: "jamie@example.com"), .init(contactID: 20, name: "Jamie Chen", email: "jamie.work@example.com")]),
                .init(localID: 30, kind: .group, name: "Weekend friends", emails: [.init(contactID: 10, name: "Sam Rivera", email: "sam@example.com"), .init(contactID: 20, name: "Jamie Chen", email: "jamie@example.com")])
            ]; contactsLoaded = true; contactsError = nil; return
        }
        contactsBusy = true; contactsError = nil
        contactListEpoch.invalidate(); let ticket = contactListEpoch.value, session = epoch.value
        contactDetailEpoch.invalidate(); contactDetailTask?.cancel(); contactDetailBusy = false
        contactsTask = Task { [self] in
            do {
                let result = try await runner.request(NativeMailCommand("contacts"))
                try check(session); guard contactListEpoch.accepts(ticket), let entries = result.contacts else { throw ProtonXError.invalidResponse }
                try ContactEntry.validate(entries)
                contacts = entries; contactsLoaded = true
                if !entries.contains(where: { $0.id == selectedContact }) { selectedContact = nil }
                if selectedContact == nil { contactDetail = nil }
                else if refreshDetails || contactDetail == nil { selectContact(selectedContact) }
            } catch {
                if !Task.isCancelled, epoch.accepts(session), contactListEpoch.accepts(ticket) {
                    contactsError = safeError(error)
                    if (error as? NativeMailFailure) == .sessionExpired { expireSession() }
                }
            }
            if epoch.accepts(session), contactListEpoch.accepts(ticket) { contactsBusy = false }
        }
    }
    func selectContact(_ id: String?) {
        contactDetailEpoch.invalidate(); contactDetailTask?.cancel()
        selectedContact = id; contactDetail = nil; contactDetailBusy = false; contactDetailError = nil
        guard phase == .open, let entry = currentContact, entry.kind == .contact else { return }
        if demo {
            contactDetail = .init(localID: entry.localID, fields: entry.emails.map { .init("Email", $0.email) } + [.init("Phone", "+1 202 555 0142"), .init("Organisation", "Example Studio"), .init("Note", "Synthetic contact for the ProtonX preview.")]); return
        }
        let ticket = contactDetailEpoch.value, session = epoch.value
        contactDetailBusy = true
        contactDetailTask = Task { [self] in
            do {
                let result = try await runner.request(NativeMailCommand("contact_detail", item: entry.localID))
                try check(session)
                guard contactDetailEpoch.accepts(ticket), currentContact?.id == id, let details = result.contactDetail else { throw CancellationError() }
                try details.validate(for: entry.localID); contactDetail = details
            } catch {
                if !Task.isCancelled, epoch.accepts(session), contactDetailEpoch.accepts(ticket), currentContact?.id == id {
                    contactDetailError = safeError(error)
                    if (error as? NativeMailFailure) == .sessionExpired { expireSession() }
                }
            }
            if epoch.accepts(session), contactDetailEpoch.accepts(ticket) { contactDetailBusy = false }
        }
    }
    @discardableResult func addContactRecipients(_ addresses: [String], field: String, token: UInt64) -> Bool {
        guard phase == .open, !busy, draft?.token == token, draft?.state == .editing, let editor = editorState else { return false }
        // An email may be chosen only from this session's disclosed contact list.
        let allowed = Set(contacts.flatMap(\.emails).map { $0.email })
        guard !addresses.isEmpty, addresses.allSatisfy({ allowed.contains($0) }) else { return false }
        do {
            switch field {
            case "to": editor.to = try ContactRecipients.appending(addresses, to: editor.to, otherFields: [editor.cc, editor.bcc])
            case "cc": editor.cc = try ContactRecipients.appending(addresses, to: editor.cc, otherFields: [editor.to, editor.bcc])
            case "bcc": editor.bcc = try ContactRecipients.appending(addresses, to: editor.bcc, otherFields: [editor.to, editor.cc])
            default: return false
            }
            markDraftEdited(); return true
        } catch { return false }
    }

}
