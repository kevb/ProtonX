import SwiftUI
import ProtonXCore

struct ItemEditor: View {
    @EnvironmentObject var store: PassStore
    @Environment(\.dismiss) private var dismiss
    let editing: Bool
    @State private var draft = NativeItemDraft()
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    private struct WebsiteInput: Identifiable { let id = UUID(); var value = "" }
    @State private var websites = [WebsiteInput()]
    @State private var originalWebsites: [String] = []
    @State private var totpSetup = ""
    @State private var removeTOTP = false
    @State private var existingTOTP = false
    @State private var unsupportedFields = 0
    @State private var item: PassItem?
    @State private var vaultID = ""
    @State private var localError: String?
    @State private var saving = false
    @State private var conflicted = false
    @State private var saveTask: Task<Void, Never>?
    @State private var originalContent: EditableContent?
    @FocusState private var focusedField: String?
    private var isLogin: Bool { draft.kind == "login" }
    // Memory-only comparison; opening an item must not create a new revision.
    private struct EditableContent: Equatable {
        let title: String, note: String, username: String, email: String, password: String
        let websites: [String]
        let totpSetup: String
        let removeTOTP: Bool
        let customFields: [CustomFieldDraft]
    }
    private var content: EditableContent {
        EditableContent(title: draft.title, note: draft.note, username: username, email: email,
                        password: password, websites: normalizedWebsites, totpSetup: totpSetup,
                        removeTOTP: removeTOTP, customFields: draft.customFields)
    }
    private var normalizedWebsites: [String] {
        websites.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var cannotSave: Bool {
        conflicted || saving || store.busy || store.mustRefreshBeforeWriting ||
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vaultID.isEmpty ||
        (editing && (originalContent == nil || originalContent == content))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button { clear(); dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(PassIconStyle()).keyboardShortcut(.cancelAction).disabled(saving)
                    .accessibilityLabel("Cancel editing").help("Cancel (Esc)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(editing ? "Edit \(isLogin ? "login" : "secure note")" : "Create item").font(.system(size: 16, weight: .semibold))
                    if editing, let vault = store.vaults.first(where: { $0.id == vaultID }) {
                        Text(vault.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(editing ? "Save Changes" : "Create \(isLogin ? "Login" : "Note")", action: save)
                    .buttonStyle(PassPillStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(cannotSave).accessibilityIdentifier("saveItem")
            }.padding(.horizontal, 24).padding(.vertical, 18).background(PassTheme.canvas)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !editing {
                        HStack(spacing: 16) {
                            Picker("Type", selection: $draft.kind) { Text("Login").tag("login"); Text("Secure note").tag("note") }
                            Spacer(minLength: 8)
                            Picker("Vault", selection: $vaultID) { ForEach(store.writableVaults) { Text($0.name).tag($0.id) } }
                        }.pickerStyle(.menu).font(.system(size: 13)).padding(.horizontal, 4)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Title").font(.system(size: 13)).foregroundStyle(.secondary)
                        TextField("Untitled", text: $draft.title).font(.system(size: 26, weight: .semibold))
                            .focused($focusedField, equals: "title").accessibilityLabel("Title").accessibilityIdentifier("itemTitle")
                    }.padding(20).passSurface().editorFocus(focusedField == "title")
                    if isLogin { loginFields; websiteFields }
                    noteField
                    customFields
                }.textFieldStyle(.plain).padding(24).disabled(saving)
            }.background(PassTheme.canvas)
            if let localError {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(localError).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    if store.mustRefreshBeforeWriting && !conflicted { Button("Refresh Vault") { store.refresh() }.disabled(store.busy) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(PassTheme.canvas)
            }
        }.frame(width: 640, height: 760).tint(PassTheme.accent)
        .onAppear(perform: populate)
        .onDisappear { saveTask?.cancel(); clear() }
        .onChange(of: draft.kind) { _, _ in totpSetup = ""; removeTOTP = false }
    }
    private var loginFields: some View {
        VStack(spacing: 0) {
            entryRow("Username", symbol: "person") {
                TextField("Enter username", text: $username).focused($focusedField, equals: "username").accessibilityLabel("Username")
            }
            Divider().padding(.leading, 54)
            entryRow("Email", symbol: "envelope") {
                TextField("Enter email", text: $email).focused($focusedField, equals: "email").accessibilityLabel("Email")
            }
            Divider().padding(.leading, 54)
            entryRow("Password", symbol: "key") {
                HStack(spacing: 12) {
                    SecureField("Enter password", text: $password).focused($focusedField, equals: "password").accessibilityLabel("Password")
                    Button { do { password = try PasswordGenerator.generate() } catch { localError = error.localizedDescription } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(PassIconStyle()).accessibilityLabel("Generate password").help("Generate password")
                }
            }
            Divider().padding(.leading, 54)
            entryRow("2FA secret key (TOTP)", symbol: "lock") {
                if existingTOTP {
                    Text("Existing setup is kept unless you replace or remove it.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Remove existing setup", isOn: $removeTOTP).font(.caption)
                }
                if store.canSetupTOTP(for: item) && !removeTOTP {
                    SecureField(existingTOTP ? "Replacement otpauth://totp/… URI" : "Add otpauth://totp/… setup URI", text: $totpSetup)
                        .focused($focusedField, equals: "totp").accessibilityLabel(existingTOTP ? "Replacement setup URI" : "Verification setup URI")
                    Text("Setup secrets stay concealed.").font(.caption).foregroundStyle(.secondary)
                } else if !removeTOTP {
                    Text("This account has reached its verification code limit.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.passSurface().editorFocus(["username", "email", "password", "totp"].contains(focusedField ?? ""))
    }
    private var websiteFields: some View {
        entryRow("Websites", symbol: "globe") {
            ForEach($websites) { $website in
                HStack(spacing: 10) {
                    TextField("https://example.com", text: $website.value)
                        .focused($focusedField, equals: "website:" + website.id.uuidString).accessibilityLabel("Website address")
                    Button { websites.removeAll { $0.id == website.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).frame(width: 28, height: 28)
                        .contentShape(Rectangle()).accessibilityLabel("Remove website").help("Remove website")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(PassTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(focusedField == "website:" + website.id.uuidString ? PassTheme.accent : PassTheme.border, lineWidth: 1).allowsHitTesting(false) }
            }
            Divider().padding(.vertical, 4)
            Button("Add website", systemImage: "plus") {
                let website = WebsiteInput()
                websites.append(website)
                focusedField = "website:" + website.id.uuidString
            }.buttonStyle(.plain).foregroundStyle(PassTheme.accent).padding(.vertical, 4)
        }.passSurface()
    }
    private var noteField: some View {
        entryRow(isLogin ? "Note" : "Secure note", symbol: "note.text") {
            TextEditor(text: $draft.note).font(.system(size: 15)).scrollContentBackground(.hidden)
                .frame(height: isLogin ? 76 : 260).focused($focusedField, equals: "note").accessibilityLabel("Notes")
                .overlay(alignment: .topLeading) {
                    if draft.note.isEmpty { Text(isLogin ? "Add a note…" : "Write your note…").font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false).accessibilityHidden(true) }
                }
        }.passSurface().editorFocus(focusedField == "note")
    }
    private var customFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($draft.customFields) { $field in
                if !field.removed {
                    entryRow("Custom field", symbol: field.concealed ? "lock" : "text.alignleft") {
                        HStack {
                            TextField("Field name", text: $field.name).accessibilityLabel("Field name")
                                .focused($focusedField, equals: "custom-name:" + field.id.uuidString)
                            Button {
                                if field.sourceIndex == nil { draft.customFields.removeAll { $0.id == field.id } }
                                else { field.removed = true }
                            } label: { Image(systemName: "minus") }.buttonStyle(PassIconStyle()).accessibilityLabel("Remove custom field")
                        }
                        if field.concealed {
                            SecureField("Value", text: $field.value).accessibilityLabel("Concealed custom field value").focused($focusedField, equals: "custom-value:" + field.id.uuidString)
                        } else { TextField("Value", text: $field.value).accessibilityLabel("Custom field value").focused($focusedField, equals: "custom-value:" + field.id.uuidString) }
                        Toggle("Conceal value", isOn: $field.concealed).font(.caption).padding(.top, 4)
                    }.passSurface().editorFocus(focusedField == "custom-name:" + field.id.uuidString || focusedField == "custom-value:" + field.id.uuidString).disabled(!store.customFieldsAllowed)
                }
            }
            if store.customFieldsAllowed { Button("Add custom field", systemImage: "plus") { draft.customFields.append(CustomFieldDraft()) }.buttonStyle(PassPillStyle()) }
            else { Text("Custom field changes require a supported Proton plan. Existing fields are preserved.").font(.caption).foregroundStyle(.secondary) }
            if unsupportedFields > 0 { Text("\(unsupportedFields) other custom field(s) will be preserved. Use the official app to edit those types.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func entryRow<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(PassTheme.accent).frame(width: 22, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
                content().font(.system(size: 16))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18)
    }
    private func populate() {
        vaultID = store.writableVaults.first(where: { $0.id == store.selectedVault })?.id ?? store.writableVaults.first?.id ?? ""
        if editing, let selected = store.currentItem, let detail = store.detail {
            item = selected; vaultID = selected.shareID; draft.kind = selected.kind
            draft.title = detail.title; draft.note = detail.note; draft.expectedRevision = detail.revision
            username = detail.fields.first { $0.label == "Username" }?.value ?? ""
            email = detail.fields.first { $0.label == "Email" }?.value ?? ""
            password = detail.fields.first { $0.label == "Password" }?.value ?? ""
            originalWebsites = detail.urls; websites = detail.urls.isEmpty ? [WebsiteInput()] : detail.urls.map { WebsiteInput(value: $0) }
            existingTOTP = detail.hasTOTP; draft.customFields = detail.editableCustomFields; unsupportedFields = detail.unsupportedCustomFieldCount
        }
        originalContent = content
        focusedField = "title"
    }
    private func save() {
        guard !cannotSave else { return }
        var input = draft
        if isLogin {
            input.username = username; input.email = email; input.password = password
            let urls = normalizedWebsites
            input.urls = !editing || urls != originalWebsites ? urls : nil
            input.totpURI = removeTOTP ? "" : (totpSetup.isEmpty ? nil : totpSetup)
        }
        do { _ = try input.encodedInput() } catch { localError = error.localizedDescription; return }
        saving = true; localError = nil
        saveTask = Task { @MainActor in
            do { try await store.save(input, item: item, vaultID: vaultID); clear(); dismiss() }
            catch {
                if !Task.isCancelled {
                    if case ProtonXError.helperDiagnostic(let diagnostic) = error, diagnostic.failure == .conflict {
                        conflicted = true
                        localError = diagnostic.message + " Close this editor, refresh and reopen the item to use its latest revision."
                    } else { localError = error.localizedDescription + " Refresh the vault before retrying if the connection was interrupted." }
                    saving = false
                }
            }
        }
    }
    private func clear() { draft = NativeItemDraft(); username = ""; email = ""; password = ""; websites = []; totpSetup = ""; originalWebsites = []; originalContent = nil }
}

private extension View {
    func editorFocus(_ focused: Bool) -> some View {
        overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(focused ? PassTheme.accent : .clear, lineWidth: 1.5).allowsHitTesting(false) }
    }
}
