import SwiftUI
import LocalAuthentication
import UniformTypeIdentifiers
import ProtonXCore

@MainActor
final class MailStore: ObservableObject {
    @Published var config: MailConfiguration?
    @Published var mailboxes: [String] = []
    @Published var mailbox = "INBOX"
    @Published var messages: [MailMessage] = []
    @Published var selectedID: UInt64?
    @Published var selected: MailMessage?
    @Published var query = ""
    @Published var busy = false
    @Published var error: String?
    @Published var locked = false
    @Published var demo = false
    @Published var sent = false
    private var epoch = SessionEpoch()
    private var selectionEpoch = SessionEpoch()
    private var task: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var auth: LAContext?
    private let service = BridgeMailService()
    private let keychain = KeychainStore(service: "org.kevb.ProtonX.Mail")
    private var demoMessages: [MailMessage] = []
    init() { locked = UserDefaults.standard.bool(forKey: "mailConnected") }
    func connect(_ newConfig: MailConfiguration) {
        run { [self] in
            try newConfig.validate()
            let folders = try await service.mailboxes(newConfig)
            let initial = try await service.list(newConfig, mailbox: "INBOX")
            try Task.checkCancellation()
            try keychain.save(JSONEncoder().encode(newConfig), account: "bridge")
            UserDefaults.standard.set(true, forKey: "mailConnected")
            config = newConfig; mailboxes = folders; messages = initial; locked = false; demo = false
        }
    }
    func unlock() {
        let context = LAContext(); auth = context
        run { [self] in
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock ProtonX Mail on this Mac") else { throw ProtonXError.cancelled }
            try Task.checkCancellation()
            guard let data = try keychain.load(account: "bridge") else { locked = false; return }
            let saved = try JSONDecoder().decode(MailConfiguration.self, from: data)
            let folders = try await service.mailboxes(saved)
            let initial = try await service.list(saved, mailbox: mailbox)
            try Task.checkCancellation()
            config = saved; mailboxes = folders; messages = initial; locked = false
        }
    }
    func refresh() {
        guard let config else { return }
        run { [self] in
            let next = try await service.list(config, mailbox: mailbox)
            try Task.checkCancellation(); messages = next
        }
    }
    func select() {
        selected = nil; selectionEpoch.invalidate(); selectionTask?.cancel()
        guard let id = selectedID else { return }
        if demo { selected = demoMessages.first { $0.uid == id }; return }
        guard let config else { return }
        let captured = epoch.value, selection = selectionEpoch.value, folder = mailbox
        selectionTask = Task {
            do {
                let message = try await service.message(config, mailbox: folder, uid: id)
                try Task.checkCancellation()
                if epoch.accepts(captured) && selectionEpoch.accepts(selection) { selected = message }
            } catch { if !Task.isCancelled && epoch.accepts(captured) { self.error = error.localizedDescription } }
        }
    }
    func send(_ draft: MailDraft) {
        guard let config, !demo else { error = "Demo messages cannot be sent."; return }
        sent = false
        run { [self] in try await service.send(draft, config: config); try Task.checkCancellation(); sent = true }
    }
    func lock() {
        epoch.invalidate(); selectionEpoch.invalidate(); task?.cancel(); selectionTask?.cancel(); auth?.invalidate(); service.cancelAll()
        config = nil; messages = []; selected = nil; selectedID = nil; query = ""; demoMessages = []; demo = false; busy = false; error = nil
        locked = UserDefaults.standard.bool(forKey: "mailConnected")
    }
    func disconnect() {
        lock()
        do { try keychain.delete(account: "bridge"); UserDefaults.standard.set(false, forKey: "mailConnected"); locked = false }
        catch { self.error = error.localizedDescription }
    }
    func enterDemo() {
        lock(); demo = true; locked = false; mailbox = "INBOX"; mailboxes = ["INBOX"]
        demoMessages = [
            MailMessage(uid: 1, subject: "Welcome to ProtonX", sender: "ProtonX <hello@example.com>", recipient: "alex@example.com", date: "Demo message", body: "A native inbox, with a shared menu-bar icon and Mac keyboard shortcuts.\n\nThis is synthetic data. No Proton account has been accessed.\n\nMail uses Proton Bridge for encryption and authentication. HTML and remote images are never loaded in this version."),
            MailMessage(uid: 2, subject: "Your weekend plans", sender: "Sam <sam@example.com>", recipient: "alex@example.com", date: "Demo message", body: "Coffee on Saturday?\n\nThis is another synthetic example.")]
        messages = demoMessages; selectedID = 1; select()
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        let captured = epoch.value
        task = Task {
            do { try await action() }
            catch { if !Task.isCancelled && epoch.accepts(captured) { self.error = error.localizedDescription } }
            if epoch.accepts(captured) { busy = false }
        }
    }
}

struct MailWindow: View {
    @StateObject private var store = MailStore()
    @State private var compose = false
    @State private var confirmDisconnect = false
    var body: some View {
        Group {
            if store.config != nil || store.demo { inbox }
            else if store.locked {
                VStack(spacing: 20) { Image(systemName: "lock.shield").font(.largeTitle); Text("Mail is locked").font(.title); Button("Unlock Mail") { store.unlock() }.buttonStyle(.borderedProminent).disabled(store.busy); if store.busy { ProgressView() }; Button("Disconnect Bridge…") { confirmDisconnect = true } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { BridgeSetupView(store: store) }
        }.frame(minWidth: 820, minHeight: 540)
        .safeAreaInset(edge: .bottom) {
            if let error = store.error { HStack { Text(error).font(.callout); Spacer(); Button("Dismiss") { store.error = nil } }.padding(12).background(.orange.opacity(0.12)) }
        }
        .sheet(isPresented: $compose) { ComposeView(store: store) }
        .confirmationDialog("Disconnect Proton Bridge?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { store.disconnect() }
        } message: { Text("Remove this app’s saved Bridge credentials from Keychain. Your Proton mailbox stays on the server.") }
        .onReceive(NotificationCenter.default.publisher(for: .protonXLock)) { _ in store.lock(); compose = false }
    }
    private var inbox: some View {
        NavigationSplitView {
            List(store.mailboxes, id: \.self, selection: $store.mailbox) { folder in Label(folder == "INBOX" ? "Inbox" : folder, systemImage: folder == "INBOX" ? "tray" : "folder").tag(folder) }
                .navigationSplitViewColumnWidth(min: 170, ideal: 190)
                .onChange(of: store.mailbox) { _, _ in store.selectedID = nil; store.selected = nil; store.refresh() }
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.demo { Text("Demo · synthetic data").font(.caption).foregroundStyle(.orange) }
                        Button("Lock Mail", systemImage: "lock") { store.lock() }
                        Button("Disconnect…") { confirmDisconnect = true }
                    }.padding()
                }
        } content: {
            List(store.messages.filter { store.query.isEmpty || $0.subject.localizedStandardContains(store.query) || $0.sender.localizedStandardContains(store.query) }, selection: $store.selectedID) { message in
                VStack(alignment: .leading, spacing: 5) {
                    Text(message.subject).font(.headline).lineLimit(2)
                    Text(message.sender).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 6).tag(message.uid)
            }.navigationSplitViewColumnWidth(min: 250, ideal: 320).searchable(text: $store.query, prompt: "Search loaded messages")
                .onChange(of: store.selectedID) { _, _ in store.select() }
                .safeAreaInset(edge: .bottom) { Text("Newest 25 messages · refresh to sync").font(.caption).foregroundStyle(.secondary).padding(10) }
        } detail: {
            if let message = store.selected {
                ScrollView { VStack(alignment: .leading, spacing: 20) {
                    Text(message.subject).font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 6) { Text("From: " + message.sender); Text("To: " + message.recipient); Text(message.date).foregroundStyle(.secondary) }.font(.callout).textSelection(.enabled)
                    Divider(); Text(message.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if message.attachmentCount > 0 { Text("\(message.attachmentCount) attachment(s). Use the official client to download.").font(.caption).foregroundStyle(.secondary) }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading) }
            } else { ContentUnavailableView("Choose a message", systemImage: "envelope", description: Text("Read your mail without loading remote images.")) }
        }.navigationTitle("ProtonX Mail")
        .toolbar {
            ToolbarItemGroup {
                if store.busy { ProgressView().controlSize(.small) }
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(store.busy || store.demo)
                Button { compose = true } label: { Label("Compose", systemImage: "square.and.pencil") }.disabled(store.demo || store.busy)
            }
        }
    }
}

struct BridgeSetupView: View {
    @ObservedObject var store: MailStore
    @State private var config = MailConfiguration()
    @State private var importing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Connect Proton Bridge", systemImage: "envelope").font(.title2.weight(.semibold))
            Text("Start Proton Bridge and sign in there, then copy the mail-client credentials below. Bridge handles your account login and encryption. A Bridge-eligible Proton plan is required.").foregroundStyle(.secondary)
            Form {
                TextField("Email", text: $config.username)
                SecureField("Bridge password", text: $config.password)
                TextField("IMAP port", value: $config.imapPort, format: .number.grouping(.never))
                TextField("SMTP port", value: $config.smtpPort, format: .number.grouping(.never))
                Toggle("Use direct TLS (SSL) instead of STARTTLS", isOn: $config.directTLS)
                Button(config.certificatePEM.isEmpty ? "Import Bridge TLS certificate…" : "Certificate imported · replace…") { importing = true }
            }.formStyle(.grouped)
            HStack { Button("Explore demo inbox") { store.enterDemo() }; Spacer(); if store.busy { ProgressView() }; Button("Connect") { store.connect(config) }.buttonStyle(.borderedProminent).disabled(store.busy || config.certificatePEM.isEmpty || config.password.isEmpty) }
            Text("Only 127.0.0.1 is supported. TLS certificate and hostname verification are required. Credentials are saved in this Mac’s Keychain after a successful connection.").font(.caption).foregroundStyle(.secondary)
        }.padding(32).frame(maxWidth: 580).frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count < 65536, let text = String(data: data, encoding: .utf8), text.contains("BEGIN CERTIFICATE"), !text.contains("PRIVATE KEY") else { throw ProtonXError.invalidInput("Select Bridge’s public PEM certificate, without a private key.") }
                config.certificatePEM = text
            } catch { store.error = error.localizedDescription }
        }.onDisappear { config = MailConfiguration() }
    }
}

struct ComposeView: View {
    @ObservedObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MailDraft()
    @State private var confirmSend = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New message").font(.title2.weight(.semibold))
            TextField("To (one email address)", text: $draft.to)
            TextField("Subject", text: $draft.subject)
            TextEditor(text: $draft.body).frame(minHeight: 240)
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack { Button("Cancel") { draft = MailDraft(); dismiss() }.disabled(store.busy); Spacer(); if store.busy { ProgressView() }; Button("Send…") { confirmSend = true }.disabled(store.busy || !MailDraft.validAddress(draft.to)) }
        }.padding(24).frame(width: 600).textFieldStyle(.roundedBorder)
        .confirmationDialog("Send this message to \(draft.to)?", isPresented: $confirmSend) { Button("Send Message") { store.send(draft) } }
        .onChange(of: store.sent) { _, sent in if sent { draft = MailDraft(); dismiss() } }
        .onDisappear { draft = MailDraft() }
    }
}
