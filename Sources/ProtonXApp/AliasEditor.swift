// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import ProtonXCore

/// Shared presentation only. All alias operations belong to the Pass session.
struct AliasEditor: View {
    @ObservedObject var store: PassStore
    let close: () -> Void
    let viewInPass: (CreatedPassAlias, String) -> Void
    @State private var title = ""
    @State private var note = ""
    @State private var prefix = "alias"
    @State private var customPrefix = false
    @State private var vaultID = ""
    @State private var suffixIndex = 0
    @State private var mailboxID: Int64 = 0
    @State private var options: PassAliasOptions?
    @State private var loading = false
    @State private var saving = false
    @State private var attempted = false
    @State private var result: CreatedPassAlias?
    @State private var error: String?
    @State private var retry = 0
    @State private var copied = false
    @State private var closing = false
    @State private var saveTask: Task<Void, Never>?
    @State private var copyTask: Task<Void, Never>?
    @FocusState private var titleFocused: Bool
    private var draft: PassAliasDraft? {
        guard let options, options.suffixes.indices.contains(suffixIndex), let mailbox = options.mailboxes.first(where: { $0.id == mailboxID }) else { return nil }
        return PassAliasDraft(title: title.trimmingCharacters(in: .whitespacesAndNewlines), note: note, prefix: prefix, suffix: options.suffixes[suffixIndex], mailbox: mailbox)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("New email alias", systemImage: "at.badge.plus").font(.headline)
                Spacer()
                Button(action: dismissSheet) { Image(systemName: "xmark") }.buttonStyle(PassIconStyle()).accessibilityLabel("Close alias sheet").keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if store.phase != .open {
                VStack(spacing: 0) {
                    Text("Unlock Pass to create a hide-my-email alias. Your Mail stays where you left it.")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 20)
                    WelcomeView().environmentObject(store)
                    if let failure = store.error { Text(failure).font(.callout).foregroundStyle(.red).padding() }
                }
            } else if let result {
                success(result)
            } else {
                form
            }
        }
        .frame(width: 560, height: store.phase == .open ? 650 : 720).background(PassTheme.canvas).tint(PassTheme.accent)
        .interactiveDismissDisabled(saving)
        .onAppear { chooseVault() }
        .onChange(of: store.busy) { _, busy in
            if !busy, store.phase == .open, vaultID.isEmpty { chooseVault() }
        }
        .onChange(of: store.phase) { _, phase in
            options = nil; result = nil; note = ""; title = ""; prefix = "alias"; customPrefix = false; error = nil; attempted = false; copied = false
            if phase == .open { chooseVault() }
        }
        .task(id: "\(store.phase == .open):\(vaultID):\(retry)") { await loadOptions() }
        .onDisappear { saveTask?.cancel(); copyTask?.cancel(); options = nil; result = nil; title = ""; note = ""; prefix = "alias" }
    }
    private var form: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: "theatermasks").font(.system(size: 28)).foregroundStyle(PassTheme.accent)
                            .frame(width: 58, height: 58).background(PassTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Keep your real address private").font(.title3.weight(.semibold))
                            Text("Use an alias when signing up. Messages are forwarded to your chosen mailbox.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Alias title").font(.caption).foregroundStyle(.secondary)
                        TextField("e.g. Shopping, newsletters, a website", text: $title).font(.title2.weight(.medium)).focused($titleFocused).accessibilityIdentifier("aliasTitle")
                            .onChange(of: title) { _, value in if !customPrefix { prefix = PassAliasDraft.suggestedPrefix(value) } }
                    }.padding(18).passSurface()
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Your alias", systemImage: "at").font(.caption).foregroundStyle(.secondary)
                        if loading { ProgressView("Getting alias options…").controlSize(.small) }
                        else { Text(draft?.email ?? "Alias preview unavailable").font(.system(size: 16, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("aliasPreview") }
                        if let options, options.suffixes.count > 1 {
                            Picker("Domain", selection: $suffixIndex) { ForEach(options.suffixes.indices, id: \.self) { index in Text(options.suffixes[index].suffix).tag(index) } }
                        }
                        DisclosureGroup("Customize prefix") {
                            TextField("Alias prefix", text: Binding(get: { prefix }, set: { prefix = $0; customPrefix = true }))
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("aliasPrefix").padding(.top, 8)
                            Text("Up to 40 lowercase letters, numbers, dots, hyphens or underscores.").font(.caption).foregroundStyle(.secondary)
                            if !PassAliasDraft.validPrefix(prefix) { Text("Use a valid prefix without leading, trailing or repeated dots.").font(.caption).foregroundStyle(.red) }
                        }.font(.callout)
                        Divider()
                        Label("Forwards to", systemImage: "arrowshape.turn.up.right").font(.caption).foregroundStyle(.secondary)
                        if let options {
                            if options.mailboxes.count == 1 { Text(options.mailboxes[0].email).font(.callout).textSelection(.enabled) }
                            else { Picker("Forwarding mailbox", selection: $mailboxID) { ForEach(options.mailboxes) { mailbox in Text(mailbox.email).tag(mailbox.id) } }.labelsHidden() }
                        } else { Text("Provided by your Pass account").font(.callout).foregroundStyle(.secondary) }
                    }.padding(18).passSurface()
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Note · optional").font(.caption).foregroundStyle(.secondary)
                        TextField("What will you use this alias for?", text: $note, axis: .vertical).lineLimit(2...4).accessibilityIdentifier("aliasNote")
                    }.padding(18).passSurface()
                    Picker("Save in Pass", selection: Binding(get: { vaultID }, set: { options = nil; error = nil; vaultID = $0 })) { ForEach(store.writableVaults) { Text($0.name).tag($0.id) } }.font(.callout)
                    if store.isDemo { Label("Demo only · no real address is created", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        if !attempted { Button("Try again") { retry += 1 }.disabled(store.busy) }
                        else { Text("Check your aliases in Pass before creating another. This request will not be repeated automatically.").font(.caption).foregroundStyle(.secondary) }
                    }
                    if store.mustRefreshBeforeWriting { Text("Refresh Pass online before creating an alias.").font(.callout).foregroundStyle(.secondary) }
                }.padding(24).textFieldStyle(.plain).disabled(saving || attempted)
            }
            Divider()
            HStack {
                Button("Cancel", action: dismissSheet).buttonStyle(PassPillStyle())
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Create and copy alias", action: create).buttonStyle(PassPillStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(loading || saving || attempted || !store.canCreateAlias || draft.flatMap { try? $0.encodedInput() } == nil).accessibilityIdentifier("createAlias")
            }.padding(20)
        }
    }
    private func success(_ value: CreatedPassAlias) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text("Your alias is ready").font(.title2.weight(.semibold))
            Text(value.alias).font(.title3.weight(.medium)).textSelection(.enabled).multilineTextAlignment(.center)
            Text(store.isDemo ? "Synthetic alias · nothing was copied" : copied ? "Copied · clipboard clears after 30 seconds" : "Created in Pass")
                .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("aliasCreated")
            if !store.isDemo { Button(copied ? "Copy again" : "Copy alias") { copy(value.alias) }.buttonStyle(PassPillStyle()) }
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
            Spacer()
            HStack {
                Button("View in Pass") { viewInPass(value, vaultID) }.buttonStyle(PassPillStyle())
                Spacer()
                Button("Done", action: dismissSheet).buttonStyle(PassPillStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(28)
    }
    private func chooseVault() { if !store.writableVaults.contains(where: { $0.id == vaultID }) { vaultID = store.writableVaults.first(where: { $0.id == store.selectedVault })?.id ?? store.writableVaults.first?.id ?? "" } }
    private func loadOptions() async {
        guard store.phase == .open, !vaultID.isEmpty, !attempted else { return }
        options = nil; loading = true; error = nil; let vault = vaultID
        defer { if vault == vaultID { loading = false } }
        do {
            let value = try await store.aliasOptions(vaultID: vault)
            try Task.checkCancellation(); guard vaultID == vault else { return }
            options = value; suffixIndex = 0; mailboxID = value.mailboxes[0].id; titleFocused = true
        } catch { if !Task.isCancelled && vaultID == vault { self.error = "Couldn’t load alias options. Check your Pass connection, plan and vault permissions." } }
    }
    private func create() {
        guard let draft, !attempted, !saving, store.canCreateAlias else { return }
        attempted = true; saving = true; error = nil
        saveTask = Task { @MainActor in
            defer { saving = false }
            do {
                let created = try await store.createAlias(draft, vaultID: vaultID)
                try Task.checkCancellation(); guard !closing, store.phase == .open else { return }
                result = created
                if !store.isDemo { copy(created.alias) }
            } catch { if !Task.isCancelled && store.phase == .open { self.error = "Alias creation wasn’t confirmed. Refresh Pass and check for the alias before trying again." } }
        }
    }
    private func copy(_ alias: String) {
        ClipboardController.shared.copy(alias); copied = true; copyTask?.cancel()
        copyTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)); copied = false } catch {}
        }
    }
    private func dismissSheet() { closing = true; saveTask?.cancel(); copyTask?.cancel(); close() }
}
