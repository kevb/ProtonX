import SwiftUI
import ProtonXCore

struct PassWindow: View {
    @EnvironmentObject var store: PassStore
    @Environment(\.openSettings) private var openSettings
    @State private var showingCreate = false
    @State private var showingEdit = false
    @State private var confirmTrash = false
    @State private var confirmSignOut = false
    var body: some View {
        Group {
            if store.phase == .open { workspace } else { WelcomeView() }
        }
        .focusedSceneValue(\.protonXProduct, .pass)
        .focusedSceneValue(\.protonXCanCreate, store.canCreate)
        .focusedSceneValue(\.protonXCanRefresh, store.phase == .open && !store.busy && !store.isDemo)
        .frame(minWidth: 820, minHeight: 540)
        .toolbar { ToolbarItem(placement: .navigation) { SuiteProductSwitcher(current: "pass") } }
        .preferredColorScheme(previewColorScheme)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = store.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle"); Text(error).font(.callout); Spacer()
                    if store.mustRefreshBeforeWriting { Button("Refresh Vault") { store.refresh() }.disabled(store.busy) }
                    Button("Dismiss") { store.error = nil }
                }
                    .padding(12).background(.orange.opacity(0.12)).accessibilityIdentifier("errorBanner")
            }
        }
        .sheet(isPresented: $showingCreate) { ItemEditor(editing: false) }
        .sheet(isPresented: $showingEdit) { ItemEditor(editing: true) }
        .confirmationDialog(store.showingTrash ? "Restore this item?" : "Move this item to Trash?", isPresented: $confirmTrash) {
            Button(store.showingTrash ? "Restore" : "Move to Trash", role: store.showingTrash ? nil : .destructive) { store.trashCurrent() }
        }
        .confirmationDialog("Sign out of ProtonX Pass?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { store.signOut() }
        } message: { Text("This removes this app’s saved Pass session and encrypted local cache after remote logout succeeds.") }
        .onChange(of: store.phase) { _, phase in
            if phase != .open { showingCreate = false; showingEdit = false; confirmTrash = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .protonXNewItem)) { _ in if store.canCreate { showingCreate = true } }
        .productWindow(.pass)
        .onAppear {
            SystemIntegration.shared.lockSuite = { store.lock(); NotificationCenter.default.post(name: .protonXLock, object: nil) }
            SystemIntegration.shared.openSettings = { openSettings(); NSApp.activate(ignoringOtherApps: true) }
            SystemIntegration.shared.configure()
            if store.previewOnly || ProcessInfo.processInfo.arguments.contains("--demo") { store.enterDemo() }
        }
    }
    private var workspace: some View {
        NavigationSplitView {
            List(selection: collectionSelection) {
                Section {
                    sidebarRow("All items", symbol: "square.grid.2x2", selection: "all", count: store.items.count).tag("all")
                    sidebarRow("Logins", symbol: "key", selection: "kind:login", count: store.items.filter { $0.kind == "login" }.count).tag("kind:login")
                    sidebarRow("Notes", symbol: "note.text", selection: "kind:note", count: store.items.filter { $0.kind == "note" }.count).tag("kind:note")
                }
                Section("Types") {
                    ForEach([("credit_card", "Cards", "creditcard"), ("identity", "Identities", "person.text.rectangle"), ("wifi", "Wi-Fi", "wifi"), ("alias", "Aliases", "at"), ("ssh_key", "SSH keys", "terminal"), ("custom", "Other items", "doc.text")], id: \.0) { type in
                        if store.items.contains(where: { $0.kind == type.0 }) { sidebarRow(type.1, symbol: type.2, selection: "kind:" + type.0).tag("kind:" + type.0) }
                    }
                }
                Section("Vaults") {
                    ForEach(store.vaults) { vault in
                        sidebarRow(vault.name, symbol: vault.canUpdate == true ? "folder" : "folder.badge.person.crop", selection: "vault:" + vault.id, count: store.items.filter { $0.shareID == vault.id }.count).tag("vault:" + vault.id)
                    }
                }
                Section { sidebarRow("Trash", symbol: "trash", selection: "trash", count: store.trashedItems.count).tag("trash") }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .background(PassTheme.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 300)
            .safeAreaInset(edge: .top, spacing: 0) {
                PassWordmark().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 20)
                    .background(PassTheme.sidebar)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.isDemo ? "Demo workspace" : "Pass workspace").font(.system(size: 13, weight: .medium))
                    if store.isUsingSavedVault {
                        Label(store.busy ? "Saved vault · refreshing" : "Saved vault · read only", systemImage: "internaldrive").font(.caption).foregroundStyle(PassTheme.accent)
                        Button("Refresh Online") { store.refresh() }.disabled(store.busy).accessibilityIdentifier("recoverPassSync")
                    } else if store.mustRefreshBeforeWriting {
                        Label("Refresh needed before changes", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange)
                        Button("Refresh Vault") { store.refresh() }.disabled(store.busy).accessibilityIdentifier("recoverPassSync")
                    }
                    if !store.isDemo && !store.isUsingSavedVault {
                        if store.offlineCacheStatus == "ready" {
                            Label("Encrypted saved vault ready", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                        } else if store.offlineCacheStatus == "unavailable" {
                            Label("Saved vault unavailable", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        } else if store.offlineCacheStatus == "planUnavailable" {
                            Text("This account requires an online connection").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let synced = store.lastSyncedAt {
                        HStack(spacing: 6) {
                            Circle().fill(store.mustRefreshBeforeWriting ? Color.orange : Color.green).frame(width: 5, height: 5).accessibilityHidden(true)
                            Text("\(store.isUsingSavedVault ? "Last synced" : "Updated") \(synced, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button { store.lock() } label: { Label("Lock", systemImage: "lock").fixedSize() }.buttonStyle(PassPillStyle()).help("Lock ProtonX (⌘L)")
                        Spacer()
                        Menu { Button("Settings…") { openSettings() }; Button("Sign Out…", role: .destructive) { confirmSignOut = true } } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).frame(width: 44, height: 28).accessibilityLabel("Account actions")
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(PassTheme.sidebar)
            }
        } content: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(collectionTitle).font(.system(size: 19, weight: .semibold))
                        Text("\(store.filteredItems.count) item\(store.filteredItems.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Picker("Sort items", selection: $store.sort) { ForEach(ItemSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Sort items")
                }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 16)
                List(store.filteredItems, selection: $store.selectedItem) { item in
                HStack(spacing: 12) {
                    PassItemBadge(symbol: item.symbol, kind: item.kind, selected: store.selectedItem == item.id)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.system(size: 14, weight: store.selectedItem == item.id ? .semibold : .medium)).lineLimit(1)
                        Text(store.vaults.first { $0.id == item.shareID }?.name ?? "Vault").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 10).accessibilityElement(children: .combine).accessibilityValue(item.typeName).tag(item.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
            }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
                .overlay {
                    if store.isLoadingInitialSnapshot {
                        ProgressView("Loading your vault…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if store.initialSnapshotFailed {
                        ContentUnavailableView {
                            Label("Could not load your vault", systemImage: "exclamationmark.circle")
                        } description: {
                            Text("Try refreshing when your connection is available.")
                        } actions: { Button("Retry") { store.refresh() } }
                    } else if store.filteredItems.isEmpty {
                        ContentUnavailableView {
                            Label(store.query.isEmpty ? (store.showingTrash ? "Trash is empty" : "No items yet") : "No matching items", systemImage: store.query.isEmpty ? (store.showingTrash ? "trash" : "key") : "magnifyingglass")
                        } description: {
                            Text(store.query.isEmpty ? (store.showingTrash ? "Items you move to Trash can be restored here." : "Create a login or secure note in this vault.") : "Try a different title or clear your search.")
                        } actions: {
                            if !store.query.isEmpty { Button("Clear Search") { store.query = "" } }
                            else if store.canCreate { Button("Create Item") { showingCreate = true } }
                        }
                    }
                }
            }.background(PassTheme.collection).navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 440)
        } detail: {
            if let item = store.currentItem {
                if let detail = store.detail {
                    ItemDetailView(detail: detail, onEdit: { showingEdit = true }, onTrash: { confirmTrash = true })
                        .id(item.id + ":" + String(detail.revision ?? 0))
                } else if store.error != nil {
                    ContentUnavailableView { Label("Could not open item", systemImage: "exclamationmark.triangle") }
                        description: { Text("Your vault is unchanged. You can retry when your connection is available.") }
                        actions: { Button("Retry") { store.selectItem() } }
                } else { ProgressView("Opening item…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else { ContentUnavailableView("Your vault, at home on Mac", systemImage: "key", description: Text("Choose an item to view its details.")) }
        }
        .background(PassTheme.canvas)
        .navigationTitle("ProtonX Pass")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NativeSearchField(text: $store.query).frame(width: 280)
                if store.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(store.busy || store.isDemo)
                Button { showingCreate = true } label: { HStack(spacing: 7) { Image(systemName: "plus"); Text("Create item") }.fixedSize() }
                    .buttonStyle(PassPillStyle(primary: true)).disabled(!store.canCreate).accessibilityLabel("Create item").accessibilityIdentifier("newItem")
            }
        }
    }
    private var previewColorScheme: ColorScheme? {
        #if PROTONX_DESIGN_LIGHT
        if store.previewOnly { return .light }
        #endif
        return nil
    }
    private var collectionTitle: String {
        if store.showingTrash { return "Trash" }
        if let vault = store.vaults.first(where: { $0.id == store.selectedVault }) { return vault.name }
        if let kind = store.kind {
            return ["login": "Logins", "note": "Secure notes", "credit_card": "Cards", "identity": "Identities", "wifi": "Wi-Fi", "alias": "Aliases", "ssh_key": "SSH keys"][kind] ?? "Other items"
        }
        return "All items"
    }
    private var collectionSelection: Binding<String?> {
        Binding(get: {
            if store.showingTrash { return "trash" }
            if let vault = store.selectedVault { return "vault:" + vault }
            if let kind = store.kind { return "kind:" + kind }
            return "all"
        }, set: { value in
            guard let value else { return }
            store.showingTrash = value == "trash"
            store.selectedVault = value.hasPrefix("vault:") ? String(value.dropFirst(6)) : nil
            store.kind = value.hasPrefix("kind:") ? String(value.dropFirst(5)) : nil
        })
    }
    private func sidebarRow(_ title: String, symbol: String, selection: String, count: Int? = nil) -> some View {
        HStack {
            Image(systemName: symbol).font(.system(size: 16, weight: .regular)).foregroundStyle(collectionSelection.wrappedValue == selection ? PassTheme.selectedInk : PassTheme.accent)
                .frame(width: 28, height: 32)
                .background(collectionSelection.wrappedValue == selection ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Spacer()
            if let count { Text(String(count)).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 7).contentShape(Rectangle())
    }

}

struct WelcomeView: View {
    @EnvironmentObject var store: PassStore
    @State private var answer = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: store.phase == .locked ? "lock.shield" : "key.horizontal")
                .font(.system(size: 40, weight: .light)).foregroundStyle(PassTheme.accent)
                .frame(width: 88, height: 88).background(PassTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 28))
            Text(store.phase == .locked ? "Pass is locked" : "ProtonX Pass").font(.largeTitle.weight(.semibold))
            Text(store.phase == .locked ? (store.isDemo ? "Unlock the demo to explore synthetic data." : "Unlock with Touch ID or your Mac password.") : "Your Proton vault. A native Mac experience.").foregroundStyle(.secondary)
            if let challenge = store.challenge {
                VStack(alignment: .leading, spacing: 10) {
                    Text(challenge.title).font(.headline)
                    Group { if challenge.secure { SecureField(challenge.title, text: $answer) } else { TextField(challenge.title, text: $answer) } }
                        .textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit)
                        .accessibilityIdentifier("authAnswer")
                    HStack { Button("Cancel") { answer = ""; store.cancelLogin() }; Spacer(); Button("Continue", action: submit).keyboardShortcut(.defaultAction).disabled(answer.isEmpty) }
                }.frame(width: 330)
            } else if store.busy {
                ProgressView("Connecting to Proton…")
                Button("Cancel") { store.cancelLogin() }
            } else {
                Button(store.previewOnly ? "Explore Preview" : (store.phase == .locked ? "Unlock Pass" : "Sign In to Proton")) { store.previewOnly ? store.enterDemo() : (store.phase == .locked ? store.unlock() : store.login()) }
                    .buttonStyle(PassPillStyle(primary: true)).keyboardShortcut(.defaultAction)
                if store.phase == .locked && !store.isDemo { Button("Sign In Again") { store.login() } }
                if store.phase == .welcome && !store.previewOnly { Button("Try direct password sign-in (experimental)") { store.login(interactive: true) }.font(.caption) }
                if store.phase == .welcome { Button("Explore with demo data") { store.enterDemo() }.accessibilityIdentifier("enterDemo") }
            }
            Text("Independent open source client · GPL-3.0-or-later\nNot affiliated with Proton AG").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(48).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PassTheme.canvas; RadialGradient(colors: [PassTheme.accent.opacity(0.08), .clear], center: .top, startRadius: 0, endRadius: 600) }
        .onChange(of: store.challenge) { _, _ in answer = ""; focused = true }
        .onChange(of: store.phase) { _, _ in answer = "" }
    }
    private func submit() { let value = answer; answer = ""; store.answerCredential(value) }
}

struct ItemDetailView: View {
    @EnvironmentObject var store: PassStore
    let detail: ItemDetail
    let onEdit: () -> Void
    let onTrash: () -> Void
    @State private var revealed = Set<String>()
    @State private var copied: String?
    private func readableDate(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.timeZone = TimeZone(secondsFromGMT: 0)
        return parser.date(from: value.hasSuffix("Z") ? value : value + "Z")?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
    private func fieldSymbol(_ field: SecretField) -> String {
        switch field.label { case "Password": "key"; case "Username", "Email": "person"; case "Card number": "creditcard"; default: field.concealed ? "lock" : "text.alignleft" }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    PassItemBadge(symbol: store.currentItem?.symbol ?? "key", kind: store.currentItem?.kind ?? "login", size: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail.title).font(.system(size: 23, weight: .semibold)).textSelection(.enabled).lineLimit(3)
                        Text(store.currentVault?.name ?? store.currentItem?.typeName ?? "Item").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: onEdit) { Label("Edit", systemImage: "pencil") }.buttonStyle(PassPillStyle()).disabled(store.busy || !store.canEdit)
                    Menu {
                        Button(store.showingTrash ? "Restore item" : "Move to Trash", systemImage: store.showingTrash ? "arrow.uturn.backward" : "trash", action: onTrash)
                            .disabled(store.busy || !store.canTrash)
                    } label: { Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 38, height: 38).background(PassTheme.accent.opacity(0.08), in: Circle()) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Item actions")
                }.padding(.bottom, 10)
                if !detail.fields.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(detail.fields.enumerated()), id: \.offset) { index, field in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: fieldSymbol(field)).font(.system(size: 17)).foregroundStyle(PassTheme.accent).frame(width: 22, height: 40).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(field.label).font(.system(size: 12)).foregroundStyle(.secondary)
                                    Text(field.concealed && !revealed.contains(String(index)) ? "••••••••••••" : field.value)
                                        .font(field.concealed ? .system(size: 14, design: .monospaced) : .system(size: 15))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                HStack(spacing: 4) {
                                    if field.concealed {
                                        Button { if store.canUseVisibleDetail(), !revealed.insert(String(index)).inserted { revealed.remove(String(index)) } } label: { Image(systemName: revealed.contains(String(index)) ? "eye.slash" : "eye") }
                                            .accessibilityLabel(revealed.contains(String(index)) ? "Hide \(field.label)" : "Reveal \(field.label)")
                                            .help(revealed.contains(String(index)) ? "Hide \(field.label)" : "Reveal \(field.label)")
                                    }
                                    Button { if store.canUseVisibleDetail() { ClipboardController.shared.copy(field.value); copied = String(index) } } label: { Image(systemName: copied == String(index) ? "checkmark" : "doc.on.doc") }
                                        .accessibilityLabel("Copy \(field.label)").help("Copy \(field.label)")
                                }.buttonStyle(PassIconStyle()).padding(.top, 7)
                            }.padding(18)
                            if index < detail.fields.count - 1 { Divider().overlay(PassTheme.border.opacity(0.4)).padding(.leading, 54) }
                        }
                    }.passSurface()
                }
                if detail.hasTOTP {
                    detailCard("Verification code", symbol: "clock") {
                        Button { store.copyTOTP() } label: { Label("Copy verification code", systemImage: "doc.on.doc") }
                            .buttonStyle(PassPillStyle()).disabled(store.busy || !store.canCopyTOTP)
                        if !store.canCopyTOTP { Text("Verification code access is limited for this account.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !detail.urls.isEmpty {
                    detailCard("Websites", symbol: "globe") {
                        ForEach(detail.urls, id: \.self) { value in
                            if let url = URLPolicy.webURL(value) {
                                Link(destination: url) {
                                    HStack(spacing: 8) { Text(value).lineLimit(2).multilineTextAlignment(.leading); Spacer(minLength: 8); Image(systemName: "arrow.up.right").font(.caption) }
                                        .font(.system(size: 14)).foregroundStyle(PassTheme.accent).padding(12)
                                        .background(PassTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                                }
                            } else { Text("Unsupported website address").foregroundStyle(.secondary) }
                        }
                    }
                }
                if !detail.note.isEmpty {
                    detailCard("Note", symbol: "note.text") { Text(detail.note).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                if detail.passkeyCount > 0 { Label("\(detail.passkeyCount) passkey(s) · use the official app for authentication", systemImage: "person.badge.key").font(.caption).foregroundStyle(.secondary) }
                if detail.offlineAttachmentsUnavailable { Label("Attachments are unavailable in the saved vault", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary) }
                else if detail.attachmentCount > 0 { Label("\(detail.attachmentCount) attachment(s) · use the official app to download", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary) }
                if let item = store.currentItem {
                    VStack(alignment: .leading, spacing: 16) {
                        if store.currentVault?.canUpdate != true { Label("Shared vault · read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
                        if let date = item.modifiedAt { metadataRow("Last modified", value: readableDate(date), symbol: "pencil") }
                        if let date = item.createdAt { metadataRow("Created", value: readableDate(date), symbol: "calendar") }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).passSurface()
                }
                Label("Copied values clear after 30 seconds", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 4)
            }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
        }.background(PassTheme.canvas).onDisappear { revealed = []; copied = nil }
    }
    private func detailCard<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(PassTheme.accent).frame(width: 22, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).passSurface()
    }
    private func metadataRow(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).foregroundStyle(PassTheme.accent).frame(width: 22, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(value).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search Pass"
        field.setAccessibilityLabel("Search Pass")
        field.delegate = context.coordinator
        context.coordinator.field = field
        context.coordinator.observe()
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }
    static func dismantleNSView(_ view: NSSearchField, coordinator: Coordinator) { coordinator.stopObserving() }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        weak var field: NSSearchField?
        var observer: NSObjectProtocol?
        init(text: Binding<String>) { self.text = text }
        func observe() {
            observer = NotificationCenter.default.addObserver(forName: .protonXFocusSearch, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let field = self?.field else { return }
                    field.window?.makeFirstResponder(field)
                }
            }
        }
        func controlTextDidChange(_ notification: Notification) { text.wrappedValue = field?.stringValue ?? "" }
        func stopObserving() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
    }
}
