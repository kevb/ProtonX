// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@MainActor private final class LockSyncNotificationSink: DesktopNotifying {
    var allowed: NotificationPermission = .authorized
    var notices: [DesktopNotice] = []
    var clearedCount = 0
    var dock: UInt64?
    func permission() async -> NotificationPermission { allowed }
    func authorize() async throws -> Bool { allowed == .authorized }
    func add(_ notice: DesktopNotice) async throws { notices.append(notice) }
    func remove(_ ids: [String]) { notices.removeAll { ids.contains($0.id) } }
    func clear() { clearedCount += 1; notices = [] }
    func badge(_ count: UInt64?) { dock = count }
}

private final class LockedSyncMailRunner: NativeMailRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var savedDrafts: [NativeMailComposeContent] = []
    private var pollReplies: [NativeMailResult]
    private var snapshotReplies: [NativeMailResult]
    private var cancelledCount = 0
    init(polls: [NativeMailResult] = [], snapshots: [NativeMailResult] = []) {
        self.pollReplies = polls
        self.snapshotReplies = snapshots
    }
    var calls: [String] { lock.withLock { recorded } }
    var draftsSaved: [NativeMailComposeContent] { lock.withLock { savedDrafts } }
    var cancellations: Int { lock.withLock { cancelledCount } }
    func cancelAll() { lock.withLock { cancelledCount += 1 } }
    func request(_ command: NativeMailCommand) async throws -> NativeMailResult {
        lock.withLock {
            recorded.append(command.method)
            if command.method == "save_draft", let content = command.content { savedDrafts.append(content) }
        }
        switch command.method {
        case "login", "restore":
            return .init(phase: .connected, cacheFirst: false)
        case "compose":
            return .init(draft: .init(token: 42, sender: "alex@example.com", senders: ["alex@example.com"], to: [], subject: "", quote: "", state: .editing))
        case "save_draft":
            return .init(draft: .init(token: command.token ?? 42, sender: command.content?.sender ?? "alex@example.com", senders: ["alex@example.com"], to: command.content?.to ?? [], subject: command.content?.subject ?? "", text: command.content?.text ?? "", quote: "", state: .editing))
        case "close_draft":
            return .init(closed: true)
        case "snapshot":
            return lock.withLock {
                if !snapshotReplies.isEmpty { return snapshotReplies.removeFirst() }
                return NativeMailResult(
                    folders: [.init(id: 1, name: "Inbox", count: 1, kind: .inbox)],
                    folder: 1,
                    messages: [.init(id: 11, subject: "Synthetic inbox", sender: "sam@example.com", unread: true)],
                    loading: false,
                    email: "alex@example.com",
                    fresh: true
                )
            }
        case "message":
            return .init(id: command.item ?? 11, body: "Synthetic message body")
        case "notifications_start":
            return .init(notifications: [], unreadCount: 1)
        case "notifications_stop":
            return .init(notifications: [], unreadCount: 0)
        case "notifications_poll":
            return lock.withLock {
                if !pollReplies.isEmpty { return pollReplies.removeFirst() }
                return .init(notifications: [], unreadCount: 1)
            }
        default:
            throw ProtonXError.invalidResponse
        }
    }
}

private final class PassBgRunner: HelperRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var responses: [Result<String, Error>]
    init(_ responses: [Result<String, Error>]) { self.responses = responses }
    var calls: [String] { lock.withLock { recorded } }
    func cancelAll() {}
    func run(_ command: HelperCommand, challenge: ChallengeHandler?) async throws -> Data {
        let next: Result<String, Error> = lock.withLock {
            recorded.append(command.arguments.first ?? "")
            return responses.isEmpty ? .failure(ProtonXError.invalidResponse) : responses.removeFirst()
        }
        return Data(try next.get().utf8)
    }
}

private actor CalendarBgRunner: NativeCalendarRunning {
    private(set) var calls: [String] = []
    var eventTitle = "Synthetic event 1"
    func setTitle(_ title: String) { eventTitle = title }
    nonisolated func cancelAll() {}
    func request(_ command: NativeCalendarCommand) async throws -> NativeCalendarResult {
        calls.append(command.method)
        if command.method == "snapshot" {
            let start = command.start!, end = command.end!
            let json = "{\"schema\":1,\"id\":1,\"result\":{\"phase\":\"connected\",\"start\":\(start),\"end\":\(end),\"calendars\":[{\"id\":\"cal-1\",\"name\":\"Personal\",\"color\":0}],\"events\":[{\"id\":\"ev-1\",\"calendarID\":\"cal-1\",\"title\":\"\(eventTitle)\",\"location\":\"\",\"notes\":\"\",\"start\":\(start+3600),\"end\":\(start+7200),\"zone\":\"UTC\",\"allDay\":false,\"recurring\":false}]}}"
            return try NativeCalendarProcess.decode(Data(json.utf8), expectedID: 1)
        }
        return .init(phase: "connected")
    }
}

@MainActor private func awaitCondition(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw ProtonXError.cancelled }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite @MainActor struct LockAndBackgroundSyncTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ProtonXLockSyncTests." + UUID().uuidString)!
    }

    @Test func lockSettingsDefaultsAndLegacyFallback() {
        let defaults = isolatedDefaults()
        let initial = LockSettings.load(from: defaults)
        #expect(initial.passAutoLockSeconds == 300)
        #expect(initial.mailAutoLockSeconds == 86_400)
        #expect(initial.lockMailOnScreenLock)
        #expect(initial.keepMailOpenOnWindowClose)
        #expect(initial.mailBackgroundSyncWhileLocked)
        #expect(!initial.passBackgroundCacheSync)

        // Legacy autoLockSeconds carries over to Pass only; Mail stays at 24h default.
        defaults.set(900, forKey: LockSettings.legacyAutoLockKey)
        let migrated = LockSettings.load(from: defaults)
        #expect(migrated.passAutoLockSeconds == 900)
        #expect(migrated.mailAutoLockSeconds == 86_400)

        // Explicit 0 ("Never") is honored without falling back to default.
        defaults.set(0, forKey: LockSettings.passAutoLockKey)
        defaults.set(0, forKey: LockSettings.mailAutoLockKey)
        let never = LockSettings.load(from: defaults)
        #expect(never.passAutoLockSeconds == 0)
        #expect(never.mailAutoLockSeconds == 0)
    }

    @Test func perProductInactivitySeparatesPassAppIdleFromMailMacIdle() {
        let integration = SystemIntegration()
        var lockedBatches: [Set<LockTarget>] = []
        integration.lockProductsAutomatically = { lockedBatches.append($0) }
        let settings = LockSettings(passAutoLockSeconds: 300, mailAutoLockSeconds: 3600)
        let start = ProcessInfo.processInfo.systemUptime

        // User is working in other apps (systemIdle = 5s), Pass has been untouched > 5m.
        integration.checkProductInactivity(at: start + 305, systemIdleSeconds: 5, settings: settings)
        #expect(lockedBatches == [[.pass]])

        // Another 2 minutes pass while Mac stays active: neither Pass nor Mail locks again.
        integration.checkProductInactivity(at: start + 425, systemIdleSeconds: 10, settings: settings)
        #expect(lockedBatches.count == 1)

        // Mac is left idle for > 1 hour: Mail & Calendar lock once, not repeatedly.
        integration.checkProductInactivity(at: start + 430, systemIdleSeconds: 3605, settings: settings)
        integration.checkProductInactivity(at: start + 435, systemIdleSeconds: 3610, settings: settings)
        #expect(lockedBatches == [[.pass], [.mail, .calendar]])

        // Activity resumes, then another 1 hour idle locks Mail & Calendar again.
        integration.checkProductInactivity(at: start + 440, systemIdleSeconds: 1, settings: settings)
        integration.checkProductInactivity(at: start + 445, systemIdleSeconds: 3601, settings: settings)
        #expect(lockedBatches == [[.pass], [.mail, .calendar], [.mail, .calendar]])
    }

    @Test func systemLockRespectsDisplaySleepAndMailScreenLockPreference() {
        let defaults = isolatedDefaults()
        let integration = SystemIntegration()
        integration.defaults = defaults
        var lockedBatches: [Set<LockTarget>] = []
        var wakes = 0
        integration.lockProductsAutomatically = { lockedBatches.append($0) }
        integration.systemDidWake = { wakes += 1 }

        // Display dimming locks Pass only, leaving Mail & Calendar unlocked.
        integration.updateSystemLock(.displaySleep, locked: true)
        #expect(lockedBatches == [[.pass]])
        integration.updateSystemLock(.displaySleep, locked: false)
        #expect(wakes == 1)

        // Screen lock locks all products by default.
        integration.updateSystemLock(.screenLocked, locked: true)
        #expect(lockedBatches == [[.pass], [.pass, .mail, .calendar]])
        integration.updateSystemLock(.screenLocked, locked: false)
        #expect(wakes == 2)

        // With lockMailOnScreenLock disabled, screen lock locks only Pass.
        defaults.set(false, forKey: LockSettings.lockMailOnScreenLockKey)
        integration.updateSystemLock(.screenLocked, locked: true)
        #expect(lockedBatches.last == [.pass])
        integration.updateSystemLock(.screenLocked, locked: false)
    }

    @Test func windowCloseLocksPassButKeepsMailAndCalendarWhenConfigured() {
        let defaults = isolatedDefaults()
        let suite = SuiteWorkspace(
            defaults: defaults,
            previewOnly: true,
            makePass: { let p = PassStore(previewOnly: true); p.enterDemo(); return p },
            makeMail: { NativeMailStore(previewOnly: true) },
            makeCalendar: { CalendarStore(previewOnly: true) }
        )
        suite.select(.pass); suite.select(.mail); suite.select(.calendar)
        #expect(suite.pass?.phase == .open && suite.mail?.phase == .open && suite.calendar?.isWorkspaceOpen == true)

        // Default keepMailOpenOnWindowClose == true: closes lock Pass only.
        suite.handleWindowClose()
        #expect(suite.pass?.phase == .locked)
        #expect(suite.mail?.phase == .open)
        #expect(suite.calendar?.isWorkspaceOpen == true)

        // Explicit Lock locks all products.
        suite.lock()
        #expect(suite.mail?.phase == .welcome)
        #expect(suite.calendar?.phase == .welcome)

        // With keepMailOpenOnWindowClose == false: window close locks all products too.
        defaults.set(false, forKey: LockSettings.keepMailOpenOnWindowCloseKey)
        suite.pass?.enterDemo(); suite.mail?.enterDemo(); suite.calendar?.enterPreview()
        suite.handleWindowClose()
        #expect(suite.pass?.phase == .locked)
        #expect(suite.mail?.phase == .welcome)
        #expect(suite.calendar?.phase == .welcome)
    }

    @Test func lockedMailContinuesBackgroundSyncWithStrictAnonymousNotificationsAndReusesHelperOnUnlock() async throws {
        let secretAlert = NativeMailNotification(id: 21, folder: 1, sender: "Private Sender", subject: "Confidential Subject")
        let lockedAlert = NativeMailNotification(id: 22, folder: 1, sender: "Secret Bank", subject: "Private Code 999999")
        let grouped = (30...33).map { NativeMailNotification(id: UInt64($0), folder: 1, sender: "Sender \($0)", subject: "Secret \($0)") }
        let runner = LockedSyncMailRunner(polls: [
            .init(notifications: [secretAlert], unreadCount: 2),
            .init(notifications: [lockedAlert], unreadCount: 3),
            .init(notifications: grouped, unreadCount: 7)
        ])
        let sink = LockSyncNotificationSink()
        let notifDefaults = isolatedDefaults()
        let notifications = NativeNotifications(backend: sink, defaults: notifDefaults)
        await notifications.refreshPermission()
        notifications.update { $0.enabled = true; $0.previews = true; $0.badge = true }
        var openedTarget: (folder: UInt64, item: UInt64)?
        var openMailCalls = 0
        notifications.openMail = { target in openMailCalls += 1; openedTarget = target }

        let mailDefaults = isolatedDefaults()
        final class UnlockGate: @unchecked Sendable { var allowed = false }
        let unlockGate = UnlockGate()
        let mail = NativeMailStore(runner: runner, defaults: mailDefaults, localUnlock: { unlockGate.allowed })
        mail.configureNotifications(notifications, interval: .milliseconds(10))
        mail.configureBackgroundSync(whileLocked: true, interval: .seconds(60))

        // Sign in unlocked: previews are allowed while unlocked.
        mail.signIn(username: "alex@example.com", password: "SYNTHETIC")
        try await awaitCondition { sink.notices.count == 1 }
        #expect(sink.notices[0].body.contains("Private Sender"))
        #expect(sink.notices[0].body.contains("Confidential Subject"))

        // Lock UI while preserving background sync:
        // 1. All visible content clears immediately.
        // 2. Previously delivered preview alert is cleared from Notification Center.
        // 3. New alerts during lock are strictly anonymous with no sender/subject or click route.
        mail.lock(preserveBackgroundSync: true)
        #expect(mail.phase == .locked && mail.messages.isEmpty && mail.folders.isEmpty && mail.email.isEmpty)
        #expect(notifications.lockedMode)
        #expect(mail.backgroundSyncActive)

        try await awaitCondition { sink.notices.count >= 2 }
        for notice in sink.notices {
            #expect(!notice.body.contains("Secret Bank"))
            #expect(!notice.body.contains("999999"))
            #expect(!notice.body.contains("Sender"))
            #expect(notice.body.contains("Unlock ProtonX Mail to view."))
        }
        #expect(sink.dock == 7)

        // Clicking an anonymous alert opens Mail unlock only (target == nil), never routing to a message.
        let anonymousID = try #require(sink.notices.first?.id)
        notifications.clicked(anonymousID)
        #expect(openMailCalls == 1 && openedTarget == nil)

        // Denied local auth still blocks unlocking even though background helper is running.
        mail.unlock(mode: .system)
        try await awaitCondition { !mail.busy }
        #expect(mail.phase == .locked && mail.messages.isEmpty)

        // Approved local auth reopens Mail seamlessly and switches notifications back to unlocked mode.
        unlockGate.allowed = true
        mail.unlock(mode: .system)
        try await awaitCondition { mail.phase == .open && !mail.busy && mail.lastSynced != nil }
        #expect(!notifications.lockedMode)
        #expect(!mail.messages.isEmpty)
        #expect(runner.calls.filter { $0 == "restore" }.isEmpty)

        // Terminate (Quit) stops background sync, cancels helper, and clears alerts & Dock badge.
        mail.terminate()
        #expect(mail.phase == .locked && !mail.backgroundSyncActive)
        #expect(sink.notices.isEmpty && sink.dock == nil && runner.cancellations >= 1)
    }

    @Test func unlockedMailPollTriggersNonBlockingBackgroundRefresh() async throws {
        let initial = NativeMailResult(
            folders: [.init(id: 1, name: "Inbox", count: 1, kind: .inbox)],
            folder: 1,
            messages: [.init(id: 11, subject: "Initial mail", sender: "sam@example.com", unread: true)],
            loading: false,
            email: "alex@example.com",
            fresh: true
        )
        let refreshed = NativeMailResult(
            folders: [.init(id: 1, name: "Inbox", count: 2, kind: .inbox)],
            folder: 1,
            messages: [
                .init(id: 12, subject: "Newly arrived", sender: "jamie@example.com", unread: true),
                .init(id: 11, subject: "Initial mail", sender: "sam@example.com", unread: true)
            ],
            loading: false,
            email: "alex@example.com",
            fresh: true
        )
        let arrival = NativeMailNotification(id: 12, folder: 1, sender: "Jamie", subject: "Newly arrived")
        let runner = LockedSyncMailRunner(
            polls: [.init(notifications: [arrival], unreadCount: 2)],
            snapshots: [initial, refreshed]
        )
        let sink = LockSyncNotificationSink()
        let notifications = NativeNotifications(backend: sink, defaults: isolatedDefaults())
        await notifications.refreshPermission()
        notifications.update { $0.enabled = true }

        let mail = NativeMailStore(runner: runner, defaults: isolatedDefaults())
        mail.configureNotifications(notifications, interval: .milliseconds(10))
        mail.signIn(username: "alex@example.com", password: "SYNTHETIC")
        try await awaitCondition { mail.messages.count == 2 && !mail.backgroundSyncing }
        #expect(mail.messages.first?.id == 12)
        #expect(mail.lastSynced != nil && !mail.backgroundSyncing)
        mail.terminate()
    }

    @Test func passLockedBackgroundCacheSyncRefreshesWithoutDisclosingItemsInMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonXPassBgTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".session"), withIntermediateDirectories: true)
        try Data("Synthetic presence hint".utf8).write(to: root.appendingPathComponent(".session/session.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshotJSON = #"{"vaults":[{"name":"Synthetic","vault_id":"v","share_id":"s","can_create":true,"can_update":true,"can_trash":true}],"items":[{"id":"i","share_id":"s","title":"Synthetic secret title","item_type":"login"}],"trashed_items":[],"capabilities":{"totp_limit":null,"custom_fields_allowed":true},"cache_status":"ready"}"#
        let invalidated = ProtonXError.helperDiagnostic(
            try JSONDecoder().decode(HelperDiagnostic.self, from: Data(#"{"failure":"sessionInvalidated","message":"Session expired"}"#.utf8))
        )
        let runner = PassBgRunner([.success(snapshotJSON), .failure(invalidated)])
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_500)
        let store = PassStore(
            service: PassService(runner: runner),
            sessionDirectory: root,
            previewOnly: false,
            localUnlock: { true },
            now: { fixedNow }
        )
        defer { store.terminate() }
        store.configureBackgroundSync(lockedCacheSync: true, openInterval: .seconds(300), lockedInterval: .seconds(900))
        #expect(store.phase == .locked)

        store.refreshSavedCacheInBackground()
        try await awaitCondition { store.lastBackgroundCacheSyncAt == fixedNow }
        // Pass remains strictly locked with zero metadata held in Swift UI state.
        #expect(store.phase == .locked)
        #expect(store.items.isEmpty && store.vaults.isEmpty && store.detail == nil && store.lastSyncedAt == nil)
        #expect(runner.calls == ["native-snapshot"])

        // Session invalidation during locked cache refresh returns Pass to welcome.
        store.refreshSavedCacheInBackground()
        try await awaitCondition { store.phase == .welcome }
        #expect(store.items.isEmpty)
    }

    @Test func calendarBackgroundRefreshUpdatesEventsAndTimestampWithoutBlockingBusy() async throws {
        let runner = CalendarBgRunner()
        let store = CalendarStore(
            previewOnly: false,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            runner: runner,
            defaults: isolatedDefaults()
        )
        defer { store.lock() }
        store.signIn(username: "alex@example.com", password: "SYNTHETIC")
        try await awaitCondition { store.phase == .connected && !store.busy }
        #expect(store.lastSyncedAt != nil)
        #expect(store.events.first?.title == "Synthetic event 1")

        await runner.setTitle("Synthetic event 2")
        store.backgroundRefresh()
        try await awaitCondition { store.events.first?.title == "Synthetic event 2" && !store.backgroundSyncing }
        #expect(!store.busy && store.syncWarning == nil)
    }

    @Test func syncTimeFormatterProducesReadableRelativeLabels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SyncTimeFormatter.label(for: now.addingTimeInterval(-10), now: now) == "Updated just now")
        #expect(SyncTimeFormatter.label(for: now.addingTimeInterval(-120), now: now) == "Updated 2m ago")
        #expect(SyncTimeFormatter.label(for: now.addingTimeInterval(-7200), now: now) == "Updated 2h ago")
        #expect(SyncTimeFormatter.label(for: now.addingTimeInterval(-120), now: now, prefix: "Last synced") == "Last synced 2m ago")
    }

    @Test func linkedMailCalendarContactsUnlockRestoresPeersWithoutPromptingAndNeverUnlocksPass() async throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "nativeMailConnected")
        defaults.set(true, forKey: "nativeCalendarConnected")

        let passRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonXLinkedPass-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: passRoot.appendingPathComponent(".session"), withIntermediateDirectories: true)
        try Data("Synthetic presence hint".utf8).write(to: passRoot.appendingPathComponent(".session/session.json"))
        defer { try? FileManager.default.removeItem(at: passRoot) }

        let mailRunner = LockedSyncMailRunner()
        let calendarRunner = CalendarBgRunner()
        let passRunner = PassBgRunner([])
        final class Counter: @unchecked Sendable { var count = 0 }
        let mailAuths = Counter(), calendarAuths = Counter(), passAuths = Counter()

        let suite = SuiteWorkspace(
            defaults: defaults,
            previewOnly: false,
            makePass: {
                PassStore(service: PassService(runner: passRunner), sessionDirectory: passRoot, previewOnly: false, localUnlock: {
                    passAuths.count += 1; return false
                })
            },
            makeMail: {
                NativeMailStore(runner: mailRunner, defaults: defaults, previewOnly: false, localUnlock: {
                    mailAuths.count += 1; return true
                })
            },
            makeCalendar: {
                CalendarStore(previewOnly: false, runner: calendarRunner, defaults: defaults, localUnlock: {
                    calendarAuths.count += 1; return true
                })
            }
        )
        defer { suite.terminate() }

        // 1. Unlock Mail once with local auth -> switching to Calendar restores Calendar with 0 extra prompts.
        suite.select(.mail)
        #expect(suite.mail?.phase == .locked)
        suite.mail?.unlock(mode: .system)
        try await awaitCondition { suite.mail?.phase == .open && suite.mail?.busy == false }
        #expect(mailAuths.count == 1)

        suite.select(.calendar)
        try await awaitCondition { suite.calendar?.phase == .connected && suite.calendar?.busy == false }
        #expect(calendarAuths.count == 0)

        // 2. Switching to Pass MUST remain strictly locked and never invoke Pass helper automatically.
        suite.select(.pass)
        #expect(suite.pass?.phase == .locked)
        #expect(passAuths.count == 0 && passRunner.calls.isEmpty)

        // 3. Locking Mail group locks BOTH Mail and Calendar together.
        suite.lockMailGroup(origin: .mail)
        #expect(suite.mail?.phase == .locked && suite.calendar?.phase == .locked)

        // 4. Reverse direction: unlock Calendar once -> switching to Contacts/Mail restores Mail with 0 extra prompts.
        suite.select(.calendar)
        suite.calendar?.unlock(mode: .system)
        try await awaitCondition { suite.calendar?.phase == .connected && suite.calendar?.busy == false }
        #expect(calendarAuths.count == 1)

        suite.select(.contacts)
        try await awaitCondition { suite.mail?.phase == .open && suite.mail?.busy == false }
        #expect(mailAuths.count == 1) // Still 1 from step 1; no second prompt!

        // 5. Disabling linkMailCalendarUnlock restores independent gates.
        suite.lockMailGroup(origin: .calendar)
        defaults.set(false, forKey: LockSettings.linkMailCalendarUnlockKey)
        suite.select(.mail)
        suite.mail?.unlock(mode: .system)
        try await awaitCondition { suite.mail?.phase == .open && suite.mail?.busy == false }
        suite.select(.calendar)
        try await Task.sleep(for: .milliseconds(40))
        #expect(suite.calendar?.phase == .locked)
    }

    @Test func demoMailNeverGrantsLinkedUnlockToRealSavedCalendar() async throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "nativeCalendarConnected")
        let calendarRunner = CalendarBgRunner()
        let suite = SuiteWorkspace(
            defaults: defaults,
            previewOnly: false,
            makeMail: { NativeMailStore(runner: LockedSyncMailRunner(), defaults: defaults, previewOnly: false) },
            makeCalendar: { CalendarStore(previewOnly: false, runner: calendarRunner, defaults: defaults, localUnlock: { false }) }
        )
        defer { suite.terminate() }

        suite.select(.mail)
        suite.mail?.enterDemo()
        #expect(suite.mail?.phase == .open && suite.mail?.demo == true)
        suite.select(.calendar)
        try await Task.sleep(for: .milliseconds(40))
        #expect(suite.calendar?.phase == .locked)
        #expect(await calendarRunner.calls.isEmpty)
    }

    @Test func lockedMailAutoSavesDraftAndRestoresInboxInstantlyWithCleanReaderOnUnlock() async throws {
        let initial = NativeMailResult(
            folders: [.init(id: 1, name: "Inbox", count: 1, kind: .inbox)],
            folder: 1,
            messages: [.init(id: 11, subject: "Retained inbox item", sender: "sam@example.com", unread: true)],
            loading: false,
            email: "alex@example.com",
            fresh: true
        )
        let refreshed = NativeMailResult(
            folders: [.init(id: 1, name: "Inbox", count: 2, kind: .inbox)],
            folder: 1,
            messages: [
                .init(id: 12, subject: "Arrived while locked", sender: "jamie@example.com", unread: true),
                .init(id: 11, subject: "Retained inbox item", sender: "sam@example.com", unread: true)
            ],
            loading: false,
            email: "alex@example.com",
            fresh: true
        )
        let runner = LockedSyncMailRunner(snapshots: [initial, refreshed])
        let mail = NativeMailStore(runner: runner, defaults: isolatedDefaults(), localUnlock: { true })
        mail.configureBackgroundSync(whileLocked: true, interval: .seconds(60))

        // Sign in, open a message body, and open an editing draft with one valid + one half-typed recipient.
        mail.signIn(username: "alex@example.com", password: "SYNTHETIC")
        try await awaitCondition { mail.phase == .open && !mail.busy }
        mail.selectedItem = 11; mail.select()
        try await awaitCondition { mail.body != nil }
        mail.compose()
        try await awaitCondition { mail.draft != nil && !mail.busy }
        mail.editorState?.to = "sam@example.com, half-typed@"
        mail.editorState?.subject = "Important unsaved draft"
        mail.editorState?.text = "Never lose this text"

        // Lock UI with background sync:
        // - Visible state & decrypted body clear immediately
        // - Draft auto-saves (stripping only the half-typed recipient) and closes composer cleanly
        mail.lock(preserveBackgroundSync: true)
        #expect(mail.phase == .locked && mail.messages.isEmpty && mail.folders.isEmpty && mail.body == nil && mail.draft == nil)
        try await awaitCondition { runner.calls.contains("save_draft") && runner.calls.contains("close_draft") }
        let saved = try #require(runner.draftsSaved.first)
        #expect(saved.to == ["sam@example.com"])
        #expect(saved.subject == "Important unsaved draft")
        #expect(saved.text == "Never lose this text")

        // Unlock: inbox restores immediately from retained state, body reloads cleanly, and background sync pulls new mail.
        mail.unlock(mode: .system)
        try await awaitCondition { mail.phase == .open && !mail.busy }
        #expect(!mail.folders.isEmpty && mail.messages.contains(where: { $0.id == 11 }))
        try await awaitCondition { mail.messages.contains(where: { $0.id == 12 }) && mail.body != nil }
        #expect(mail.body == "Synthetic message body")

        // Quit (`prepareForTermination`) flushes an active draft before terminating.
        mail.compose()
        try await awaitCondition { mail.draft != nil && !mail.busy }
        mail.editorState?.subject = "Quit draft"
        mail.editorState?.text = "Saved before quit"
        let suite = SuiteWorkspace(defaults: isolatedDefaults(), previewOnly: false, makeMail: { mail })
        suite.select(.mail)
        var readyToQuit = false
        let deferred = suite.prepareForTermination { readyToQuit = true }
        #expect(deferred)
        try await awaitCondition { readyToQuit }
        #expect(runner.draftsSaved.last?.subject == "Quit draft")
        #expect(runner.draftsSaved.last?.text == "Saved before quit")
        #expect(!mail.backgroundSyncActive && mail.messages.isEmpty)
    }

    @Test func calendarRetainsRangeAcrossUILockForInstantUnlockAndWipesOnTerminate() async throws {
        let runner = CalendarBgRunner()
        let store = CalendarStore(
            previewOnly: false,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            runner: runner,
            defaults: isolatedDefaults(),
            localUnlock: { true }
        )
        store.signIn(username: "alex@example.com", password: "SYNTHETIC")
        try await awaitCondition { store.phase == .connected && !store.busy }
        #expect(store.events.first?.title == "Synthetic event 1")

        store.lock(preserveRetainedState: true)
        #expect(store.phase == .locked && store.events.isEmpty && store.calendars.isEmpty)

        await runner.setTitle("Synthetic event updated while locked")
        store.unlock(mode: .system)
        try await awaitCondition { store.phase == .connected && !store.busy }
        #expect(!store.calendars.isEmpty)
        try await awaitCondition { store.events.first?.title == "Synthetic event updated while locked" && !store.backgroundSyncing }

        store.terminate()
        #expect(store.phase == .locked && store.events.isEmpty)
    }
}
