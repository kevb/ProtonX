import SwiftUI
import ProtonXCore

/// A native text editor; Proton's core owns the quote, signatures and envelope.
struct MailComposer: View {
    @ObservedObject var store: NativeMailStore
    let initial: NativeMailDraft
    @ObservedObject var editor: MailEditorState
    @State private var confirmDiscard = false
    @State private var confirmSend = false
    @State private var confirmClosePending = false
    @FocusState private var focus: String?
    init(store: NativeMailStore, draft: NativeMailDraft, editor: MailEditorState) {
        self.store = store; initial = draft; self.editor = editor
    }
    private var current: NativeMailDraft { store.draft ?? initial }
    private var content: NativeMailComposeContent { editor.content }
    private var editable: Bool { current.state == .editing && !store.busy }
    private var valid: Bool { (try? content.validate(senders: current.senders, sending: true)) != nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.pencil").foregroundStyle(MailTheme.accent)
                Text(editor.subject.isEmpty ? "New message" : editor.subject).font(.headline).lineLimit(1)
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                if current.state == .editing {
                    Button("Save & Close") { store.saveDraft(content, close: true) }.disabled(!editable)
                } else {
                    Button("Close") { confirmClosePending = true }.disabled(store.busy)
                }
            }.padding(20).background(MailTheme.sidebar)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("From").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Picker("Sending address", selection: $editor.sender) {
                            ForEach(current.senders, id: \.self) { address in Text(address).tag(address) }
                        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        if editor.sender.lowercased().hasSuffix("@gmail.com") { Text("Connected Gmail").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 12)
                    Divider()
                    HStack {
                        recipientField("To", text: $editor.to, focus: "to")
                        Button(editor.expandedRecipients ? "Hide Cc/Bcc" : "Cc/Bcc") { editor.expandedRecipients.toggle() }.buttonStyle(.plain).foregroundStyle(MailTheme.accent)
                    }
                    Divider()
                    if editor.expandedRecipients {
                        recipientField("Cc", text: $editor.cc, focus: "cc"); Divider()
                        recipientField("Bcc", text: $editor.bcc, focus: "bcc"); Divider()
                    }
                    HStack {
                        Text("Subject").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        TextField("Subject", text: $editor.subject).textFieldStyle(.plain).focused($focus, equals: "subject")
                    }.padding(.vertical, 15)
                    Divider()
                    if current.warning != nil {
                        Label("The original receiving address is unavailable. This reply will use the From address shown above.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).padding(.vertical, 14)
                    }
                    TextEditor(text: $editor.text).font(.body).scrollContentBackground(.hidden)
                        .foregroundStyle(MailTheme.ink).padding(12).background(MailTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                        .environment(\.colorScheme, .light)
                        .frame(minHeight: 230).focused($focus, equals: "body").padding(.top, 16)
                        .accessibilityLabel("Message body")
                    if !current.quote.isEmpty {
                        DisclosureGroup("Signature & quoted message") {
                            Text(current.quote).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                        }.padding(.vertical, 14)
                    }
                    if current.attachments > 0 {
                        Label("\(current.attachments) existing attachment(s) retained by Proton", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                    }
                }.disabled(!editable).padding(.horizontal, 24)
            }.background(MailTheme.canvas)
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 10)
            }
            HStack(spacing: 14) {
                Button { confirmDiscard = true } label: { Image(systemName: "trash").accessibilityLabel("Discard draft") }.buttonStyle(.plain).disabled(!editable)
                Button("Save Draft") { store.saveDraft(content) }.buttonStyle(.plain).disabled(!editable)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.composeStatus ?? "Unsaved edits · plain text editor").font(.caption).foregroundStyle(.secondary)
                    if current.state == .unknown || current.state == .failed { Button("Check send status") { store.checkSendStatus() }.font(.caption).disabled(store.busy) }
                }
                Spacer()
                Button { confirmSend = true } label: { Label("Send", systemImage: "paperplane.fill") }
                    .buttonStyle(MailActionStyle(primary: true)).disabled(!editable || !valid).keyboardShortcut(.return, modifiers: [.command])
            }.padding(20).background(MailTheme.collection)
        }.frame(minWidth: 580, maxWidth: 850, minHeight: 600, maxHeight: .infinity)
        .onAppear { focus = editor.to.isEmpty ? "to" : "body" }
        .onChange(of: content) { _, _ in store.markDraftEdited() }
        .confirmationDialog("Close this composer?", isPresented: $confirmClosePending) {
            Button("Close & Check Sent") { store.closePendingDraft() }
        } message: { Text("Closing does not cancel delivery. Check Sent and Drafts before trying to send this message again.") }
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard) {
            Button("Discard Draft", role: .destructive) { store.discardDraft() }
        } message: { Text("Remove this draft from Proton. Your unsaved text will be lost.") }
        .confirmationDialog("Send from \(editor.sender)?", isPresented: $confirmSend) {
            Button("Send Message") { store.sendDraft(content) }
        } message: {
            Text("To: \(editor.to)\(editor.cc.isEmpty ? "" : "\nCc: " + editor.cc)\(editor.bcc.isEmpty ? "" : "\nBcc: " + editor.bcc)\(editor.subject.isEmpty ? "\nThis message has no subject." : "")")
        }
    }
    private func recipientField(_ title: String, text: Binding<String>, focus key: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            TextField("Email addresses, separated by commas", text: text).textFieldStyle(.plain).focused($focus, equals: key)
        }.padding(.vertical, 15)
    }
}
