import SwiftUI
import ProtonXCore

struct PassWindow: View {
    @EnvironmentObject var store: PassStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showingCreate = false
    @State private var showingEdit = false
    @State private var confirmTrash = false
    @State private var confirmSignOut = false
    var body: some View {
        Group {
            if store.phase == .open { workspace } else { WelcomeView() }
        }
        .frame(minWidth: 820, minHeight: 540)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = store.error {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(error).font(.callout); Spacer(); Button("Dismiss") { store.error = nil } }
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
        .onAppear {
            SystemIntegration.shared.openPass = { openWindow(id: "pass"); NSApp.activate(ignoringOtherApps: true) }
            SystemIntegration.shared.openMail = { openWindow(id: "mail"); NSApp.activate(ignoringOtherApps: true) }
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
                    sidebarRow("All items", symbol: "square.grid.2x2", count: store.items.count).tag("all")
                    sidebarRow("Logins", symbol: "key", count: store.items.filter { $0.kind == "login" }.count).tag("kind:login")
                    sidebarRow("Notes", symbol: "note.text", count: store.items.filter { $0.kind == "note" }.count).tag("kind:note")
                }
                Section("Types") {
                    ForEach([("credit_card", "Cards", "creditcard"), ("identity", "Identities", "person.text.rectangle"), ("wifi", "Wi-Fi", "wifi"), ("alias", "Aliases", "at"), ("ssh_key", "SSH keys", "terminal"), ("custom", "Other items", "doc.text")], id: \.0) { type in
                        if store.items.contains(where: { $0.kind == type.0 }) { sidebarRow(type.1, symbol: type.2).tag("kind:" + type.0) }
                    }
                }
                Section("Vaults") {
                    ForEach(store.vaults) { vault in
                        sidebarRow(vault.name, symbol: vault.canUpdate == true ? "folder" : "folder.badge.person.crop", count: store.items.filter { $0.shareID == vault.id }.count).tag("vault:" + vault.id)
                    }
                }
                Section { sidebarRow("Trash", symbol: "trash", count: store.trashedItems.count).tag("trash") }
            }
            .listStyle(.sidebar).navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 270)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if store.isDemo { Label("Demo · synthetic data", systemImage: "testtube.2").font(.caption).foregroundStyle(.orange) }
                    if store.mustRefreshBeforeWriting { Label("Refresh needed before changes", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
                    if let synced = store.lastSyncedAt {
                        Text("Updated \(synced, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button { store.lock() } label: { Label("Lock", systemImage: "lock") }.help("Lock ProtonX (⌘L)")
                        Spacer()
                        Menu { Button("Settings…") { openSettings() }; Button("Sign Out…", role: .destructive) { confirmSignOut = true } } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).frame(width: 44, height: 28).accessibilityLabel("Account actions")
                    }
                }.padding()
            }
        } content: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(collectionTitle).font(.headline)
                        Text("\(store.filteredItems.count) item\(store.filteredItems.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Picker("Sort items", selection: $store.sort) { ForEach(ItemSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Sort items")
                }.padding(14)
                Divider()
                List(store.filteredItems, selection: $store.selectedItem) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.symbol).foregroundStyle(.purple).frame(width: 32, height: 32).background(.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).lineLimit(1)
                        Text(store.vaults.first { $0.id == item.shareID }?.name ?? "Vault").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4).tag(item.id)
            }
                .overlay {
                    if store.filteredItems.isEmpty {
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
            }.navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
        } detail: {
            if let item = store.currentItem {
                if let detail = store.detail {
                    ItemDetailView(detail: detail).id(item.id + ":" + String(detail.revision ?? 0))
                        .toolbar {
                            ToolbarItemGroup {
                                Button { showingEdit = true } label: { Label("Edit", systemImage: "square.and.pencil") }.disabled(store.busy || !store.canEdit)
                                Button { confirmTrash = true } label: { Label(store.showingTrash ? "Restore" : "Trash", systemImage: store.showingTrash ? "arrow.uturn.backward" : "trash") }.disabled(store.busy || !store.canTrash)
                            }
                        }
                } else if store.error != nil {
                    ContentUnavailableView { Label("Could not open item", systemImage: "exclamationmark.triangle") }
                        description: { Text("Your vault is unchanged. You can retry when your connection is available.") }
                        actions: { Button("Retry") { store.selectItem() } }
                } else { ProgressView("Opening item…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else { ContentUnavailableView("Your vault, at home on Mac", systemImage: "key", description: Text("Choose an item to view its details.")) }
        }
        .navigationTitle("ProtonX Pass")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NativeSearchField(text: $store.query).frame(width: 220)
                if store.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(store.busy || store.isDemo)
                Button { showingCreate = true } label: { Label("Create Item", systemImage: "plus") }.disabled(!store.canCreate).accessibilityIdentifier("newItem")
            }
        }
    }
    private var collectionTitle: String {
        if store.showingTrash { return "Trash" }
        if let vault = store.vaults.first(where: { $0.id == store.selectedVault }) { return vault.name }
        if let kind = store.kind { return PassItem(itemID: "", shareID: "", title: "", kind: kind).typeName + "s" }
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
    private func sidebarRow(_ title: String, symbol: String, count: Int? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count { Text(String(count)).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 3).contentShape(Rectangle())
    }

}

struct WelcomeView: View {
    @EnvironmentObject var store: PassStore
    @State private var answer = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: store.phase == .locked ? "lock.shield" : "key.horizontal").font(.system(size: 48, weight: .light)).foregroundStyle(.purple)
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
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                if store.phase == .locked && !store.isDemo { Button("Sign In Again") { store.login() } }
                if store.phase == .welcome && !store.previewOnly { Button("Try direct password sign-in (experimental)") { store.login(interactive: true) }.font(.caption) }
                if store.phase == .welcome { Button("Explore with demo data") { store.enterDemo() }.accessibilityIdentifier("enterDemo") }
            }
            Text("Independent open source client · GPL-3.0-or-later\nNot affiliated with Proton AG").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(48).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.challenge) { _, _ in answer = ""; focused = true }
        .onChange(of: store.phase) { _, _ in answer = "" }
    }
    private func submit() { let value = answer; answer = ""; store.answerCredential(value) }
}

struct ItemDetailView: View {
    @EnvironmentObject var store: PassStore
    let detail: ItemDetail
    @State private var revealed = Set<String>()
    @State private var copied: String?
    private func readableDate(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.timeZone = TimeZone(secondsFromGMT: 0)
        return parser.date(from: value.hasSuffix("Z") ? value : value + "Z")?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Image(systemName: store.currentItem?.symbol ?? "key").font(.title).foregroundStyle(.purple); VStack(alignment: .leading, spacing: 5) { Text(detail.title).font(.title2.weight(.semibold)).textSelection(.enabled); Text(store.currentItem?.typeName ?? "Item").font(.caption).foregroundStyle(.secondary) } }
                ForEach(Array(detail.fields.enumerated()), id: \.offset) { index, field in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(field.label).font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top) {
                            Text(field.concealed && !revealed.contains(String(index)) ? "••••••••••••" : field.value)
                                .font(field.concealed ? .system(.body, design: .monospaced) : .body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            if field.concealed {
                                Button { if !revealed.insert(String(index)).inserted { revealed.remove(String(index)) } } label: { Image(systemName: revealed.contains(String(index)) ? "eye.slash" : "eye") }.accessibilityLabel(revealed.contains(String(index)) ? "Hide \(field.label)" : "Reveal \(field.label)")
                            }
                            Button { ClipboardController.shared.copy(field.value); copied = String(index) } label: { Image(systemName: copied == String(index) ? "checkmark" : "doc.on.doc") }.accessibilityLabel("Copy \(field.label)")
                        }.buttonStyle(.borderless).padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if detail.hasTOTP {
                    Button { store.copyTOTP() } label: { Label("Copy verification code", systemImage: "clock.badge.checkmark") }.disabled(store.busy || !store.canCopyTOTP)
                    if !store.canCopyTOTP { Text("Verification code access is limited for this account.").font(.caption).foregroundStyle(.secondary) }
                }
                if !detail.urls.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Websites").font(.caption).foregroundStyle(.secondary)
                        ForEach(detail.urls, id: \.self) { value in
                            if let url = URLPolicy.webURL(value) { Link(value, destination: url).lineLimit(2) }
                            else { Text("Unsupported website address").foregroundStyle(.secondary) }
                        }
                    }
                }
                if !detail.note.isEmpty {
                    VStack(alignment: .leading, spacing: 10) { Text("Notes").font(.caption).foregroundStyle(.secondary); Text(detail.note).textSelection(.enabled) }
                }
                if detail.passkeyCount > 0 { Label("\(detail.passkeyCount) passkey(s) · use the official app for authentication", systemImage: "person.badge.key").font(.caption).foregroundStyle(.secondary) }
                if detail.attachmentCount > 0 { Label("\(detail.attachmentCount) attachment(s) · use the official app to download", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary) }
                Text("Copied values clear after 30 seconds. Locking clears the item from this window.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let item = store.currentItem {
                    VStack(alignment: .leading, spacing: 8) {
                        if store.currentVault?.canUpdate != true { Label("Shared vault · read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
                        if let date = item.modifiedAt { LabeledContent("Last changed", value: readableDate(date)) }
                        if let date = item.createdAt { LabeledContent("Created", value: readableDate(date)) }
                    }.font(.caption).foregroundStyle(.secondary).padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(28).frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.onDisappear { revealed = []; copied = nil }
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
