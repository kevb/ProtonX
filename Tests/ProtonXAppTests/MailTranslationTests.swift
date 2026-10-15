// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import SwiftUI
import Testing
@preconcurrency import Translation
@testable import ProtonXApp

private let syntheticTurkish = """
Merhaba Deniz,

Elektrik faturanız hazırlanmıştır. Son ödeme tarihi 20 Ekim. Faturanızı incelemek için https://example.invalid/fatura?hesap=42 bağlantısını kullanabilirsiniz.

Sorularınız için destek@example.invalid adresine yazabilirsiniz.

İyi günler dileriz.
"""
private actor TranslationAvailabilityGate {
    var reply: CheckedContinuation<MailTranslationModel.Availability, Never>?
    func wait() async -> MailTranslationModel.Availability { await withCheckedContinuation { reply = $0 } }
    func release() { reply?.resume(returning: .installed); reply = nil }
    var waiting: Bool { reply != nil }
}

@Suite @MainActor struct MailTranslationTests {
    private func settings(preferred: [String] = ["en-GB"]) -> MailTranslationSettings {
        let defaults = UserDefaults(suiteName: "ProtonXTranslationTests." + UUID().uuidString)!
        return MailTranslationSettings(defaults: defaults, preferredLanguages: preferred)
    }
    private func prepared(_ preferences: MailTranslationSettings) async -> MailTranslationModel {
        let model = MailTranslationModel(); model.load(syntheticTurkish, settings: preferences)
        await model.check { _, _ in .installed }; return model
    }
    @Test func detectionUsesMessageProseAndIgnoresEnglishSignatureAndQuotes() {
        #expect(MailLanguage.detect(syntheticTurkish + "\n--\nBest regards, Customer Support\nPlease contact us for more information") == "tr")
        #expect(MailLanguage.detect(syntheticTurkish + "\n> The old quoted message was entirely written in English and should not decide the language.") == "tr")
        #expect(MailLanguage.detect("Thank you for your message. Your appointment has been confirmed for tomorrow afternoon.") == "en")
        #expect(MailLanguage.detect("1234 €55.00 https://example.invalid/test") == nil)
        #expect(MailLanguage.detect("OK") == nil)
        #expect(MailLanguage.code("en_GB") == "en-GB")
        #expect(MailLanguage.code("en\nsecret") == nil)
    }
    @Test func understoodLanguageRulesAndTargetArePreferencesOnly() {
        let name = "ProtonXTranslationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MailTranslationSettings(defaults: defaults, preferredLanguages: ["en-GB"])
        #expect(preferences.understands("en-US") && !preferences.understands("tr"))
        preferences.setAlways("tr", true); preferences.setIgnored("tr", true)
        #expect(preferences.ignored == ["tr"] && preferences.always.isEmpty)
        preferences.setAlways("tr", true)
        #expect(preferences.always == ["tr"] && preferences.ignored.isEmpty)
        preferences.setUnderstood("fr-FR", true); preferences.target = "en-US"
        let restored = MailTranslationSettings(defaults: defaults, preferredLanguages: ["de"])
        #expect(restored.understands("fr-CA"))
        #expect(restored.target == MailLanguage.code("en-US") && restored.always == ["tr"])
        #expect(!defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("faturanız") })
    }
    @Test func languageAndOfferPreferencesDoNotAutomaticallyTranslateMessages() async {
        let preferences = settings(), model = await prepared(preferences)
        #expect(!model.dismissed && model.source == "tr" && model.canTranslate)
        #expect(model.request == nil && model.translated == nil)
        preferences.setUnderstood("tr", true); model.load(syntheticTurkish, settings: preferences)
        #expect(model.dismissed)
        preferences.setUnderstood("tr", false); preferences.setIgnored("tr", true)
        model.load(syntheticTurkish, settings: preferences); #expect(model.dismissed)
        preferences.setAlways("tr", true); model.load(syntheticTurkish, settings: preferences)
        #expect(!model.dismissed)
        preferences.offersEnabled = false; model.load(syntheticTurkish, settings: preferences)
        #expect(model.dismissed)
    }
    @Test func documentPreservesLinksAddressesWhitespaceAndUntrustedTextLiterally() throws {
        let text = "  Merhaba dünya!  \n\nhttps://example.invalid/a?x=1&y=2\n\nDestek: help@example.invalid\n<script>alert(1)</script>"
        let document = try MailTranslationDocument(text)
        #expect(try document.assemble(document.strings) == text)
        #expect(!document.strings.contains { $0.contains("https://") || $0.contains("help@example.invalid") })
        let translated = try document.assemble(document.strings.map { "EN: " + $0 })
        #expect(translated.contains("https://example.invalid/a?x=1&y=2") && translated.contains("help@example.invalid"))
        #expect(translated.contains("<script>")) // The reader renders it as native text, never HTML.
        #expect(throws: (any Error).self) { try document.assemble([]) }
        #expect(throws: (any Error).self) { try document.assemble(document.strings.map { _ in "" }) }
        #expect(throws: (any Error).self) { try MailTranslationDocument(String(repeating: "a", count: MailTranslationDocument.maxBytes + 1)) }
        let unicode = String(repeating: "Türkçe bir cümle. 👩🏽‍💻 ", count: 200)
        let chunks = try MailTranslationDocument(unicode)
        #expect(chunks.strings.allSatisfy { $0.count <= 2_000 })
        #expect(try chunks.assemble(chunks.strings) == unicode)
    }
    @Test func sameLanguageAndUnsupportedPairCannotStart() async {
        let model = await prepared(settings())
        model.choose(target: "tr"); await model.check { _, _ in Issue.record("Same language must not reach the provider"); return .installed }
        model.begin(); #expect(model.request == nil)
        model.choose(target: "en"); await model.check { _, _ in .unsupported }
        model.begin(); #expect(model.request == nil && model.translated == nil)
    }
    @Test func choosingCurrentLanguageDoesNotDisableAnAvailablePair() async {
        let model = await prepared(settings())
        model.choose(source: "tr")
        #expect(model.canTranslate); model.begin(); #expect(model.request != nil)
    }
    @Test func onlyInstalledExplicitlyRememberedActiveMessagesTranslateAutomatically() async {
        let preferences = settings(); preferences.setAlways("tr", true)
        let model = await prepared(preferences)
        model.beginAutomatically(settings: preferences, active: false); #expect(model.request == nil)
        model.beginAutomatically(settings: preferences, active: true); #expect(model.request != nil)
        model.cancel(); model.beginAutomatically(settings: preferences, active: true); #expect(model.request == nil)
        model.load(syntheticTurkish, settings: preferences); await model.check { _, _ in .download }
        model.beginAutomatically(settings: preferences, active: true); #expect(model.request == nil)
        model.begin(); #expect(model.request != nil) // An explicit click may request Apple's download sheet.
    }
    @Test func cancellationSelectionChangeAndLockRejectLateResults() async throws {
        let preferences = settings(), model = await prepared(preferences)
        model.begin(); let first = try #require(model.request)
        model.cancel(); model.complete(first.id, result: .success("Late translation"))
        #expect(model.translated == nil && model.request == nil)
        model.begin(); let second = try #require(model.request)
        model.choose(target: "de"); model.complete(second.id, result: .success("Wrong language result"))
        #expect(model.translated == nil && model.target == "de")
        await model.check { _, _ in .installed }; model.begin(); let third = try #require(model.request)
        model.clear(); model.complete(third.id, result: .success("Result after lock"))
        #expect(model.source == nil && model.translated == nil && model.request == nil)
        model.load("A completely different English message with enough text to recognise its language.", settings: preferences)
        model.complete(third.id, result: .success("Result for previous message")); #expect(model.translated == nil)
    }
    @Test func lateLanguageAvailabilityCannotOverwriteNewSelection() async {
        let model = await prepared(settings()), gate = TranslationAvailabilityGate()
        let pending = Task { await model.check { _, _ in await gate.wait() } }
        while !(await gate.waiting) { await Task.yield() }
        model.choose(target: "de"); await model.check { _, _ in .download }
        await gate.release(); await pending.value
        #expect(model.target == "de" && model.availability == .download)
    }
    @Test func originalToggleDoesNotRetranslateAndFailuresAreSafeToRetry() async throws {
        let model = await prepared(settings())
        model.begin(); let first = try #require(model.request)
        model.complete(first.id, result: .failure(CocoaError(.fileReadUnknown)))
        #expect(model.phase == .failed && model.translated == nil && model.error?.contains("original is unchanged") == true)
        model.begin(); let second = try #require(model.request)
        model.complete(second.id, result: .success("Hello Deniz,\n\nYour synthetic bill is ready."))
        #expect(model.showingTranslation && model.request == nil)
        model.showingTranslation = false; model.showingTranslation = true
        #expect(model.translated?.contains("Hello Deniz") == true && model.request == nil)
        model.clear(); #expect(model.translated == nil && !model.showingTranslation)
    }
    @Test func oversizedMessageFailsWithoutTruncationOrProviderRequest() async {
        let preferences = settings(), model = MailTranslationModel()
        model.load(String(repeating: syntheticTurkish, count: 300), settings: preferences)
        await model.check { _, _ in .installed }; model.begin()
        #expect(model.request == nil && model.phase == .failed && model.error?.contains("too long") == true)
    }
    @Test func appleAdapterTranslatesSyntheticTextWhenModelsAreAlreadyInstalled() async throws {
        // No download/permission UI in tests. Only this synthetic fixture is submitted.
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *), await AppleMailTranslation.availability("tr", "en-GB") == .installed else { return }
        let request = MailTranslationModel.Request(source: "tr", target: "en-GB", document: try MailTranslationDocument(syntheticTurkish))
        let session: TranslationSession
        #if compiler(>=6.3)
        if #available(macOS 26.4, *) { session = TranslationSession(installedSource: Locale.Language(identifier:"tr"),target:Locale.Language(identifier:"en-GB"),preferredStrategy:.lowLatency) }
        else { session = TranslationSession(installedSource: Locale.Language(identifier:"tr"),target:Locale.Language(identifier:"en-GB")) }
        #else
        session = TranslationSession(installedSource: Locale.Language(identifier:"tr"),target:Locale.Language(identifier:"en-GB"))
        #endif
        let output = try await AppleMailTranslation.translate(request,session:session)
        #expect(output != syntheticTurkish && !output.isEmpty)
        #expect(output.contains("https://example.invalid/fatura?hesap=42") && output.contains("destek@example.invalid"))
        #expect(output.contains("20"))
        #endif
    }
    @Test func ribbonLayoutsRenderSyntheticContentInBothAppearances() async throws {
        let preferences = settings(), model = await prepared(preferences)
        let output = "Hello Deniz,\n\nYour electricity bill is ready. Payment is due on 20 October.\n\nhttps://example.invalid/bill\n\nHave a good day."
        for translated in [false, true] {
            if translated {
                model.begin(); let request = try #require(model.request)
                model.complete(request.id, result: .success(output))
            }
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                for width in [340, 820] {
                    let view = VStack(spacing: 0) {
                        MailTranslationRibbon(model: model, settings: preferences, languages: ["tr", "en", "de", "fr"])
                        if translated { MailTranslatedPaper(text: output) }
                        else { MailMessagePaper(text: syntheticTurkish) }
                    }.frame(width: CGFloat(width)).background(MailTheme.canvas)
                    let host = NSHostingView(rootView: view); host.appearance = NSAppearance(named: appearance)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 390); host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/protonx-translation-\(name)-\(width)-\(translated ? "translated" : "original").png"))
                    #expect(host.fittingSize.width <= CGFloat(width) + 1)
                }
            }
        }
    }
}
