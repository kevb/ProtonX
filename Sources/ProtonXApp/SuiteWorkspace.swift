// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import SwiftUI
import ProtonXCore

/// Product stores outlive tab rendering. Preferences contain navigation only;
/// draft contents and product credentials never enter shared defaults.
@MainActor final class SuiteWorkspace: ObservableObject {
    @Published private(set) var selected: ProductRoute?
    @Published private(set) var pass: PassStore?
    @Published private(set) var mail: NativeMailStore?
    @Published private(set) var calendar: CalendarStore?
    @Published var passSearchRequested = false
    @Published var showingAlias = false
    let previewOnly: Bool
    private let defaults: UserDefaults
    private let makePass: () -> PassStore
    private let makeMail: () -> NativeMailStore
    private let makeCalendar: () -> CalendarStore
    private let makeNotificationsAvailable: Bool
    private var systemAuthenticationSuspended = false
    private var waitingForAccount: ProductRoute?
    private var returnToContacts = false
    private var returnToCalendarFrom: ProductRoute?
    private var accountSourceIsValid: (@MainActor () -> Bool)?
    private var observations: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard, previewOnly: Bool = Bundle.main.bundleIdentifier == "org.kevb.ProtonX.Preview",
         initialProduct: ProductRoute? = nil, makePass: (() -> PassStore)? = nil, makeMail: (() -> NativeMailStore)? = nil, makeCalendar: (() -> CalendarStore)? = nil) {
        self.defaults = defaults; self.previewOnly = previewOnly; self.makeNotificationsAvailable = makeMail == nil
        self.makePass = makePass ?? {
            let store = PassStore(previewOnly: previewOnly)
            if previewOnly || ProcessInfo.processInfo.arguments.contains("--demo") { store.enterDemo() }
            return store
        }
        self.makeMail = makeMail ?? { NativeMailStore(previewOnly: previewOnly) }
        self.makeCalendar = makeCalendar ?? { CalendarStore(previewOnly: previewOnly, defaults: defaults) }
        let preference = defaults.string(forKey: "suiteStartup") ?? "last"
        let initial = initialProduct ?? (previewOnly ? nil : (preference == "last" ? defaults.string(forKey: "suiteLastProduct").flatMap(ProductRoute.init(rawValue:)) : ProductRoute(rawValue: preference)))
        select(initial)
    }
    var canCreate: Bool {
        guard !showingAlias else { return false }
        return switch selected {
        case .pass: pass?.canCreate == true
        case .mail: mail.map { $0.phase == .open && !$0.busy && $0.draft == nil } ?? false
        case .contacts: false
        case .calendar: calendar.map { $0.canEdit && !$0.busy && $0.editor == nil } ?? false
        case nil: false
        }
    }
    var canRefresh: Bool {
        guard !showingAlias else { return false }
        return switch selected {
        case .pass: pass.map { $0.phase == .open && !$0.busy && !$0.isDemo } ?? false
        case .mail: mail.map { $0.phase == .open && !$0.busy && !$0.demo } ?? false
        case .contacts: mail.map { $0.phase == .open && !$0.contactsBusy } ?? false
        case .calendar: calendar.map { $0.isWorkspaceOpen && !$0.busy } ?? false
        case nil: false
        }
    }
    var toolbarSyncLabel: String? {
        switch selected {
        case .pass: pass?.isSyncing == true ? (pass?.syncingStatusLabel ?? "Syncing vault…") : nil
        case .mail: mail?.isSyncing == true ? (mail?.syncingStatusLabel ?? "Syncing…") : nil
        case .contacts: mail?.contactsBusy == true ? "Syncing contacts…" : nil
        case .calendar: calendar?.isSyncing == true ? "Syncing calendar…" : nil
        case nil: nil
        }
    }
    var refreshHelp: String {
        switch selected {
        case .pass:
            if let synced = pass?.lastSyncedAt { return "Refresh Pass · \(SyncTimeFormatter.label(for: synced))" }
            return "Refresh Pass (⌘R)"
        case .mail:
            if let synced = mail?.lastSynced { return "Refresh Mail · \(SyncTimeFormatter.label(for: synced))" }
            return "Refresh Mail (⌘R)"
        case .calendar:
            if let synced = calendar?.lastSyncedAt { return "Refresh Calendar · \(SyncTimeFormatter.label(for: synced))" }
            return "Refresh Calendar (⌘R)"
        case .contacts:
            return "Refresh Contacts (⌘R)"
        case nil:
            return "Refresh"
        }
    }
    private func configurePassStore(_ store: PassStore) {
        store.setSystemSuspended(systemAuthenticationSuspended)
        if !previewOnly, makeNotificationsAvailable {
            store.configureBackgroundSync(lockedCacheSync: LockSettings.load(from: defaults).passBackgroundCacheSync)
        }
        store.objectWillChange.sink { [weak self] _ in self?.productChanged() }.store(in: &observations)
    }
    private func configureMailStore(_ store: NativeMailStore) {
        store.setSystemSuspended(systemAuthenticationSuspended)
        if !previewOnly, makeNotificationsAvailable {
            store.configureNotifications(NativeNotifications.shared)
            store.configureBackgroundSync(whileLocked: LockSettings.load(from: defaults).mailBackgroundSyncWhileLocked)
        }
        store.objectWillChange.sink { [weak self] _ in self?.productChanged() }.store(in: &observations)
    }
    private func configureCalendarStore(_ store: CalendarStore) {
        store.setSystemSuspended(systemAuthenticationSuspended)
        store.objectWillChange.sink { [weak self] _ in self?.productChanged() }.store(in: &observations)
    }
    func openAlias() {
        guard selected == .mail ? mail?.phase == .open : selected == .pass && pass?.phase == .open else { return }
        if pass == nil {
            let store = makePass(); pass = store; configurePassStore(store)
        }
        if pass?.phase == .locked { pass?.localAuthentication.arm() }
        showingAlias = true
    }
    func closeAlias() {
        showingAlias = false
        pass?.cancelLocalUnlock()
        if pass?.phase != .open, pass?.busy == true { pass?.cancelLogin() }
    }
    private var canUseLinkedMailCalendarUnlock: Bool {
        guard !previewOnly, !systemAuthenticationSuspended, LockSettings.load(from: defaults).linkMailCalendarUnlock else { return false }
        let mailOpen = mail.map { $0.phase == .open && !$0.demo && !$0.previewOnly } ?? false
        let calendarOpen = calendar.map { $0.phase == .connected && !$0.previewOnly } ?? false
        return mailOpen || calendarOpen
    }
    func lockMailGroup(origin: LockTarget) {
        if LockSettings.load(from: defaults).linkMailCalendarUnlock {
            lock(targets: [.mail, .calendar], forAutomaticLock: false)
        } else {
            lock(targets: [origin], forAutomaticLock: false)
        }
    }
    func select(_ product: ProductRoute?) {
        let changing = selected != product
        if changing {
            if showingAlias { closeAlias() }
            if product != .mail { returnToContacts = false }
            if selected == .calendar { waitingForAccount = nil }
            if selected == .calendar && calendar?.phase == .signingIn { calendar?.lock(); accountSourceIsValid = nil }
            if let pending = returnToCalendarFrom, product != pending { returnToCalendarFrom = nil }
            pass?.cancelLocalUnlock(); mail?.cancelLocalUnlock(); calendar?.cancelLocalUnlock()
        }
        if product != .pass { passSearchRequested = false }
        if product == .pass && pass == nil {
            let store = makePass(); pass = store; configurePassStore(store)
        }
        if (product == .mail || product == .contacts) && mail == nil {
            let store = makeMail(); mail = store; configureMailStore(store)
        }
        if product == .calendar && calendar == nil {
            let store = makeCalendar(); calendar = store; configureCalendarStore(store)
        }
        selected = product
        if let product, !previewOnly { defaults.set(product.rawValue, forKey: "suiteLastProduct") }
        let linked = canUseLinkedMailCalendarUnlock
        if product == .pass {
            if changing { pass?.localAuthentication.arm() }
        } else if product == .mail || product == .contacts {
            if linked && mail?.phase == .locked {
                mail?.unlockLinked()
            } else if changing {
                mail?.localAuthentication.arm()
            }
        } else if product == .calendar {
            if linked && calendar?.phase == .locked {
                calendar?.unlockLinked()
            } else if changing {
                calendar?.localAuthentication.arm()
            }
        }
        if product == .calendar, !previewOnly {
            prepareAccountSources()
            let available = calendarAccounts.filter { !$0.needsUnlock }
            if available.count == 1 {
                if available[0].canContinue { connectCalendar(using:available[0].product) }
                else { waitingForAccount = available[0].product }
            }
        }
    }
    struct CalendarAccountOption: Identifiable {
        let product: ProductRoute
        let title: String
        let needsUnlock: Bool
        let canContinue: Bool
        var id: String { product.rawValue }
    }
    var calendarAccounts: [CalendarAccountOption] {
        guard !previewOnly else { return [] }
        var result: [CalendarAccountOption] = []
        if let mail, !mail.demo, !mail.previewOnly, mail.accountHandoffGeneration != nil || mail.phase == .locked {
            result.append(.init(product:.mail,title:mail.email.isEmpty ? "Your Mail account" : mail.email,needsUnlock:mail.phase == .locked,canContinue:mail.phase == .locked || mail.canConnectCalendar))
        }
        if let pass, !pass.isDemo, !pass.previewOnly, pass.accountHandoffGeneration != nil || pass.phase == .locked {
            result.append(.init(product:.pass,title:"Your Pass account",needsUnlock:pass.phase == .locked,canContinue:pass.phase == .locked || pass.canConnectCalendar))
        }
        return result
    }
    private func prepareAccountSources() {
        // Saved-state hints may construct a locked view, never read credentials or restore.
        if mail == nil && defaults.bool(forKey:"nativeMailConnected") {
            let store = makeMail(); mail = store; configureMailStore(store)
        }
        if pass == nil {
            let store = makePass()
            if store.hasSession {
                pass = store; configurePassStore(store)
            }
        }
    }
    func openMailForContacts() { select(.mail); returnToContacts = true }
    func writeContactEmail(_ addresses: [String]) {
        guard mail?.phase == .open, mail?.draft == nil, mail?.busy == false else { return }
        guard let merged = try? ContactRecipients.appending(addresses, to: "", otherFields: []) else { return }
        select(.mail); mail?.compose(recipients: NativeMailComposeContent.parseRecipients(merged))
    }
    func cancelCalendarAccountIntent() { waitingForAccount = nil; returnToCalendarFrom = nil }
    func connectCalendar(using product: ProductRoute) {
        guard selected == .calendar, !previewOnly, calendar?.phase == .welcome, calendar?.busy == false else { return }
        waitingForAccount = nil
        if product == .mail, let mail {
            if mail.phase == .locked { select(.mail); returnToCalendarFrom = .mail; return }
            guard mail.canConnectCalendar, let ticket = mail.accountHandoffGeneration else { return }
            let valid: @MainActor @Sendable () -> Bool = { [weak mail] in mail?.accountHandoffGeneration == ticket }
            accountSourceIsValid = valid
            calendar?.connectAccount(produce:{ try await mail.calendarHandoff() },sourceIsValid:valid)
        } else if product == .pass, let pass {
            if pass.phase == .locked { select(.pass); returnToCalendarFrom = .pass; return }
            guard pass.canConnectCalendar, let ticket = pass.accountHandoffGeneration else { return }
            let valid: @MainActor @Sendable () -> Bool = { [weak pass] in pass?.accountHandoffGeneration == ticket }
            accountSourceIsValid = valid
            calendar?.connectAccount(produce:{ try await pass.calendarHandoff() },sourceIsValid:valid)
        }
    }
    private func productChanged() {
        objectWillChange.send()
        // Published callbacks arrive before the new value is set.
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            if returnToContacts, selected == .mail, mail?.phase == .open, mail?.busy == false {
                returnToContacts = false; select(.contacts)
            }
            if let valid = accountSourceIsValid {
                if calendar?.phase != .signingIn { accountSourceIsValid = nil }
                else if !valid() { calendar?.lock(); calendar?.error = "Your account was locked while Calendar was connecting. Unlock it and try again."; accountSourceIsValid = nil }
            }
            if let product = waitingForAccount, selected == .calendar, calendar?.phase == .welcome,
               calendar?.error == nil, calendarAccounts.first(where:{$0.product == product})?.canContinue == true {
                waitingForAccount = nil; connectCalendar(using:product)
            }
            if let product = returnToCalendarFrom, selected == product,
               (product == .mail ? mail?.canConnectCalendar == true : pass?.canConnectCalendar == true) {
                returnToCalendarFrom = nil; select(.calendar)
            }
        }
    }
    func suspendAuthentication(_ suspended: Bool) {
        systemAuthenticationSuspended = suspended
        pass?.setSystemSuspended(suspended)
        mail?.setSystemSuspended(suspended)
        calendar?.setSystemSuspended(suspended)
    }
    func startBackgroundSync() {
        guard !previewOnly else { return }
        let settings = LockSettings.load(from: defaults)
        if settings.mailBackgroundSyncWhileLocked && defaults.bool(forKey: "nativeMailConnected") {
            if mail == nil {
                let store = makeMail(); mail = store; configureMailStore(store)
            } else {
                mail?.configureBackgroundSync(whileLocked: true)
            }
            if mail?.phase == .locked { mail?.startLockedBackgroundSync() }
        }
        if settings.passBackgroundCacheSync {
            if pass == nil {
                let store = makePass()
                if store.hasSession { pass = store; configurePassStore(store) }
            } else {
                pass?.configureBackgroundSync(lockedCacheSync: true)
            }
        }
    }
    func applyBackgroundSyncSettings() {
        guard !previewOnly else { return }
        let settings = LockSettings.load(from: defaults)
        mail?.configureBackgroundSync(whileLocked: settings.mailBackgroundSyncWhileLocked)
        pass?.configureBackgroundSync(lockedCacheSync: settings.passBackgroundCacheSync)
        if settings.mailBackgroundSyncWhileLocked || settings.passBackgroundCacheSync {
            startBackgroundSync()
        }
    }
    func handleForegroundReturn() {
        guard !previewOnly else { return }
        mail?.handleForegroundReturn()
        pass?.handleForegroundReturn()
        calendar?.handleForegroundReturn()
    }
    func handleWindowClose() {
        let settings = LockSettings.load(from: defaults)
        let targets = settings.targetsForWindowClose()
        if targets.contains(.mail), !settings.mailBackgroundSyncWhileLocked, let mail, mail.hasUnsavedEditingDraft {
            // Flush unsaved draft before tearing down Mail when background sync while locked is disabled.
            lock(targets: targets.subtracting([.mail]), forAutomaticLock: false)
            Task { [weak self] in
                await mail.flushDraftBeforeShutdown()
                self?.lock(targets: [.mail], forAutomaticLock: false)
            }
            return
        }
        lock(targets: targets, forAutomaticLock: false)
    }
    func prepareForTermination(_ done: @escaping @MainActor () -> Void) -> Bool {
        guard let mail, mail.hasUnsavedEditingDraft else { return false }
        Task { [weak self] in
            await mail.flushDraftBeforeShutdown()
            self?.terminate()
            done()
        }
        return true
    }
    func terminate() {
        lock(targets: Set(LockTarget.allCases), forAutomaticLock: false, preserveBackgroundSync: false)
        mail?.terminate()
        pass?.terminate()
        calendar?.terminate()
    }
    func lock(targets: Set<LockTarget> = Set(LockTarget.allCases), forAutomaticLock: Bool = false, preserveBackgroundSync: Bool? = nil) {
        let settings = LockSettings.load(from: defaults)
        let keepMailSync = preserveBackgroundSync ?? (!previewOnly && settings.mailBackgroundSyncWhileLocked)
        let keepPassCacheSync = preserveBackgroundSync ?? (!previewOnly && settings.passBackgroundCacheSync)
        if targets.contains(.pass) || (targets.contains(.mail) && selected == .mail) {
            if showingAlias { closeAlias() }
        }
        if targets.contains(.mail) { returnToContacts = false }
        if targets.contains(.calendar) {
            waitingForAccount = nil; returnToCalendarFrom = nil; accountSourceIsValid = nil
        }
        if targets.contains(.pass) { passSearchRequested = false }
        // Repeated automatic locks must leave already-locked products alone: otherwise
        // overlapping sleep/lock events could disarm the pending attempt or undo Cancel.
        if targets.contains(.pass), let pass, !forAutomaticLock || pass.phase == .open || pass.busy {
            let rearm = forAutomaticLock && !pass.previewOnly && !pass.isDemo &&
                (pass.phase == .open || (pass.localAuthentication.state == .authenticating && pass.localAuthentication.mode == .touchID))
            pass.lock(preserveLockedCacheSync: keepPassCacheSync)
            if rearm, pass.phase == .locked { pass.localAuthentication.arm() }
        }
        if targets.contains(.mail), let mail, !forAutomaticLock || (mail.phase != .locked && mail.phase != .welcome) || mail.busy {
            let rearm = forAutomaticLock && !mail.previewOnly && !mail.demo &&
                (mail.phase == .open || (mail.localAuthentication.state == .authenticating && mail.localAuthentication.mode == .touchID))
            mail.lock(preserveBackgroundSync: keepMailSync)
            if rearm, mail.phase == .locked { mail.localAuthentication.arm() }
        }
        if targets.contains(.calendar), let calendar, !forAutomaticLock || (calendar.phase != .locked && calendar.phase != .welcome) || calendar.busy {
            let rearm = forAutomaticLock && !calendar.previewOnly &&
                (calendar.phase == .connected || (calendar.localAuthentication.state == .authenticating && calendar.localAuthentication.mode == .touchID))
            calendar.lock(preserveRetainedState: keepMailSync)
            if rearm, calendar.phase == .locked { calendar.localAuthentication.arm() }
        }
        if targets.contains(.mail) {
            NotificationCenter.default.post(name: .protonXLock, object: nil)
        }
    }
    func refresh() {
        guard canRefresh else { return }
        switch selected { case .pass: pass?.refresh(); case .mail: mail?.refresh(); case .calendar: calendar?.refresh(); case .contacts: mail?.loadContacts(); case nil: break }
    }
    func requestPassSearch() { select(.pass); passSearchRequested = true }
}

struct SuiteWindow: View {
    @ObservedObject var workspace: SuiteWorkspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            ZStack {
                home.opacity(workspace.selected == nil ? 1 : 0)
                    .allowsHitTesting(workspace.selected == nil).accessibilityHidden(workspace.selected != nil)
                // Stable view identities retain split views, scroll positions and
                // editor state. Hiding is navigation, not locking or logout.
                if let pass = workspace.pass {
                    PassWindow(isActive: workspace.selected == .pass, newAlias: { workspace.openAlias() }).environmentObject(pass)
                        .opacity(workspace.selected == .pass ? 1 : 0)
                        .allowsHitTesting(workspace.selected == .pass).accessibilityHidden(workspace.selected != .pass)
                }
                if let mail = workspace.mail {
                    MailWindow(store: mail, isActive: workspace.selected == .mail, newAlias: { workspace.openAlias() }, lockMail: { workspace.lockMailGroup(origin: .mail) })
                        .opacity(workspace.selected == .mail ? 1 : 0)
                        .allowsHitTesting(workspace.selected == .mail).accessibilityHidden(workspace.selected != .mail)
                }
                if let mail = workspace.mail {
                    ContactsWindow(store: mail, isActive: workspace.selected == .contacts, openMail: { workspace.openMailForContacts() }, writeEmail: { workspace.writeContactEmail($0) })
                        .opacity(workspace.selected == .contacts ? 1 : 0)
                        .allowsHitTesting(workspace.selected == .contacts).accessibilityHidden(workspace.selected != .contacts)
                }
                if let calendar = workspace.calendar {
                    CalendarWindow(store: calendar, isActive: workspace.selected == .calendar, accounts: workspace.calendarAccounts, connectAccount: { workspace.connectCalendar(using:$0) }, useAnotherAccount: { workspace.cancelCalendarAccountIntent() }, lockCalendar: { workspace.lockMailGroup(origin: .calendar) })
                        .opacity(workspace.selected == .calendar ? 1 : 0)
                        .allowsHitTesting(workspace.selected == .calendar).accessibilityHidden(workspace.selected != .calendar)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(PassTheme.canvas)
        .navigationTitle(workspace.selected.map { "ProtonX " + $0.displayName } ?? "ProtonX")
        .sheet(isPresented: $workspace.showingAlias, onDismiss: { workspace.closeAlias() }) {
            if let pass = workspace.pass {
                AliasEditor(store: pass, close: { workspace.closeAlias() }, viewInPass: { result, vault in
                    workspace.closeAlias(); workspace.select(.pass); pass.selectAlias(result, vaultID: vault)
                })
            }
        }
        .focusedSceneValue(\.protonXProduct, workspace.selected)
        .focusedSceneValue(\.protonXCanCreate, workspace.canCreate)
        .focusedSceneValue(\.protonXCanRefresh, workspace.canRefresh)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if workspace.selected == .pass, let pass = workspace.pass, pass.phase == .open {
                    NativeSearchField(text: Binding(get: { pass.query }, set: { pass.query = $0 }),
                                      focusRequested: $workspace.passSearchRequested).frame(width: 250)
                }
                if workspace.selected == .mail, let mail = workspace.mail, mail.phase == .open, mail.draft == nil {
                    Picker("Mail view", selection: Binding(get: { mail.conversationView }, set: { mail.conversationView = $0 })) {
                        Text("Conversations").tag(true); Text("Messages").tag(false)
                    }.pickerStyle(.menu).accessibilityIdentifier("mailConversationView")
                }
                if workspace.selected == .mail, workspace.mail?.phase == .open {
                    Button { workspace.openAlias() } label: { Label("New email alias…", systemImage: "at.badge.plus") }
                        .help("Create a hide-my-email alias in Pass").accessibilityIdentifier("suiteNewAlias")
                }
                if let syncLabel = workspace.toolbarSyncLabel {
                    ToolbarSyncPill(label: syncLabel)
                }
                if workspace.selected != nil {
                    Button { workspace.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help(workspace.refreshHelp)
                        .disabled(!workspace.canRefresh)
                    if workspace.selected != .contacts {
                    if workspace.selected == .pass {
                        Menu {
                            Button("Login or secure note…") { NotificationCenter.default.post(name: .protonXNewItem, object: nil) }
                            Button("Email alias…", systemImage: "at.badge.plus") { workspace.openAlias() }
                        } label: { Label("Create item", systemImage: "plus") }
                        .disabled(!workspace.canCreate).accessibilityIdentifier("suiteCreate")
                    } else {
                    Button {
                        NotificationCenter.default.post(name: workspace.selected == .calendar ? .protonXNewEvent : workspace.selected == .mail ? .protonXNewMessage : .protonXNewItem, object: nil)
                    } label: { Label(workspace.selected == .calendar ? "New event" : workspace.selected == .mail ? "New message" : "Create item", systemImage: "plus") }
                        .disabled(!workspace.canCreate).accessibilityIdentifier("suiteCreate")
                    }
                    }
                }
            }
        }
        .background(SuiteWindowRegistration(onClose: { workspace.handleWindowClose() }).frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: .protonXSettingsChanged)) { _ in
            workspace.applyBackgroundSyncSettings()
        }
        .onAppear {
            if workspace.selected == .pass { workspace.pass?.localAuthentication.arm() }
            if workspace.selected == .mail || workspace.selected == .contacts { workspace.mail?.localAuthentication.arm() }
            if workspace.selected == .calendar { workspace.calendar?.localAuthentication.arm() }
            ProductWindows.shared.installSelector { workspace.select($0) }
            ProductWindows.shared.installOpener { _ in openWindow(id: "suite") }
            SystemIntegration.shared.openHome = { workspace.select(nil); ProductWindows.shared.showSuite() }
            SystemIntegration.shared.openPassForSearch = { workspace.requestPassSearch(); ProductWindows.shared.open(.pass) }
            NativeNotifications.shared.openMail = { target in
                ProductWindows.shared.open(.mail)
                if let target { workspace.mail?.openNotification(folder: target.folder, item: target.item) }
            }
            SystemIntegration.shared.lockSuite = { workspace.lock() }
            SystemIntegration.shared.terminateSuite = { workspace.terminate() }
            SystemIntegration.shared.prepareForTermination = { done in workspace.prepareForTermination(done) }
            SystemIntegration.shared.suspendAuthentication = { workspace.suspendAuthentication($0) }
            SystemIntegration.shared.lockSuiteAutomatically = { workspace.lock(forAutomaticLock: true) }
            SystemIntegration.shared.lockProductsAutomatically = { targets in workspace.lock(targets: targets, forAutomaticLock: true) }
            SystemIntegration.shared.appDidBecomeActive = { workspace.handleForegroundReturn() }
            SystemIntegration.shared.openSettings = { openSettings(); NSApp.activate(ignoringOtherApps: true) }
            SystemIntegration.shared.configure()
            workspace.startBackgroundSync()
        }
        .onDisappear { workspace.handleWindowClose() }
    }
    private var rail: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 23)).foregroundStyle(PassTheme.accent)
                .padding(.top, 16).padding(.bottom, 10).accessibilityHidden(true)
            railButton("Home", symbol: "square.grid.2x2", product: nil, shortcut: "⌘0")
            Divider().padding(.horizontal, 14)
            railButton("Pass", symbol: "key", product: .pass, shortcut: "⌘1")
            railButton("Mail", symbol: "envelope", product: .mail, shortcut: "⌘2")
            railButton("Calendar", symbol: "calendar", product: .calendar, shortcut: "⌘3")
            railButton("Contacts", symbol: "person.crop.rectangle", product: .contacts, shortcut: "⌘4")
            Spacer()
            Button { workspace.lock() } label: { Image(systemName: "lock").frame(width: 46, height: 36) }
                .buttonStyle(.plain).help("Lock ProtonX (⌘L)").accessibilityLabel("Lock ProtonX")
            Button { openSettings() } label: { Image(systemName: "gearshape").frame(width: 46, height: 36) }
                .buttonStyle(.plain).help("Settings (⌘,)").accessibilityLabel("Settings")
        }.padding(.horizontal, 8).padding(.bottom, 14).frame(width: 76)
            .background(PassTheme.sidebar)
    }
    private func railButton(_ name: String, symbol: String, product: ProductRoute?, shortcut: String) -> some View {
        let selected = workspace.selected == product
        return Button { workspace.select(product) } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                Text(name).font(.system(size: 10, weight: .medium))
            }.frame(width: 60, height: 58)
                .foregroundStyle(selected ? PassTheme.accent : .secondary)
                .background(selected ? PassTheme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .leading) { if selected { Capsule().fill(PassTheme.accent).frame(width: 3, height: 22) } }
        }.buttonStyle(.plain).help("\(name) (\(shortcut))")
            .accessibilityLabel(name).accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("suiteRail" + name)
    }
    private var home: some View {
        VStack(spacing: 32) {
            VStack(spacing: 10) {
                Text("Welcome to ProtonX").font(.system(size: 32, weight: .semibold))
                Text("Your Proton suite, at home on Mac.").font(.title3).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                productCard(.pass, title: "Pass", symbol: "key", subtitle: "Passwords and private notes")
                productCard(.mail, title: "Mail", symbol: "envelope", subtitle: "Your inbox and conversations")
                productCard(.contacts, title: "Contacts", symbol: "person.crop.rectangle", subtitle: "People and your address book")
                productCard(.calendar, title: "Calendar", symbol: "calendar", subtitle: workspace.previewOnly ? "Native preview · sample events" : "Calendars, events and your week")
            }
            .frame(maxWidth: 650)
            Text("Switch products anytime. Your place stays with you.")
                .font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("suiteHome")
    }
    private func productCard(_ product: ProductRoute, title: String, symbol: String, subtitle: String) -> some View {
        Button { workspace.select(product) } label: {
            VStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(PassTheme.accent)
                    .frame(width: 80, height: 80).background(PassTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).frame(height: 220).background(PassTheme.sidebar, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).accessibilityLabel("Open " + title).accessibilityIdentifier("suiteHome" + title)
    }
}
