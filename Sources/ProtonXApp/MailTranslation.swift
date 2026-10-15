// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NaturalLanguage
import SwiftUI

enum MailLanguage {
    static func code(_ value: String) -> String? {
        let tag = value.replacingOccurrences(of: "_", with: "-")
        guard tag.count <= 35, tag.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil,
              let base = Locale.Language(identifier: tag).languageCode?.identifier, base != "und" else { return nil }
        return Locale.Language(identifier: tag).minimalIdentifier
    }
    static func base(_ value: String) -> String { Locale.Language(identifier: value).languageCode?.identifier ?? value }
    static func name(_ code: String) -> String { Locale.current.localizedString(forIdentifier: code) ?? code }
    static func shortName(_ code: String) -> String {
        base(code) == "zh" ? name(code) : Locale.current.localizedString(forLanguageCode: base(code)) ?? name(code)
    }
    static func detect(_ text: String) -> String? {
        var lines: [String] = []
        var letters = 0
        for line in text.prefix(64_000).components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "--" || trimmed == "-- " || trimmed.hasPrefix("-----Original Message") ||
                (trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:")) { break }
            // Decorative rules and conversion artifacts must not exhaust the sample
            // before the first actual sentence in a table-based email.
            if !trimmed.hasPrefix(">") {
                let prose = String(line.prefix(2_000)).replacingOccurrences(of: #"https?://\S+|\S+@\S+"#, with: "", options: .regularExpression)
                let count = prose.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                if count >= 2 { lines.append(prose); letters += count }
                if letters >= 8_000 { break }
            }
        }
        let sample = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"https?://\S+|\S+@\S+"#, with: "", options: .regularExpression)
        guard sample.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer(); recognizer.processString(sample)
        guard let result = recognizer.languageHypotheses(withMaximum: 1).first, result.value >= 0.65 else { return nil }
        return code(result.key.rawValue)
    }
    static func containsProse(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["USD", "EUR", "GBP", "TRY", "TL"].contains(core),
              core.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2 else { return false }
        let stripped = core.replacingOccurrences(of: #"https?://\S+|\S+@\S+|\b(?:USD|EUR|GBP|TRY|TL)\b"#, with: "", options: .regularExpression)
        return stripped.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2
    }
}

/// Preferences contain language tags only. Message content/results never enter defaults.
@MainActor final class MailTranslationSettings: ObservableObject {
    static let shared = MailTranslationSettings()
    private let defaults: UserDefaults
    @Published var offersEnabled: Bool { didSet { defaults.set(offersEnabled, forKey: "mailTranslationOffers") } }
    @Published var target: String { didSet { defaults.set(MailLanguage.code(target) ?? "en", forKey: "mailTranslationTarget") } }
    @Published private(set) var understood: Set<String>
    @Published private(set) var always: Set<String>
    @Published private(set) var ignored: Set<String>
    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        offersEnabled = defaults.object(forKey: "mailTranslationOffers") as? Bool ?? true
        target = MailLanguage.code(defaults.string(forKey: "mailTranslationTarget") ?? preferredLanguages.first ?? "en") ?? "en"
        func languages(_ key: String, fallback: [String] = []) -> Set<String> {
            Set((defaults.stringArray(forKey: key) ?? fallback).prefix(64).compactMap(MailLanguage.code).map(MailLanguage.base))
        }
        understood = languages("mailTranslationUnderstood", fallback: preferredLanguages)
        always = languages("mailTranslationAlways"); ignored = languages("mailTranslationIgnored")
    }
    func understands(_ code: String) -> Bool { understood.contains(MailLanguage.base(code)) }
    func setUnderstood(_ code: String, _ enabled: Bool) {
        guard let code = MailLanguage.code(code) else { return }
        if enabled { understood.insert(MailLanguage.base(code)) } else { understood.remove(MailLanguage.base(code)) }
        defaults.set(understood.sorted(), forKey: "mailTranslationUnderstood")
    }
    func setAlways(_ code: String, _ enabled: Bool) {
        guard let code = MailLanguage.code(code) else { return }; let base = MailLanguage.base(code)
        if enabled { always.insert(base); ignored.remove(base) } else { always.remove(base) }
        saveRules()
    }
    func setIgnored(_ code: String, _ enabled: Bool) {
        guard let code = MailLanguage.code(code) else { return }; let base = MailLanguage.base(code)
        if enabled { ignored.insert(base); always.remove(base) } else { ignored.remove(base) }
        saveRules()
    }
    private func saveRules() {
        defaults.set(always.sorted(), forKey: "mailTranslationAlways"); defaults.set(ignored.sorted(), forKey: "mailTranslationIgnored")
    }
}

/// Translate bounded prose blocks. URLs, email addresses and paragraph separators
/// remain literal; results are rendered as native text, never trusted as HTML.
struct MailTranslationDocument: Sendable {
    enum Part: Sendable { case literal(String), prose(Int, String, String) }
    static let maxBytes = 64 * 1024
    let parts: [Part]
    let strings: [String]
    let htmlDocument: MailHTMLTranslationDocument?
    var isHTML: Bool { htmlDocument != nil }
    var languageSample: String { htmlDocument?.sample ?? "" }
    init(sanitizedHTML: String) throws {
        let document = try MailHTMLTranslationDocument(sanitizedHTML)
        parts = []; strings = document.strings; htmlDocument = document
    }
    init(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= Self.maxBytes else { throw Failure.tooLong }
        let ns = text as NSString, full = NSRange(location: 0, length: ns.length)
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let breaks = try NSRegularExpression(pattern: #"\r?\n[\t \r]*\n"#)
        let ranges = (detector.matches(in: text, range: full).map(\.range) + breaks.matches(in: text, range: full).map(\.range)).sorted { $0.location < $1.location }
        var parts: [Part] = [], strings: [String] = []
        func prose(_ value: String) {
            var remainder = value[...]
            while !remainder.isEmpty {
                var end = remainder.index(remainder.startIndex, offsetBy: min(2_000, remainder.count))
                if end != remainder.endIndex, let space = remainder[..<end].lastIndex(where: \.isWhitespace), remainder.distance(from: remainder.startIndex, to: space) > 1_000 { end = remainder.index(after: space) }
                let slice = String(remainder[..<end]), core = slice.trimmingCharacters(in: .whitespacesAndNewlines)
                if MailLanguage.containsProse(core), let range = slice.range(of: core) {
                    parts.append(.prose(strings.count, String(slice[..<range.lowerBound]), String(slice[range.upperBound...])))
                    strings.append(core)
                } else { parts.append(.literal(slice)) }
                remainder = remainder[end...]
            }
        }
        var cursor = 0
        for range in ranges where range.location >= cursor {
            prose(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            parts.append(.literal(ns.substring(with: range))); cursor = NSMaxRange(range)
        }
        prose(ns.substring(from: cursor))
        guard !strings.isEmpty, strings.count <= 128 else { throw Failure.tooLong }
        self.parts = parts; self.strings = strings; htmlDocument = nil
    }
    func assemble(_ translated: [String]) throws -> String {
        guard translated.count == strings.count, translated.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              translated.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1024 else { throw Failure.invalidResult }
        if let htmlDocument { return try htmlDocument.assemble(translated) }
        return parts.map { part in
            switch part { case .literal(let value): value; case .prose(let index, let before, let after): before + translated[index] + after }
        }.joined()
    }
    enum Failure: Error { case tooLong, invalidResult }
}

@MainActor final class MailTranslationModel: ObservableObject {
    enum Availability { case installed, download, unsupported }
    enum Phase { case ready, checking, translating, failed }
    struct Request: Identifiable, Sendable {
        let id = UUID()
        let source: String, target: String
        let document: MailTranslationDocument
    }
    @Published private(set) var source: String?
    @Published private(set) var target = "en"
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var availability: Availability = .unsupported
    @Published private(set) var request: Request?
    @Published private(set) var translated: String?
    @Published private(set) var translatedIsHTML = false
    @Published private(set) var completedBlocks = 0
    @Published private(set) var translationStarted = false
    @Published private(set) var isPreparing = false
    @Published var showingTranslation = false
    @Published var dismissed = true
    @Published private(set) var error: String?
    private var text = "", generation = UUID()
    private var document: MailTranslationDocument?
    private var autoAttempted = false
    var pair: String { (source ?? "") + ":" + target }
    var canTranslate: Bool { source != nil && MailLanguage.base(source!) != MailLanguage.base(target) && availability != .unsupported && phase != .checking && phase != .translating }
    func load(_ text: String, settings: MailTranslationSettings) {
        clear(); self.text = text; document = try? MailTranslationDocument(text)
        configure(sample: text, settings: settings)
    }
    func load(_ text: String, sanitizedHTML: String, settings: MailTranslationSettings) async {
        clear(); isPreparing = true; phase = .checking; self.text = text; let ticket = generation
        let prepared = await Task.detached(priority: .userInitiated) { try? MailTranslationDocument(sanitizedHTML: sanitizedHTML) }.value
        guard !Task.isCancelled, generation == ticket else { return }
        document = prepared; isPreparing = false; phase = .ready
        // HTML is authoritative: never fall back to translating the helper's
        // Markdown conversion if the formatted document exceeds our bounds.
        configure(sample: prepared?.languageSample ?? text, settings: settings)
    }
    private func configure(sample: String, settings: MailTranslationSettings) {
        source = MailLanguage.detect(sample); target = settings.target
        if let source {
            let base = MailLanguage.base(source)
            dismissed = !settings.offersEnabled || settings.ignored.contains(base) || (settings.understands(source) && !settings.always.contains(base)) || base == MailLanguage.base(target)
        } else { dismissed = true }
    }
    func choose(source: String? = nil, target: String? = nil) {
        guard (source ?? self.source) != self.source || (target ?? self.target) != self.target else { dismissed = false; return }
        cancel(); generation = UUID(); translated = nil; showingTranslation = false; error = nil; autoAttempted = false
        if let source { self.source = source }; if let target { self.target = target }
        availability = .unsupported; dismissed = false
    }
    func check(using lookup: (String, String) async -> Availability) async {
        guard let source, MailLanguage.base(source) != MailLanguage.base(target) else { availability = .unsupported; return }
        let ticket = generation; phase = .checking
        let result = await lookup(source, target)
        guard !Task.isCancelled, generation == ticket else { return }
        availability = result; phase = .ready
    }
    func begin() {
        guard canTranslate, let source else { return }
        do {
            guard let document else { throw MailTranslationDocument.Failure.tooLong }
            request = Request(source: source, target: target, document: document)
            completedBlocks = 0; translationStarted = false; error = nil; phase = .translating
        } catch { self.error = "This message is too long to translate here. The original is unchanged."; phase = .failed }
    }
    func beginAutomatically(settings: MailTranslationSettings, active: Bool) {
        guard active, !dismissed, !autoAttempted, translated == nil, let source, settings.always.contains(MailLanguage.base(source)), availability == .installed, canTranslate else { return }
        // Automatic translation never starts a language download/permission sheet.
        autoAttempted = true; begin()
    }
    func complete(_ id: UUID, result: Result<String, Error>) {
        guard request?.id == id else { return }
        let isHTML = request?.document.isHTML == true
        request = nil; phase = .ready
        switch result {
        case .success(let text): translated = text; translatedIsHTML = isHTML; showingTranslation = true
        case .failure(let error):
            if error is CancellationError { return }
            self.error = "Translation couldn’t finish. Try again; the original is unchanged."; phase = .failed
        }
    }
    func progress(_ id: UUID, completed: Int) { if request?.id == id { completedBlocks = completed; translationStarted = true } }
    func timeout(_ id: UUID) {
        guard request?.id == id else { return }; cancel(); phase = .failed
        error = "Translation is taking too long. Try again; the original is unchanged."
    }
    func cancel() { request = nil; if phase == .translating { phase = .ready }; autoAttempted = true }
    func clear() {
        cancel(); generation = UUID(); source = nil; text = ""; document = nil; translated = nil; translatedIsHTML = false; showingTranslation = false; completedBlocks = 0; translationStarted = false
        error = nil; availability = .unsupported; phase = .ready; autoAttempted = false; isPreparing = false; dismissed = true
    }
}
