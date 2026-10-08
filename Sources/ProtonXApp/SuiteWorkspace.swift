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
    let previewOnly: Bool
    private let defaults: UserDefaults
    private let makePass: () -> PassStore
    private let makeMail: () -> NativeMailStore
    private let makeCalendar: () -> CalendarStore
    private let makeNotificationsAvailable: Bool
    private var waitingForAccount: ProductRoute?
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
        switch selected {
        case .pass: pass?.canCreate == true
        case .mail: mail.map { $0.phase == .open && !$0.busy && $0.draft == nil } ?? false
        case .calendar: calendar.map { $0.phase == .preview && !$0.busy && $0.editor == nil } ?? false
        case nil: false
        }
    }
    var canRefresh: Bool {
        switch selected {
        case .pass: pass.map { $0.phase == .open && !$0.busy && !$0.isDemo } ?? false
        case .mail: mail.map { $0.phase == .open && !$0.busy && !$0.demo } ?? false
        case .calendar: calendar.map { $0.isWorkspaceOpen && !$0.busy } ?? false
        case nil: false
        }
    }
    func select(_ product: ProductRoute?) {
        if selected != product {
            if selected == .calendar { waitingForAccount = nil }
            if selected == .calendar && calendar?.phase == .signingIn { calendar?.lock(); accountSourceIsValid = nil }
            if let pending = returnToCalendarFrom, product != pending { returnToCalendarFrom = nil }
            pass?.cancelLocalUnlock(); mail?.cancelLocalUnlock(); calendar?.cancelLocalUnlock()
            if product == .pass { pass?.localAuthentication.arm() }
            if product == .mail { mail?.localAuthentication.arm() }
            if product == .calendar { calendar?.localAuthentication.arm() }
        }
        if product != .pass { passSearchRequested = false }
        if product == .pass && pass == nil {
            let store = makePass(); pass = store
            store.objectWillChange.sink { [weak self] _ in self?.productChanged() }.store(in: &observations)
        }
        if product == .mail && mail == nil {
            let store = makeMail(); mail = store
            if !previewOnly, makeNotificationsAvailable { store.configureNotifications(NativeNotifications.shared) }
            store.objectWillChange.sink { [weak self] _ in self?.productChanged() }.store(in: &observations)
        }
        if product == .calendar && calendar == nil {
            let store = makeCalendar(); calendar = store
            store.objectWillChange.sink { [weak self] _ in self?.productChanged() }.store(in: &observations)
        }
        selected = product
        if let product, !previewOnly { defaults.set(product.rawValue, forKey: "suiteLastProduct") }
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
            let store = makeMail(); mail = store
            if makeNotificationsAvailable { store.configureNotifications(NativeNotifications.shared) }
            store.objectWillChange.sink { [weak self] _ in self?.productChanged() }.store(in:&observations)
        }
        if pass == nil {
            let store = makePass()
            if store.hasSession {
                pass = store
                store.objectWillChange.sink { [weak self] _ in self?.productChanged() }.store(in:&observations)
            }
        }
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
    func lock() {
        waitingForAccount = nil; returnToCalendarFrom = nil; accountSourceIsValid = nil
        passSearchRequested = false
        pass?.lock()
        mail?.lock(); calendar?.lock()
        NotificationCenter.default.post(name: .protonXLock, object: nil)
    }
    func refresh() {
        guard canRefresh else { return }
        switch selected { case .pass: pass?.refresh(); case .mail: mail?.refresh(); case .calendar: calendar?.refresh(); case nil: break }
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
                    PassWindow(isActive: workspace.selected == .pass).environmentObject(pass)
                        .opacity(workspace.selected == .pass ? 1 : 0)
                        .allowsHitTesting(workspace.selected == .pass).accessibilityHidden(workspace.selected != .pass)
                }
                if let mail = workspace.mail {
                    MailWindow(store: mail, isActive: workspace.selected == .mail)
                        .opacity(workspace.selected == .mail ? 1 : 0)
                        .allowsHitTesting(workspace.selected == .mail).accessibilityHidden(workspace.selected != .mail)
                }
                if let calendar = workspace.calendar {
                    CalendarWindow(store: calendar, isActive: workspace.selected == .calendar, accounts: workspace.calendarAccounts, connectAccount: { workspace.connectCalendar(using:$0) }, useAnotherAccount: { workspace.cancelCalendarAccountIntent() })
                        .opacity(workspace.selected == .calendar ? 1 : 0)
                        .allowsHitTesting(workspace.selected == .calendar).accessibilityHidden(workspace.selected != .calendar)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(PassTheme.canvas)
        .navigationTitle(workspace.selected.map { "ProtonX " + $0.displayName } ?? "ProtonX")
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
                if (workspace.selected == .pass && workspace.pass?.busy == true) ||
                   (workspace.selected == .mail && workspace.mail?.busy == true) ||
                   (workspace.selected == .calendar && workspace.calendar?.busy == true) {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                }
                if workspace.selected != nil {
                    Button { workspace.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(!workspace.canRefresh)
                    Button {
                        NotificationCenter.default.post(name: workspace.selected == .calendar ? .protonXNewEvent : workspace.selected == .mail ? .protonXNewMessage : .protonXNewItem, object: nil)
                    } label: { Label(workspace.selected == .calendar ? "New event" : workspace.selected == .mail ? "New message" : "Create item", systemImage: "plus") }
                        .disabled(!workspace.canCreate).accessibilityIdentifier("suiteCreate")
                }
            }
        }
        .background(SuiteWindowRegistration(onClose: { workspace.lock() }).frame(width: 0, height: 0))
        .onAppear {
            if workspace.selected == .pass { workspace.pass?.localAuthentication.arm() }
            if workspace.selected == .mail { workspace.mail?.localAuthentication.arm() }
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
            SystemIntegration.shared.openSettings = { openSettings(); NSApp.activate(ignoringOtherApps: true) }
            SystemIntegration.shared.configure()
        }
        .onDisappear { workspace.lock() }
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
            HStack(spacing: 22) {
                productCard(.pass, title: "Pass", symbol: "key", subtitle: "Passwords and private notes")
                productCard(.mail, title: "Mail", symbol: "envelope", subtitle: "Your inbox and conversations")
                productCard(.calendar, title: "Calendar", symbol: "calendar", subtitle: workspace.previewOnly ? "Native preview · sample events" : "Calendars, events and your week")
            }
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
            }.frame(width: 270, height: 240).background(PassTheme.sidebar, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).accessibilityLabel("Open " + title).accessibilityIdentifier("suiteHome" + title)
    }
}
