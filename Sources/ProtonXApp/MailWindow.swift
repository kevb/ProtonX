import SwiftUI
import ProtonXCore

struct MailWindow: View {
    @StateObject private var store: NativeMailStore
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var bridge = false
    @State private var confirmSignOut = false
    @State private var readerExpanded = false
    @FocusState private var focus: String?
    init(previewOnly: Bool = false) { _store = StateObject(wrappedValue: NativeMailStore(previewOnly: previewOnly)) }
    var body: some View {
        Group {
            if store.phase == .open { workspace }
            else { authentication }
        }
        .background(MailTheme.collection)
        .preferredColorScheme(designAppearance)
        .focusedSceneValue(\.protonXProduct, .mail)
        .focusedSceneValue(\.protonXCanCreate, store.phase == .open && !store.busy && store.draft == nil)
        .focusedSceneValue(\.protonXCanRefresh, store.phase == .open && !store.busy && !store.demo)
        .frame(minWidth: 860, minHeight: 580)
        .toolbar { ToolbarItem(placement: .navigation) { SuiteProductSwitcher(current: "mail") } }
        .safeAreaInset(edge: .bottom) {
            if let error = store.error {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    if store.mustRefreshBeforeActions { Button("Refresh Mail") { store.refresh() }.disabled(store.busy) }
                    Button("Dismiss") { store.error = nil }
                }.padding(12).background(.orange.opacity(0.12))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.undoToken != nil {
                HStack {
                    Text(store.notice ?? "Mail change queued").font(.callout)
                    Spacer()
                    Button("Undo move") { store.undoMessageAction() }.disabled(!store.canUndoAction).accessibilityIdentifier("undoMailMove")
                }.padding(12).background(MailTheme.accent.opacity(0.12))
            }
        }
        .sheet(isPresented: Binding(get: { store.draft != nil }, set: { _ in })) {
            if let draft = store.draft { MailComposer(store: store, draft: draft) }
        }
        .sheet(isPresented: $bridge) { BridgeMailWindow().frame(width: 1050, height: 740) }
        .confirmationDialog("Sign out of ProtonX Mail?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { clearCredentials(); store.signOut() }
        } message: { Text("End this app’s Mail session and remove its local account data. Your messages remain with Proton.") }
        .onReceive(NotificationCenter.default.publisher(for: .protonXNewMessage)) { _ in store.compose() }
        .onReceive(NotificationCenter.default.publisher(for: .protonXRefreshMail)) { _ in store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .protonXFocusMailSearch)) { _ in focus = "search" }
        .onReceive(NotificationCenter.default.publisher(for: .protonXLock)) { _ in clearCredentials(); store.lock(); bridge = false }
        .productWindow(.mail)
        .onAppear { focus = "username" }
        .onDisappear { clearCredentials(); store.lock() }
        .onChange(of: store.phase) { _, phase in
            if phase != .welcome { password = "" }
            if phase != .open { readerExpanded = false }
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
    private var folderTitle: String { store.folders.first { $0.id == store.selectedFolder }?.name ?? "Mail" }
    private var workspace: some View {
        Group {
            if readerExpanded { messageReader }
            else { mailboxLayout }
        }
        .onChange(of: store.selectedItem) { _, selected in if selected == nil { readerExpanded = false } }
        .onChange(of: store.conversationView) { _, _ in store.reconcileSelection(); store.select() }
        .navigationTitle("ProtonX Mail")
        .toolbar {
            ToolbarItem { if store.busy { ProgressView().controlSize(.small) } }
            ToolbarItem {
                Picker("Mail view", selection: $store.conversationView) {
                    Text("Conversations").tag(true)
                    Text("Messages").tag(false)
                }.pickerStyle(.menu).accessibilityIdentifier("mailConversationView")
            }
            ToolbarItem { Button { store.compose() } label: { Label("New message", systemImage: "square.and.pencil") }.disabled(store.busy || store.draft != nil) }
            ToolbarItem { Button { store.refresh() } label: { Label("Refresh Mail", systemImage: "arrow.clockwise") }.disabled(store.busy || store.demo) }
        }
    }
    private var mailboxLayout: some View {
        NavigationSplitView {
            List(selection: $store.selectedFolder) {
                ForEach(store.folders) { folder in
                    HStack(spacing: 12) {
                        Image(systemName: MailTheme.symbol(for: folder.name)).font(.system(size: 17)).frame(width: 22)
                        Text(folder.name).font(.system(size: 14, weight: store.selectedFolder == folder.id ? .semibold : .regular))
                        Spacer()
                        if folder.count > 0 {
                            Text(folder.count.formatted()).font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(MailTheme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.padding(.vertical, 8).tag(folder.id)
                }
            }.disabled(store.busy).listStyle(.sidebar).scrollContentBackground(.hidden).background(MailTheme.sidebar)
                .navigationSplitViewColumnWidth(min: 190, ideal: 225, max: 290)
                .onChange(of: store.selectedFolder) { _, _ in store.changeFolder() }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 10) {
                            Image(systemName: "envelope.fill").foregroundStyle(MailTheme.accent).font(.title3)
                            Text("ProtonX Mail").font(.system(size: 16, weight: .semibold))
                        }
                        Button { store.compose() } label: { Text("New message").frame(maxWidth: .infinity) }
                            .buttonStyle(MailActionStyle(primary: true)).disabled(store.busy || store.draft != nil)
                    }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 16).background(MailTheme.sidebar)
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(MailTheme.accent) }
                        Divider()
                        HStack(spacing: 10) {
                            MailSenderAvatar(name: store.email)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.demo ? "Demo account" : "Mail account").font(.system(size: 12, weight: .medium))
                                Text(store.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        if store.demo { Label("Synthetic preview", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("Lock", systemImage: "lock") { store.lock() }
                            Spacer()
                            if !store.demo { Button("Sign Out…") { confirmSignOut = true }.disabled(store.busy) }
                        }.font(.callout)
                    }.buttonStyle(.plain).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(MailTheme.sidebar)
                }
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search loaded messages", text: $store.query).textFieldStyle(.plain).font(.system(size: 14))
                        .focused($focus, equals: "search").accessibilityIdentifier("mailSearch")
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear mail search")
                    }
                }.padding(12).background(MailTheme.canvas, in: RoundedRectangle(cornerRadius: 10)).padding(16)
                HStack(alignment: .firstTextBaseline) {
                    Text(folderTitle).font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Text("\(store.visibleConversations.count) loaded").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 18).padding(.bottom, 16)
                Divider()
                List(selection: $store.selectedItem) {
                    ForEach(store.visibleConversations) { conversation in
                        let message = conversation.representative
                        HStack(alignment: .top, spacing: 11) {
                            MailSenderAvatar(name: message.senderName.isEmpty ? message.sender : message.senderName)
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(message.senderName.isEmpty ? message.sender : message.senderName)
                                        .font(.system(size: 13, weight: conversation.unread ? .semibold : .regular)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if message.date > 0 {
                                        Text(Date(timeIntervalSince1970: Double(message.date)), format: .dateTime.month(.abbreviated).day())
                                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                                    }
                                }
                                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                                    .font(.system(size: 13, weight: conversation.unread ? .medium : .regular)).lineLimit(2)
                                HStack(spacing: 6) {
                                    if conversation.unread { Circle().fill(MailTheme.accent).frame(width: 6, height: 6); Text("Unread") }
                                    if message.attachments > 0 { Image(systemName: "paperclip"); Text("\(message.attachments)") }
                                    if conversation.messages.count > 1 { Text("\(conversation.messages.count) messages").help("Messages loaded in this folder; open the conversation for other messages") }
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 11).tag(conversation.selectionID(store.selectedItem))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .overlay {
                        if store.visibleConversations.isEmpty {
                            if store.isLoadingList {
                                ProgressView("Loading your mailbox…").frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if store.initialListFailed {
                                ContentUnavailableView {
                                    Label("Could not load this folder", systemImage: "exclamationmark.circle")
                                } description: { Text("Try refreshing when your connection is available.") }
                                actions: { Button("Retry") { store.refresh() } }
                            } else {
                                ContentUnavailableView(store.query.isEmpty ? "No messages here" : "No matching messages", systemImage: "tray", description: Text("Refresh or choose another folder."))
                            }
                        }
                    }
                Divider()
                HStack {
                    if store.loading { ProgressView().controlSize(.small); Text("Syncing…") }
                    else if store.showingSavedContent { Label(store.cacheRefreshFailed ? "Saved content · refresh unavailable" : "Saved on this Mac", systemImage: "internaldrive") }
                    else { Text("\(store.messages.count) messages loaded") }
                    Spacer()
                    if !store.demo && !store.messages.isEmpty { Button("Load more") { store.refresh(more: true) }.disabled(store.busy || store.messages.count >= 1000) }
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }.frame(minWidth: 300).background(MailTheme.collection)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 460)
                .onChange(of: store.query) { _, _ in store.reconcileSelection() }
                .onChange(of: store.selectedItem) { _, _ in store.select() }
        } detail: { messageReader }
    }
    private func mailAction(_ action: NativeMailAction) -> some View {
        Button { store.actOnMessage(action) } label: { Image(systemName: action.symbol) }
            .buttonStyle(MailActionStyle())
            .help(action.title).accessibilityLabel(action.title)
            .accessibilityIdentifier("mailAction." + action.rawValue)
            .disabled(!store.canPerform(action))
    }
    private func organizationActions(_ message: NativeMailMessage) -> some View {
        HStack(spacing: 8) {
            mailAction(store.messageActions.contains(.read) ? .read : .unread).keyboardShortcut("u", modifiers: [.command, .shift])
            mailAction(.archive).keyboardShortcut("e", modifiers: [.command])
            if store.messageActions.contains(.inbox) { mailAction(.inbox) }
            mailAction(.trash).keyboardShortcut(.delete, modifiers: [.command])
        }.fixedSize()
    }
    private func replyActions(_ message: NativeMailMessage) -> some View {
        HStack(spacing: 8) {
            if message.isDraft == true && message.isScheduled != true {
                Button("Edit draft", systemImage: "pencil") { store.compose("open") }.buttonStyle(MailActionStyle())
            } else if message.canReply != false {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { store.compose("reply") }.buttonStyle(MailActionStyle())
                Button("Reply all", systemImage: "arrowshape.turn.up.left.2") { store.compose("reply_all") }.buttonStyle(MailActionStyle())
            }
        }.fixedSize().disabled(store.busy || store.threadLoading || store.body == nil || store.draft != nil)
    }
    @ViewBuilder private var messageReader: some View {
        if let message = store.selectedAnchor {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        Text(message.subject.isEmpty ? "(No subject)" : message.subject).font(.system(size: 25, weight: .semibold))
                        Spacer(minLength: 12)
                        Button { readerExpanded.toggle() } label: {
                            Image(systemName: readerExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(readerExpanded ? "Show mailbox" : "Expand message")
                            .accessibilityLabel(readerExpanded ? "Show mailbox" : "Expand message")
                    }
                    if store.threadLoading { ProgressView("Loading conversation…").controlSize(.small) }
                    if let issue = store.threadError {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.circle")
                            Text(issue).font(.callout)
                            Spacer()
                            Button("Retry") { store.select(preferred: store.expandedThreadItem, preservingContent: true) }
                            Button("Messages view") { store.conversationView = false }
                        }.padding(14).background(MailTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let thread = store.thread {
                        Text(thread.messages.count == 1 ? "Conversation · 1 message" : "Conversation · \(thread.messages.count) messages").font(.callout).foregroundStyle(.secondary)
                        ForEach(thread.messages) { member in
                            if store.expandedThreadItem == member.id { messageCard(member, collapsible: true) }
                            else { collapsedMessage(member) }
                        }
                    } else { messageCard(message, collapsible: false) }
                }.padding(26).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
            }.background(MailTheme.canvas)
        } else {
            ContentUnavailableView("Choose a message", systemImage: "envelope", description: Text("Read your mail in its own Mac window."))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(MailTheme.canvas)
        }
    }
    private func messageCard(_ message: NativeMailMessage, collapsible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("From").foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                        Text(message.senderName.isEmpty ? message.sender : message.senderName).fontWeight(.medium)
                        Spacer(minLength: 0)
                        if collapsible { Button { store.expandThreadMessage(message.id) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).help("Collapse message").accessibilityLabel("Collapse message") }
                    }
                    if !message.senderName.isEmpty { Text(message.sender).font(.caption).foregroundStyle(MailTheme.accent).padding(.leading, 50) }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("To").foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                        Text(message.recipient).foregroundStyle(.secondary)
                    }
                    if message.date > 0 { Text(Date(timeIntervalSince1970: Double(message.date)), format: .dateTime).font(.caption).foregroundStyle(.secondary).padding(.leading, 50) }
                }.font(.system(size: 13)).textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { organizationActions(message); Spacer(minLength: 8); replyActions(message) }
                    VStack(alignment: .leading, spacing: 12) { organizationActions(message); replyActions(message) }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if let body = store.body { MailMessageContent(text: body, sanitizedHTML: store.sanitizedHTML).id(message.id) }
            else if store.error != nil { Button("Retry loading message") { store.select(preferred: message.id) }.padding(28).frame(maxWidth: .infinity) }
            else { ProgressView("Decrypting message…").padding(28).frame(maxWidth: .infinity) }
            if message.attachments > 0 {
                Divider()
                Label("\(message.attachments) attachment(s) · open with the official client for now", systemImage: "paperclip")
                    .font(.caption).foregroundStyle(.secondary).padding(18)
            }
        }.background(MailTheme.canvas).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(MailTheme.border, lineWidth: 1).allowsHitTesting(false) }
    }
    private func collapsedMessage(_ message: NativeMailMessage) -> some View {
        Button { store.expandThreadMessage(message.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                MailSenderAvatar(name: message.senderName.isEmpty ? message.sender : message.senderName)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(message.senderName.isEmpty ? message.sender : message.senderName).fontWeight(message.unread ? .semibold : .medium)
                        Spacer()
                        if message.unread { Circle().fill(MailTheme.accent).frame(width: 6, height: 6) }
                        if message.attachments > 0 { Image(systemName: "paperclip"); Text("\(message.attachments)") }
                    }
                    Text(message.subject.isEmpty ? "(No subject)" : message.subject).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        Text("To \(message.recipient)").lineLimit(1)
                        Spacer()
                        if message.date > 0 { Text(Date(timeIntervalSince1970: Double(message.date)), format: .dateTime.month(.abbreviated).day().hour().minute()) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").foregroundStyle(.secondary)
            }.font(.callout).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(MailTheme.collection, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(MailTheme.border, lineWidth: 1) }
        }.buttonStyle(.plain).disabled(store.threadLoading)
            .accessibilityLabel("Open message from " + (message.senderName.isEmpty ? message.sender : message.senderName))
            .accessibilityIdentifier("mailThreadMessage.\(message.id)")
    }
    private func signIn() { let supplied = password; password = ""; store.signIn(username: username, password: supplied) }
    private func submitChallenge() { let supplied = code; code = ""; store.submitChallenge(supplied) }
    private func clearCredentials() { password = ""; code = "" }
}
