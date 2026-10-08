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
        self.makeCalendar = makeCalendar ?? { CalendarStore(previewOnly: previewOnly) }
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
        case .calendar: calendar.map { $0.phase == .preview && !$0.busy } ?? false
        case nil: false
        }
    }
    func select(_ product: ProductRoute?) {
        if selected != product {
            pass?.cancelLocalUnlock(); mail?.cancelLocalUnlock()
            if product == .pass { pass?.localAuthentication.arm() }
            if product == .mail { mail?.localAuthentication.arm() }
        }
        if product != .pass { passSearchRequested = false }
        if product == .pass && pass == nil {
            let store = makePass(); pass = store
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
        if product == .mail && mail == nil {
            let store = makeMail(); mail = store
            if !previewOnly, makeNotificationsAvailable { store.configureNotifications(NativeNotifications.shared) }
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
        if product == .calendar && calendar == nil {
            let store = makeCalendar(); calendar = store
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
        selected = product
        if let product, !previewOnly { defaults.set(product.rawValue, forKey: "suiteLastProduct") }
    }
    func lock() {
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
                    CalendarWindow(store: calendar, isActive: workspace.selected == .calendar)
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
                productCard(.calendar, title: "Calendar", symbol: "calendar", subtitle: "Native preview · sample events")
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
