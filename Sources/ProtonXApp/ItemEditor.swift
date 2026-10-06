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
    @FocusState private var titleFocused: Bool
    private var isLogin: Bool { draft.kind == "login" }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PassItemBadge(symbol: isLogin ? "key" : "note.text", kind: draft.kind, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(editing ? "Edit \(isLogin ? "login" : "secure note")" : "Create item").font(.title2.weight(.semibold))
                    Text(editing ? "Keep your details up to date" : "A safe place for the details you need").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(PassTheme.canvas)
            Divider()
            Form {
                Section("Details") {
                    if !editing { Picker("Type", selection: $draft.kind) { Text("Login").tag("login"); Text("Secure note").tag("note") } }
                    TextField("Title", text: $draft.title).focused($titleFocused).accessibilityIdentifier("itemTitle")
                    if !editing { Picker("Vault", selection: $vaultID) { ForEach(store.writableVaults) { Text($0.name).tag($0.id) } } }
                }
                if isLogin {
                    Section("Sign-in details") {
                        TextField("Username", text: $username)
                        TextField("Email", text: $email)
                        SecureField("Password", text: $password)
                        Button("Generate password") { do { password = try PasswordGenerator.generate() } catch { localError = error.localizedDescription } }
                    }
                    Section("Websites") {
                        ForEach($websites) { $website in
                            HStack {
                                TextField("https://example.com", text: $website.value).labelsHidden().accessibilityLabel("Website address")
                                Button { websites.removeAll { $0.id == website.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove website")
                            }
                        }
                        Button("Add website", systemImage: "plus.circle") { websites.append(WebsiteInput()) }
                    }
                    Section("Verification code") {
                        if existingTOTP {
                            Text("Existing setup is kept unless you replace or remove it.").font(.caption).foregroundStyle(.secondary)
                            Toggle("Remove existing setup", isOn: $removeTOTP)
                        }
                        if store.canSetupTOTP(for: item) && !removeTOTP {
                            SecureField(existingTOTP ? "Replacement setup URI" : "otpauth://totp/… setup URI", text: $totpSetup)
                            Text("Paste a TOTP setup URI. The secret stays concealed.").font(.caption).foregroundStyle(.secondary)
                        } else if !removeTOTP {
                            Text("This account has reached its verification code limit.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                customFields
                Section("Notes") {
                    TextEditor(text: $draft.note).frame(minHeight: 90).accessibilityLabel("Notes")
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).background(PassTheme.collection).disabled(saving)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    if store.mustRefreshBeforeWriting && !conflicted { Button("Refresh Vault") { store.refresh() }.disabled(store.busy) }
                }
                HStack {
                    Button("Cancel") { clear(); dismiss() }.buttonStyle(PassPillStyle()).keyboardShortcut(.cancelAction).disabled(saving)
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button(editing ? "Save Changes" : "Create \(isLogin ? "Login" : "Note")", action: save)
                        .buttonStyle(PassPillStyle(primary: true))
                        .keyboardShortcut(.defaultAction).disabled(conflicted || saving || store.busy || store.mustRefreshBeforeWriting || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vaultID.isEmpty)
                }
            }.padding(20).background(PassTheme.canvas)
        }.frame(width: 580, height: 690).tint(PassTheme.accent)
        .onAppear(perform: populate)
        .onDisappear { saveTask?.cancel(); clear() }
        .onChange(of: draft.kind) { _, _ in totpSetup = ""; removeTOTP = false }
    }
    private var customFields: some View {
        Section("Custom fields") {
            ForEach($draft.customFields) { $field in
                if !field.removed {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Field name", text: $field.name).labelsHidden()
                            Button {
                                if field.sourceIndex == nil { draft.customFields.removeAll { $0.id == field.id } }
                                else { field.removed = true }
                            } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove custom field").disabled(!store.customFieldsAllowed)
                        }
                        if field.concealed { SecureField("Value", text: $field.value) } else { TextField("Value", text: $field.value) }
                        Toggle("Conceal value", isOn: $field.concealed).font(.caption)
                    }.disabled(!store.customFieldsAllowed)
                }
            }
            if store.customFieldsAllowed { Button("Add custom field", systemImage: "plus.circle") { draft.customFields.append(CustomFieldDraft()) } }
            else { Text("Custom field changes require a supported Proton plan. Existing fields are preserved.").font(.caption).foregroundStyle(.secondary) }
            if unsupportedFields > 0 { Text("\(unsupportedFields) other custom field(s) will be preserved. Use the official app to edit those types.").font(.caption).foregroundStyle(.secondary) }
        }
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
        titleFocused = true
    }
    private func save() {
        var input = draft
        if isLogin {
            input.username = username; input.email = email; input.password = password
            let urls = websites.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
    private func clear() { draft = NativeItemDraft(); username = ""; email = ""; password = ""; websites = []; totpSetup = ""; originalWebsites = [] }
}
