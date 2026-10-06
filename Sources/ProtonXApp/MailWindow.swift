import SwiftUI
import ProtonXCore

struct MailWindow: View {
    @StateObject private var store: NativeMailStore
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var bridge = false
    @State private var confirmSignOut = false
    @FocusState private var focus: String?
    init(previewOnly: Bool = false) { _store = StateObject(wrappedValue: NativeMailStore(previewOnly: previewOnly)) }
    var body: some View {
        Group {
            if store.phase == .open { workspace }
            else { authentication }
        }
        .background(PassTheme.collection)
        .preferredColorScheme(designAppearance)
        .frame(minWidth: 860, minHeight: 580)
        .safeAreaInset(edge: .bottom) {
            if let error = store.error {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { store.error = nil }
                }.padding(12).background(.orange.opacity(0.12))
            }
        }
        .sheet(isPresented: Binding(get: { store.draft != nil }, set: { _ in })) {
            if let draft = store.draft { MailComposer(store: store, draft: draft) }
        }
        .sheet(isPresented: $bridge) { BridgeMailWindow().frame(width: 1050, height: 740) }
        .confirmationDialog("Sign out of ProtonX Mail?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { clearCredentials(); store.signOut() }
        } message: { Text("End this app’s Mail session and remove its local account data. Your messages remain with Proton.") }
        .onReceive(NotificationCenter.default.publisher(for: .protonXLock)) { _ in clearCredentials(); store.lock(); bridge = false }
        .onAppear { focus = "username" }
        .onDisappear { clearCredentials(); store.lock() }
        .onChange(of: store.phase) { _, phase in
            if phase != .welcome { password = "" }
            code = ""
            focus = phase == .totp || phase == .mailboxPassword ? "challenge" : "username"
        }
    }
    private var designAppearance: ColorScheme? {
        #if PROTONX_DESIGN_LIGHT
        if store.previewOnly { return .light }
        #endif
        return nil
    }
    private var authentication: some View {
        VStack(spacing: 22) {
            Image(systemName: store.phase == .locked ? "lock.shield" : "envelope.badge.shield.half.filled")
                .font(.system(size: 42, weight: .light)).foregroundStyle(PassTheme.accent).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title).font(.system(size: 28, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if store.phase == .welcome || store.phase == .signingIn {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Proton email or username", text: $username).textContentType(.username).focused($focus, equals: "username")
                    Divider()
                    SecureField("Password", text: $password).textContentType(.password).focused($focus, equals: "password")
                        .onSubmit(signIn)
                }.padding(20).passSurface().textFieldStyle(.plain).disabled(store.busy || store.previewOnly)
                Button(action: signIn) { HStack { if store.busy { ProgressView().controlSize(.small) }; Text(store.busy ? "Signing in…" : "Sign In") }.frame(maxWidth: .infinity) }
                    .buttonStyle(PassPillStyle(primary: true)).disabled(store.busy || username.isEmpty || password.isEmpty || store.previewOnly)
                if !store.previewOnly { Button("Use a saved Mail session") { clearCredentials(); store.unlock() }.buttonStyle(.plain).foregroundStyle(PassTheme.accent) }
            } else if store.phase == .locked {
                Button { store.unlock() } label: { HStack { if store.busy { ProgressView().controlSize(.small) }; Text("Unlock Mail") }.frame(maxWidth: .infinity) }
                    .buttonStyle(PassPillStyle(primary: true)).disabled(store.busy)
            } else if store.phase == .totp || store.phase == .mailboxPassword {
                Group {
                    if store.phase == .mailboxPassword { SecureField("Mailbox password", text: $code) }
                    else { TextField("Verification code", text: $code).textContentType(.oneTimeCode) }
                }.textFieldStyle(.plain).padding(20).passSurface().focused($focus, equals: "challenge").onSubmit(submitChallenge)
                Button { submitChallenge() } label: { HStack { if store.busy { ProgressView().controlSize(.small) }; Text("Continue") }.frame(maxWidth: .infinity) }
                    .buttonStyle(PassPillStyle(primary: true)).disabled(store.busy || code.isEmpty)
            } else if store.phase == .securityKey {
                Text("This account requires a security key. Native security-key sign-in is not supported in this build yet.").font(.callout).foregroundStyle(.secondary)
            }
            if store.busy || store.phase == .totp || store.phase == .mailboxPassword || store.phase == .securityKey {
                Button("Cancel") { clearCredentials(); store.cancelSignIn() }
            }
            Divider()
            Button("Explore demo inbox") { clearCredentials(); store.enterDemo() }.buttonStyle(.plain).foregroundStyle(PassTheme.accent)
            if !store.previewOnly { Button("Connect using Bridge…") { clearCredentials(); bridge = true }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary) }
        }.frame(maxWidth: 380).padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var title: String {
        switch store.phase {
        case .locked: "Mail is locked"
        case .totp: "Verify your sign-in"
        case .mailboxPassword: "Unlock your mailbox"
        case .securityKey: "Security key required"
        default: "Your Mail, at home on Mac"
        }
    }
    private var subtitle: String {
        switch store.phase {
        case .locked: "Use Touch ID or your Mac password to reopen your saved Mail session."
        case .totp: "Enter the code from your authenticator."
        case .mailboxPassword: "Your account uses a second password to unlock its encryption keys."
        default: "Sign in with your Proton account, in a native Mac window."
        }
    }
    private var workspace: some View {
        NavigationSplitView {
            List(selection: $store.selectedFolder) {
                Section {
                    Button { store.compose() } label: { Label("New message", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                        .buttonStyle(PassPillStyle(primary: true)).disabled(store.busy || store.draft != nil)
                }
                Section("Mail") {
                    ForEach(store.folders) { folder in
                        HStack(spacing: 12) {
                            Image(systemName: folder.name.localizedCaseInsensitiveContains("inbox") ? "tray" : "folder").foregroundStyle(PassTheme.accent)
                            Text(folder.name)
                            Spacer()
                            if folder.count > 0 { Text(folder.count.formatted()).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6).tag(folder.id)
                    }
                }
            }.disabled(store.busy).scrollContentBackground(.hidden).background(PassTheme.sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 290)
                .onChange(of: store.selectedFolder) { _, _ in store.changeFolder() }
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(PassTheme.accent) }
                        if store.demo { Label("Synthetic preview", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
                        else { Text(store.email).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Button("Lock Mail", systemImage: "lock") { store.lock() }
                        if !store.demo { Button("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right") { confirmSignOut = true }.disabled(store.busy) }
                    }.buttonStyle(.plain).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(PassTheme.sidebar)
                }
        } content: {
            List(selection: $store.selectedItem) {
                ForEach(store.visibleMessages) { message in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(message.unread ? (store.selectedItem == message.id ? Color.white : PassTheme.accent) : .clear).frame(width: 7, height: 7).padding(.top, 7)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.senderName.isEmpty ? message.sender : message.senderName).font(.system(size: 13, weight: message.unread ? .semibold : .regular)).lineLimit(1)
                            Text(message.subject.isEmpty ? "(No subject)" : message.subject).font(.callout).lineLimit(2)
                            if message.date > 0 { Text(Date(timeIntervalSince1970: Double(message.date)), style: .date).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        if message.attachments > 0 { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Has attachments") }
                    }.padding(.vertical, 9).tag(message.id)
                }
            }.frame(minWidth: 280).scrollContentBackground(.hidden).background(PassTheme.collection)
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 460)
                .searchable(text: $store.query, prompt: "Search loaded mail")
                .onChange(of: store.query) { _, _ in store.reconcileSelection() }
                .onChange(of: store.selectedItem) { _, _ in store.select() }
                .overlay { if store.visibleMessages.isEmpty { ContentUnavailableView(store.loading ? "Syncing your inbox" : store.query.isEmpty ? "No messages here" : "No matching messages", systemImage: "tray", description: Text(store.loading ? "Your mailbox is loading." : "Refresh or choose another folder.")) } }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        if store.loading { ProgressView().controlSize(.small); Text("Syncing…") }
                        else { Text("\(store.messages.count) messages loaded") }
                        Spacer()
                        if !store.demo && !store.messages.isEmpty { Button("Load more") { store.refresh(more: true) }.disabled(store.busy || store.messages.count >= 1000) }
                    }.font(.caption).foregroundStyle(.secondary).padding(12)
                }
        } detail: {
            if let message = store.selectedMessage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(message.subject.isEmpty ? "(No subject)" : message.subject).font(.system(size: 25, weight: .semibold))
                        HStack(spacing: 10) {
                            if message.isDraft == true && message.isScheduled != true {
                                Button("Edit draft", systemImage: "pencil") { store.compose("open") }.buttonStyle(PassPillStyle())
                            } else if message.canReply != false {
                                Button("Reply", systemImage: "arrowshape.turn.up.left") { store.compose("reply") }.buttonStyle(PassPillStyle())
                                Button("Reply all", systemImage: "arrowshape.turn.up.left.2") { store.compose("reply_all") }.buttonStyle(PassPillStyle())
                            }
                        }.disabled(store.busy || store.body == nil || store.draft != nil)
                        VStack(alignment: .leading, spacing: 9) {
                            Label(message.sender, systemImage: "person")
                            Text("To: \(message.recipient)").foregroundStyle(.secondary)
                            if message.date > 0 { Text(Date(timeIntervalSince1970: Double(message.date)), format: .dateTime).font(.caption).foregroundStyle(.secondary) }
                        }.font(.callout).padding(18).frame(maxWidth: .infinity, alignment: .leading).passSurface()
                        if let body = store.body { Text(body).textSelection(.enabled).font(.body).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading) }
                        else if store.error != nil { Button("Retry loading message") { store.select() } }
                        else { ProgressView("Decrypting message…").frame(maxWidth: .infinity) }
                        if message.attachments > 0 { Label("\(message.attachments) attachment(s) · open with the official client for now", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary) }
                    }.padding(30).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }.background(PassTheme.canvas)
            } else { ContentUnavailableView("Choose a message", systemImage: "envelope", description: Text("Read your mail in its own Mac window.")).frame(maxWidth: .infinity, maxHeight: .infinity).background(PassTheme.canvas) }
        }
        .navigationTitle("ProtonX Mail")
        .toolbar {
            ToolbarItem { if store.busy { ProgressView().controlSize(.small) } }
            ToolbarItem { Button { store.compose() } label: { Label("New message", systemImage: "square.and.pencil") }.disabled(store.busy || store.draft != nil).keyboardShortcut("n", modifiers: [.command]) }
            ToolbarItem { Button { store.refresh() } label: { Label("Refresh Mail", systemImage: "arrow.clockwise") }.disabled(store.busy || store.demo).keyboardShortcut("r", modifiers: [.command, .shift]) }
        }
    }
    private func signIn() { let supplied = password; password = ""; store.signIn(username: username, password: supplied) }
    private func submitChallenge() { let supplied = code; code = ""; store.submitChallenge(supplied) }
    private func clearCredentials() { password = ""; code = "" }
}
