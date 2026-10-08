// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import ProtonXCore

struct ContactsWindow: View {
    @ObservedObject var store: NativeMailStore
    let isActive: Bool
    let openMail: () -> Void
    let writeEmail: ([String]) -> Void
    @FocusState private var searchFocused: Bool
    @State private var groupsOnly = false
    private var entries: [ContactEntry] { store.visibleContacts.filter { !groupsOnly || $0.kind == .group } }
    var body: some View {
        Group {
            if store.phase == .open { addressBook }
            else {
                VStack(spacing: 20) {
                    Image(systemName: "person.crop.rectangle.stack").font(.system(size: 54, weight: .light)).foregroundStyle(MailTheme.accent)
                    Text("Your Proton contacts").font(.largeTitle.weight(.semibold))
                    Text("Contacts uses your Mail account. Open or unlock Mail to see your address book here.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Continue in Mail", action: openMail).buttonStyle(MailActionStyle(primary: true))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(MailTheme.canvas)
            .task(id: isActive && store.phase == .open) {
                guard isActive, store.phase == .open else { return }
                store.loadContacts()
                // Re-read the SDK's local event-synced index while visible. No extra API polling.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard isActive, store.phase == .open else { return }
                    if !store.demo && !store.contactDetailBusy { store.loadContacts(refreshDetails: false) }
                }
            }
            .onChange(of: groupsOnly) { _, _ in if !entries.contains(where: { $0.id == store.selectedContact }) { store.selectContact(nil) } }
            .onChange(of: store.contactsQuery) { _, _ in
                if store.currentContact == nil { store.selectContact(nil) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .protonXFocusContactsSearch)) { _ in if isActive { searchFocused = true } }
    }
    private var addressBook: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Contacts").font(.title2.weight(.semibold)); Spacer(); if store.contactsBusy { ProgressView().controlSize(.small) } }
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search names or email", text: $store.contactsQuery).textFieldStyle(.plain).focused($searchFocused) }
                        .padding(10).background(MailTheme.canvas, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("contactsSearch")
                    Picker("Contacts filter", selection: $groupsOnly) { Text("All contacts").tag(false); Text("Groups").tag(true) }.pickerStyle(.segmented).labelsHidden()
                }.padding(20)
                Divider()
                if let error = store.contactsError {
                    VStack(alignment: .leading, spacing: 8) { Text(error).font(.callout).foregroundStyle(.orange); Button("Retry") { store.loadContacts() }.disabled(store.contactsBusy) }.padding()
                }
                if entries.isEmpty {
                    ContentUnavailableView(store.contactsLoaded ? "No contacts" : "Loading contacts", systemImage: "person.crop.circle", description: Text(store.contactsLoaded ? "Try another search or add contacts in Proton Mail." : "Opening Mail’s synced address book…"))
                        .frame(maxHeight: .infinity)
                } else {
                    List(selection: Binding(get: { store.selectedContact }, set: { store.selectContact($0) })) {
                        ForEach(entries) { entry in
                            HStack(spacing: 12) {
                                avatar(entry, size: 38)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.displayName).font(.body.weight(.medium)).lineLimit(1)
                                    Text(entry.kind == .group ? "\(entry.emails.count) addresses" : (entry.emails.first?.email ?? "No email address"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(.vertical, 6).tag(entry.id)
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden)
                }
                Divider()
                HStack { Text("\(entries.count) \(groupsOnly ? (entries.count == 1 ? "group" : "groups") : (entries.count == 1 ? "entry" : "entries"))"); Spacer(); Text(store.demo ? "Demo" : "Mail address book") }.font(.caption).foregroundStyle(.secondary).padding(14)
            }.frame(minWidth: 270, idealWidth: 320, maxWidth: 430).background(MailTheme.sidebar)
            ScrollView {
                if let entry = store.currentContact, entries.contains(where: { $0.id == entry.id }) {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 18) {
                            avatar(entry, size: 72)
                            VStack(alignment: .leading, spacing: 5) { Text(entry.displayName).font(.system(size: 28, weight: .semibold)); Text(entry.kind == .group ? "Contact group" : "Proton contact").foregroundStyle(.secondary) }
                        }
                        if store.draft != nil { Text("A Mail draft is open. Use its Contacts picker to add recipients.").font(.callout).foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(entry.emails.enumerated()), id: \.offset) { _, address in
                                HStack(spacing: 14) {
                                    Image(systemName: "envelope").foregroundStyle(MailTheme.accent)
                                    VStack(alignment: .leading, spacing: 4) { if entry.kind == .group { Text(address.name).font(.caption).foregroundStyle(.secondary) }; Text(address.email).textSelection(.enabled) }
                                    Spacer()
                                    Button { writeEmail([address.email]) } label: { Image(systemName: "square.and.pencil") }
                                        .buttonStyle(.plain).help("Write to " + address.email).accessibilityLabel("Write email to " + address.email)
                                        .disabled(!canWrite([address.email]))
                                }.padding(18)
                                Divider()
                            }
                        }.background(MailTheme.collection, in: RoundedRectangle(cornerRadius: 16))
                        if entry.kind == .group {
                            Button("Write to group") { writeEmail(Array(Set(entry.emails.map(\.email))).sorted()) }
                                .buttonStyle(MailActionStyle(primary: true)).disabled(!canWrite(entry.emails.map(\.email)))
                            Text("Group addresses will be added to To and visible to recipients. Use Bcc in the composer for private group addressing.").font(.caption).foregroundStyle(.secondary)
                        }
                        if store.contactDetailBusy { ProgressView("Opening contact details…") }
                        if let error = store.contactDetailError {
                            Text(error).foregroundStyle(.orange); Button("Retry details") { store.selectContact(entry.id) }
                        }
                        if let detail = store.contactDetail, detail.localID == entry.localID, detail.fields.contains(where: { $0.label != "Email" }) {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(Array(detail.fields.filter { $0.label != "Email" }.enumerated()), id: \.offset) { _, field in
                                    VStack(alignment: .leading, spacing: 6) { Text(field.label).font(.caption).foregroundStyle(.secondary); Text(field.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                }
                            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(MailTheme.collection, in: RoundedRectangle(cornerRadius: 16))
                        }
                        Text("Browsing only · contact editing and import/export are coming later.").font(.caption).foregroundStyle(.secondary)
                    }.padding(32).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView("Choose a contact", systemImage: "person.crop.rectangle", description: Text("Contact details and email addresses appear here.")).frame(maxWidth: .infinity, minHeight: 450)
                }
            }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func canWrite(_ emails: [String]) -> Bool { !store.busy && store.draft == nil && !emails.isEmpty && Set(emails).count <= 100 && emails.allSatisfy(ContactRecipients.valid) }
    private func avatar(_ entry: ContactEntry, size: CGFloat) -> some View {
        Group {
            if entry.kind == .group { Image(systemName: "person.2").font(.system(size: size * 0.38)) }
            else { Text(String(entry.displayName.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .medium)) }
        }.foregroundStyle(MailTheme.accent).frame(width: size, height: size).background(MailTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

struct ContactRecipientPicker: View {
    @ObservedObject var store: NativeMailStore
    let choose: ([String]) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Add from Contacts").font(.headline); Spacer(); Button("Done") { dismiss() } }
            TextField("Search contacts or groups", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("recipientContactSearch")
            if store.contactsBusy { ProgressView() }
            if let error = error ?? store.contactsError { Text(error).font(.caption).foregroundStyle(.orange) }
            if store.contactsLoaded && store.contacts.filter({ $0.matches(query) }).isEmpty { Text("No matching contacts").foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.contacts.filter { $0.matches(query) }) { entry in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.displayName).font(.headline)
                            ForEach(Array(entry.emails.enumerated()), id: \.offset) { _, address in
                                Button { add([address.email]) } label: {
                                    Text(address.email).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.borderless).disabled(!ContactRecipients.valid(address.email))
                            }
                            if entry.kind == .group && !entry.emails.isEmpty {
                                Button("Add group addresses") { add(entry.emails.map(\.email)) }.disabled(!entry.emails.allSatisfy { ContactRecipients.valid($0.email) })
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(MailTheme.collection, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.frame(minHeight: 260)
            Text("Addresses already in To, Cc or Bcc won’t be added twice.").font(.caption).foregroundStyle(.secondary)
            Button("Reload contacts") { store.loadContacts() }.disabled(store.contactsBusy)
        }.padding(20).frame(width: 420, height: 440).task { store.loadContacts() }
    }
    private func add(_ addresses: [String]) {
        if choose(addresses) { dismiss() }
        else { error = "Check the existing recipient addresses and the 100-recipient limit, then try again." }
    }
}
extension Notification.Name { static let protonXFocusContactsSearch = Notification.Name("protonXFocusContactsSearch") }
