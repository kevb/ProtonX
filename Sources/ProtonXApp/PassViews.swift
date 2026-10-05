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
        .onReceive(NotificationCenter.default.publisher(for: .protonXNewItem)) { _ in if store.phase == .open { showingCreate = true } }
        .onAppear {
            SystemIntegration.shared.openPass = { openWindow(id: "pass"); NSApp.activate(ignoringOtherApps: true) }
            SystemIntegration.shared.openMail = { openWindow(id: "mail"); NSApp.activate(ignoringOtherApps: true) }
            SystemIntegration.shared.lockSuite = { store.lock(); NotificationCenter.default.post(name: .protonXLock, object: nil) }
            SystemIntegration.shared.openSettings = { openSettings(); NSApp.activate(ignoringOtherApps: true) }
            SystemIntegration.shared.configure()
            if ProcessInfo.processInfo.arguments.contains("--demo") { store.enterDemo() }
        }
    }
    private var workspace: some View {
        NavigationSplitView {
            List {
                Section {
                    sidebarButton("All items", symbol: "square.grid.2x2", count: store.items.count, selected: store.selectedVault == nil && store.kind == nil && !store.showingTrash) {
                        store.selectedVault = nil; store.kind = nil; setTrash(false)
                    }
                    sidebarButton("Logins", symbol: "key", selected: store.kind == "login") { store.kind = "login"; store.selectedVault = nil; setTrash(false) }
                    sidebarButton("Notes", symbol: "note.text", selected: store.kind == "note") { store.kind = "note"; store.selectedVault = nil; setTrash(false) }
                }
                Section("Vaults") {
                    ForEach(store.vaults) { vault in
                        sidebarButton(vault.name, symbol: "folder", count: store.items.filter { $0.shareID == vault.id }.count, selected: store.selectedVault == vault.id) {
                            store.selectedVault = vault.id; store.kind = nil; setTrash(false)
                        }
                    }
                }
                Section {
                    sidebarButton("Trash", symbol: "trash", selected: store.showingTrash) { store.selectedVault = nil; store.kind = nil; setTrash(true) }
                }
            }
            .listStyle(.sidebar).navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 270)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if store.isDemo { Label("Demo · synthetic data", systemImage: "testtube.2").font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button { store.lock() } label: { Label("Lock", systemImage: "lock") }.help("Lock ProtonX (⌘L)")
                        Spacer()
                        Menu { Button("Settings…") { openSettings() }; Button("Sign Out…", role: .destructive) { confirmSignOut = true } } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).frame(width: 20).accessibilityLabel("Account actions")
                    }
                }.padding()
            }
        } content: {
            List(store.filteredItems, selection: $store.selectedItem) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.symbol).foregroundStyle(.purple).frame(width: 32, height: 32).background(.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).lineLimit(1)
                        Text(store.vaults.first { $0.id == item.shareID }?.name ?? "Vault").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4).tag(item.id)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
            .overlay { if store.filteredItems.isEmpty { ContentUnavailableView.search(text: store.query) } }
            .onChange(of: store.selectedItem) { _, _ in store.selectItem() }
            .onChange(of: store.filteredItems.map(\.id)) { _, ids in
                if let selected = store.selectedItem, !ids.contains(selected) { store.selectedItem = nil }
            }
        } detail: {
            if let item = store.currentItem {
                if let detail = store.detail {
                    ItemDetailView(detail: detail).id(item.id)
                        .toolbar {
                            ToolbarItemGroup {
                                Button { showingEdit = true } label: { Label("Edit", systemImage: "square.and.pencil") }.disabled(store.busy || !["login", "note"].contains(item.kind))
                                Button { confirmTrash = true } label: { Label(store.showingTrash ? "Restore" : "Trash", systemImage: store.showingTrash ? "arrow.uturn.backward" : "trash") }.disabled(store.busy)
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
                Button { showingCreate = true } label: { Label("New Item", systemImage: "plus") }.disabled(store.busy || store.vaults.isEmpty).accessibilityIdentifier("newItem")
            }
        }
    }
    private func setTrash(_ value: Bool) {
        guard value != store.showingTrash else { return }
        if store.isDemo { store.error = "Trash browsing is available with a connected Proton account."; return }
        store.showingTrash = value; store.selectedItem = nil; store.refresh()
    }
    private func sidebarButton(_ title: String, symbol: String, count: Int? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Label(title, systemImage: symbol); Spacer(); if let count { Text(String(count)).font(.caption).foregroundStyle(.secondary) } }
                .padding(.vertical, 3).padding(.horizontal, 4).background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
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
                Button(store.phase == .locked ? "Unlock Pass" : "Sign In to Proton") { store.phase == .locked ? store.unlock() : store.login() }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                if store.phase == .locked && !store.isDemo { Button("Sign In Again") { store.login() } }
                if store.phase == .welcome { Button("Try direct password sign-in (experimental)") { store.login(interactive: true) }.font(.caption) }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Image(systemName: store.currentItem?.symbol ?? "key").font(.title).foregroundStyle(.purple); Text(detail.title).font(.title2.weight(.semibold)) }
                ForEach(Array(detail.fields.enumerated()), id: \.offset) { index, field in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(field.label).font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top) {
                            Text(field.concealed && !revealed.contains(String(index)) ? "••••••••••••" : field.value)
                                .font(field.concealed ? .system(.body, design: .monospaced) : .body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            if field.concealed {
                                Button { if !revealed.insert(String(index)).inserted { revealed.remove(String(index)) } } label: { Image(systemName: revealed.contains(String(index)) ? "eye.slash" : "eye") }.accessibilityLabel(revealed.contains(String(index)) ? "Hide \(field.label)" : "Reveal \(field.label)")
                            }
                            Button { ClipboardController.shared.copy(field.value); copied = field.label } label: { Image(systemName: copied == field.label ? "checkmark" : "doc.on.doc") }.accessibilityLabel("Copy \(field.label)")
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
            }.padding(28).frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.onDisappear { revealed = []; copied = nil }
    }
}

struct ItemEditor: View {
    @EnvironmentObject var store: PassStore
    @Environment(\.dismiss) private var dismiss
    let editing: Bool
    @State private var draft = LoginDraft()
    @State private var isNote = false
    @State private var note = ""
    @State private var website = ""
    @State private var vaultID = ""
    @State private var localError: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editing ? "Edit item" : "New item").font(.title2.weight(.semibold))
            Form {
                if !editing { Picker("Type", selection: $isNote) { Text("Login").tag(false); Text("Secure note").tag(true) } }
                TextField("Title", text: $draft.title).accessibilityIdentifier("itemTitle")
                if !editing { Picker("Vault", selection: $vaultID) { ForEach(store.vaults) { Text($0.name).tag($0.id) } } }
                if !isNote {
                    TextField("Username", text: $draft.username)
                    TextField("Email", text: $draft.email)
                    SecureField("Password", text: $draft.password)
                    Button("Generate password") { do { draft.password = try PasswordGenerator.generate() } catch { localError = error.localizedDescription } }
                    if !editing { TextField("Website (https://…)", text: $website) }
                }
                if isNote || editing {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $note).frame(height: 120).border(.quaternary)
                }
            }.formStyle(.grouped)
            if let localError { Text(localError).foregroundStyle(.red).font(.callout) }
            HStack { Button("Cancel") { clear(); dismiss() }.keyboardShortcut(.cancelAction).disabled(saving && store.busy); Spacer(); Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy) }
        }.padding(24).frame(width: 500)
        .onAppear {
            vaultID = store.selectedVault ?? store.vaults.first?.id ?? ""
            if editing, let detail = store.detail {
                isNote = store.currentItem?.kind == "note"
                draft.title = detail.title; note = detail.note
                draft.username = detail.fields.first { $0.label == "Username" }?.value ?? ""
                draft.email = detail.fields.first { $0.label == "Email" }?.value ?? ""
                draft.password = detail.fields.first { $0.label == "Password" }?.value ?? ""
            }
        }
        .onChange(of: store.busy) { _, busy in
            guard saving && !busy else { return }
            saving = false
            if let error = store.error { localError = error } else { clear(); dismiss() }
        }
        .onDisappear(perform: clear)
    }
    private func save() {
        draft.urls = website.isEmpty ? [] : [website]
        do { try draft.validate() } catch { localError = error.localizedDescription; return }
        guard note.utf8.count + draft.password.utf8.count < 262144 else { localError = "Keep items below 256 KB."; return }
        saving = true; localError = nil
        if editing {
            var fields = ["title": draft.title, "note": note]
            if !isNote { fields["username"] = draft.username; fields["email"] = draft.email; fields["password"] = draft.password }
            store.updateCurrent(fields: fields)
        } else { store.create(draft: draft, note: isNote ? note : nil, vaultID: vaultID) }
    }
    private func clear() { draft = LoginDraft(); note = ""; website = "" }
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
