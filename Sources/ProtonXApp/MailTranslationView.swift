// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
@preconcurrency import Translation

@available(macOS 15.0, *)
enum AppleMailTranslation {
    static func availabilityService() -> LanguageAvailability {
        #if compiler(>=6.3)
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        #endif
        return LanguageAvailability()
    }
    static func configuration(source: String, target: String) -> TranslationSession.Configuration {
        let source = Locale.Language(identifier: source), target = Locale.Language(identifier: target)
        #if compiler(>=6.3)
        if #available(macOS 26.4, *) { return .init(source: source, target: target, preferredStrategy: .lowLatency) }
        #endif
        return .init(source: source, target: target)
    }
    static func languages() async -> [String] {
        await availabilityService().supportedLanguages.map(\.minimalIdentifier).sorted { MailLanguage.name($0).localizedStandardCompare(MailLanguage.name($1)) == .orderedAscending }
    }
    static func availability(_ source: String, _ target: String) async -> MailTranslationModel.Availability {
        switch await availabilityService().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) {
        case .installed: .installed
        case .supported: .download
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }
    static func translate(_ request: MailTranslationModel.Request, session: TranslationSession, progress: (@MainActor @Sendable (Int) -> Void)? = nil) async throws -> String {
        try Task.checkCancellation()
        try await session.prepareTranslation()
        await progress?(0)
        let inputs = request.document.strings.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        var results: [Int: String] = [:]
        for try await response in session.translate(batch: inputs) {
            try Task.checkCancellation()
            guard let id = response.clientIdentifier, let index = Int(id), inputs.indices.contains(index), results[index] == nil,
                  MailLanguage.base(response.sourceLanguage.minimalIdentifier) == MailLanguage.base(request.source),
                  MailLanguage.base(response.targetLanguage.minimalIdentifier) == MailLanguage.base(request.target) else { throw MailTranslationDocument.Failure.invalidResult }
            results[index] = response.targetText
            await progress?(results.count)
        }
        guard results.count == inputs.count else { throw MailTranslationDocument.Failure.invalidResult }
        let output = inputs.indices.map { results[$0]! }
        return try await Task.detached(priority: .userInitiated) { try request.document.assemble(output) }.value
    }
}

@available(macOS 15.0, *)
private struct AppleMailTranslationTask: View {
    let request: MailTranslationModel.Request
    let progress: @MainActor @Sendable (Int) -> Void
    let finished: @MainActor (Result<String, Error>) -> Void
    var body: some View {
        Color.clear.translationTask(AppleMailTranslation.configuration(source: request.source, target: request.target)) { session in
            do { finished(.success(try await AppleMailTranslation.translate(request, session: session, progress: progress))) }
            catch { finished(.failure(error)) }
        }
    }
}

struct MailTranslationRibbon: View {
    @ObservedObject var model: MailTranslationModel
    @ObservedObject var settings: MailTranslationSettings
    let languages: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { languagePair; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: 8) {
                    languagePair
                    HStack { actions; Spacer(minLength: 0) }
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("mailTranslationError")
            } else if model.phase == .ready, model.availability == .unsupported {
                Text(model.source == nil ? "Choose the language of this message." : MailLanguage.base(model.source!) == MailLanguage.base(model.target) ? "Choose a different destination language." : "This language pair isn’t available on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
            .background(MailTheme.accent.opacity(0.08))
            .overlay(alignment: .bottom) { Rectangle().fill(MailTheme.border).frame(height: 1) }
            .accessibilityIdentifier("mailTranslationRibbon")
    }
    private var languagePair: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble").font(.system(size: 14)).foregroundStyle(MailTheme.accent).accessibilityHidden(true)
            Menu {
                ForEach(sourceLanguages, id: \.self) { code in Button(MailLanguage.name(code)) { model.choose(source: code) } }
            } label: { Text(model.source.map(MailLanguage.shortName) ?? "Choose language") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Message language").accessibilityIdentifier("mailTranslationSource")
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
            Menu {
                ForEach(targetLanguages, id: \.self) { code in Button(MailLanguage.name(code)) { model.choose(target: code) } }
            } label: { Text(MailLanguage.shortName(model.target)) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Translate to").accessibilityIdentifier("mailTranslationTarget")
        }.disabled(model.phase == .translating || model.isPreparing)
            .help("Translation happens on this Mac. The original message is kept unchanged.")
    }
    private var sourceLanguages: [String] { uniqueLanguages([model.source].compactMap { $0 } + languages) }
    private var targetLanguages: [String] { uniqueLanguages([model.target] + languages) }
    private func uniqueLanguages(_ values: [String]) -> [String] { Array(Set(values)).sorted { MailLanguage.name($0).localizedStandardCompare(MailLanguage.name($1)) == .orderedAscending } }
    private var actions: some View {
        HStack(spacing: 12) {
            if model.phase == .translating {
                ProgressView().controlSize(.mini).accessibilityLabel("Translating")
                Text(model.completedBlocks == 0 ? "Translating…" : "Translating \(model.completedBlocks)/\(model.request?.document.strings.count ?? 0)…").foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }.buttonStyle(.plain).accessibilityIdentifier("mailTranslationCancel")
            } else if model.translated != nil {
                Text(model.showingTranslation ? "Translated on this Mac" : "Original").font(.caption).foregroundStyle(.secondary)
                Button(model.showingTranslation ? "Show original" : "Show translation") { model.showingTranslation.toggle() }
                    .buttonStyle(.plain).foregroundStyle(MailTheme.accent).accessibilityIdentifier("mailTranslationToggle")
            } else {
                if model.phase == .checking { ProgressView().controlSize(.mini).accessibilityLabel("Checking languages") }
                Button(model.phase == .failed ? "Try again" : "Translate") { model.begin() }
                    .buttonStyle(.borderedProminent).tint(MailTheme.action).controlSize(.small)
                    .disabled(!model.canTranslate).accessibilityIdentifier("mailTranslate")
                    .help(model.availability == .download ? "Download the required languages, then translate on this Mac." : "Translate on this Mac")
            }
            Menu {
                if let source = model.source {
                    Toggle("Always translate \(MailLanguage.name(source))", isOn: Binding(get: { settings.always.contains(MailLanguage.base(source)) }, set: { settings.setAlways(source, $0) }))
                    Toggle("I understand \(MailLanguage.name(source))", isOn: Binding(get: { settings.understands(source) }, set: { settings.setUnderstood(source, $0) }))
                    Button("Never offer for \(MailLanguage.name(source))") { settings.setIgnored(source, true); model.cancel(); model.dismissed = true; model.showingTranslation = false }
                }
                Divider()
                Text("On-device translation · Original preserved")
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Translation options").accessibilityIdentifier("mailTranslationOptions")
            Button {
                model.cancel(); model.dismissed = true; model.showingTranslation = false
            } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss translation for this message")
                .accessibilityLabel("Dismiss translation").accessibilityIdentifier("mailTranslationDismiss")
        }
    }
}

@available(macOS 15.0, *)
struct MailTranslationReader<Original: View>: View {
    let text: String
    let sanitizedHTML: String?
    let isActive: Bool
    @ViewBuilder let original: (_ showTranslateButton: Bool, _ offerTranslation: @escaping () -> Void, _ translatedHTML: String?) -> Original
    @StateObject private var model = MailTranslationModel()
    @ObservedObject private var settings = MailTranslationSettings.shared
    @State private var languages: [String] = []
    var body: some View {
        VStack(spacing: 0) {
            if !model.dismissed { MailTranslationRibbon(model: model, settings: settings, languages: languages) }
            if let translated = model.translated, model.showingTranslation, !model.dismissed {
                if model.translatedIsHTML { original(false, {}, translated) }
                else { MailTranslatedPaper(text: translated) }
            } else {
                original(model.dismissed, { model.dismissed = false }, nil)
            }
        }
        .background {
            if let request = model.request, isActive {
                AppleMailTranslationTask(request: request, progress: { model.progress(request.id, completed: $0) }) { model.complete(request.id, result: $0) }.id(request.id).allowsHitTesting(false)
            }
        }
        .task(id: sanitizedHTML ?? text) {
            if let sanitizedHTML { await model.load(text, sanitizedHTML: sanitizedHTML, settings: settings) }
            else { model.load(text, settings: settings) }
        }
        .onChange(of: settings.target) { _, value in if !model.isPreparing { model.choose(target: value); updateOffer() } }
        .onChange(of: settings.offersEnabled) { _, _ in updateOffer() }
        .onChange(of: settings.understood) { _, _ in updateOffer() }
        .onChange(of: settings.ignored) { _, _ in updateOffer() }
        .onChange(of: settings.always) { _, _ in updateOffer(); model.beginAutomatically(settings: settings, active: isActive) }
        .onChange(of: isActive) { _, active in
            if active { model.beginAutomatically(settings: settings, active: true) } else { model.cancel() }
        }
        .task { languages = await AppleMailTranslation.languages() }
        .task(id: model.pair) {
            await model.check(using: AppleMailTranslation.availability)
            model.beginAutomatically(settings: settings, active: isActive)
        }
        .task(id: model.translationStarted ? model.request?.id : nil) {
            guard model.translationStarted else { return }
            guard let request = model.request else { return }
            do { try await Task.sleep(for: .seconds(30)); model.timeout(request.id) } catch {}
        }
        .onDisappear { model.clear() }
    }
    private func updateOffer() {
        guard let source = model.source else { return }
        let base = MailLanguage.base(source)
        model.dismissed = !settings.offersEnabled || settings.ignored.contains(base) || (settings.understands(source) && !settings.always.contains(base)) || base == MailLanguage.base(model.target)
        if model.dismissed { model.cancel(); model.showingTranslation = false }
    }
}

struct MailTranslatedPaper: View {
    let text: String
    @State private var link: URL?
    var body: some View {
        Text(attributed).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
            .foregroundStyle(MailTheme.ink).tint(Color(red: 0.41, green: 0.27, blue: 0.85))
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading).padding(28).background(MailTheme.paper)
            .environment(\.colorScheme, .light)
            .environment(\.openURL, OpenURLAction { url in link = MailReaderPolicy.externalURL(url); return .handled })
            .alert("Open this link?", isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } })) {
                Button("Cancel", role: .cancel) { link = nil }
                Button("Open") { if let link { NSWorkspace.shared.open(link) }; link = nil }
            } message: { Text(link?.absoluteString ?? "") }
            .accessibilityIdentifier("mailTranslatedPaper")
    }
    private var attributed: AttributedString {
        var result = AttributedString(text)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url.flatMap(MailReaderPolicy.externalURL), let range = Range(match.range, in: text),
                   let lower = AttributedString.Index(range.lowerBound, within: result), let upper = AttributedString.Index(range.upperBound, within: result) { result[lower..<upper].link = url }
            }
        }
        return result
    }
}

struct MailTranslationSettingsView: View {
    @ObservedObject private var settings = MailTranslationSettings.shared
    @State private var languages: [String] = []
    var body: some View {
        Form {
            Section("Translation") {
                Toggle("Offer to translate other languages", isOn: $settings.offersEnabled)
                Picker("Translate into", selection: $settings.target) {
                    ForEach(Array(Set([settings.target] + languages)).sorted(), id: \.self) { Text(MailLanguage.name($0)).tag($0) }
                }
                Text("Messages are translated on this Mac. Apple may ask to download language models the first time. Only the message you open is checked; the original email is never changed.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Languages I understand") {
                Text("Translation won’t be offered for these languages. You can still translate any message using its reader controls.").font(.caption).foregroundStyle(.secondary)
                ForEach(settings.understood.sorted(), id: \.self) { code in
                    HStack { Text(MailLanguage.name(code)); Spacer(); Button("Remove") { settings.setUnderstood(code, false) }.buttonStyle(.borderless) }
                }
                Menu("Add a language…") {
                    ForEach(languages.filter { !settings.understands($0) }, id: \.self) { code in Button(MailLanguage.name(code)) { settings.setUnderstood(code, true) } }
                }
            }
            if !settings.always.isEmpty || !settings.ignored.isEmpty {
                Section("Language rules") {
                    ForEach(settings.always.sorted(), id: \.self) { code in rule("Always translate", code: code) { settings.setAlways(code, false) } }
                    ForEach(settings.ignored.sorted(), id: \.self) { code in rule("Never offer", code: code) { settings.setIgnored(code, false) } }
                    Text("Always translate applies to opened messages with language models already installed. A missing download still needs a click.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if #unavailable(macOS 15.0) { Text("Mail translation requires macOS 15 or later.").foregroundStyle(.secondary) }
        }.formStyle(.grouped).padding(16)
            .task { if #available(macOS 15.0, *) { languages = await AppleMailTranslation.languages() } }
    }
    private func rule(_ title: String, code: String, remove: @escaping () -> Void) -> some View {
        HStack { Text(title + " · " + MailLanguage.name(code)); Spacer(); Button("Reset", action: remove).buttonStyle(.borderless) }
    }
}
