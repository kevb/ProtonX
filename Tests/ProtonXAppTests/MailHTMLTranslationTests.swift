// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftSoup
import Testing
@preconcurrency import Translation
@testable import ProtonXApp

private let syntheticRefundHTML = """
<style>.receipt {max-width:600px;background:#fff;color:#123456} h2{font-size:24px} td{padding:12px}</style>
<div style="display:none">This English preview must not affect language detection or translation.</div>
<table class="receipt" width="600"><tbody><tr><td>
<h2>Siparişiniz hakkında güncelleme</h2><p>Siparişiniz hakkında güncelleme</p>
<p>Sayın müşterimiz,</p><p>DEMO-1042 numaralı siparişinize ait <strong>125,00 TL</strong> tutarındaki iadeniz başarıyla işlenmiştir.</p>
<ul><li>İşlem tarihi: 15 Ekim</li><li>Ödemeniz aynı kartınıza aktarılacaktır.</li></ul>
<p><a class="action" href="https://example.invalid/orders?demo=1&amp;ref=2">Siparişinizi inceleyin</a></p>
<p>Destek: destek@example.invalid</p><p>https://example.invalid/help</p><hr>
<p style="color:#666">İyi günler dileriz.</p>
</td></tr></tbody></table>
"""

@Suite @MainActor struct MailHTMLTranslationTests {
    private func settings() -> MailTranslationSettings {
        MailTranslationSettings(defaults: UserDefaults(suiteName: "ProtonXHTMLTranslationTests." + UUID().uuidString)!, preferredLanguages:["en"])
    }
    @Test func detectsVisibleTurkishDespiteConverterRulesCSSAndEnglishPreheader() async throws {
        let artifact = String(repeating: String(repeating:"_",count:200) + "\n", count:100) + "\n## Merhaba Deniz, faturanız hazırlanmıştır. Son ödeme tarihi 20 Ekim. İyi günler dileriz."
        #expect(MailLanguage.detect(artifact) == "tr")
        let model = MailTranslationModel()
        await model.load(artifact, sanitizedHTML:syntheticRefundHTML, settings:settings())
        #expect(model.source == "tr" && !model.dismissed)
        await model.check { _, _ in .installed }; model.begin()
        let request = try #require(model.request)
        #expect(request.document.isHTML)
        #expect(!request.document.strings.contains { $0.contains("English preview") || $0.contains("font-size") || $0.contains("____") || $0.contains("https://") })
        #expect(request.document.strings.filter { $0 == "Siparişiniz hakkında güncelleme" }.count == 1)
        #expect(request.document.strings.count < 12)
    }
    @Test func translationPreservesDOMTablesHeadingsLinksStylesAndNumbers() throws {
        let source = try SwiftSoup.parseBodyFragment(syntheticRefundHTML)
        let input = try MailTranslationDocument(sanitizedHTML:syntheticRefundHTML)
        let translated = try input.assemble(input.strings.map { "English: " + $0 })
        let result = try SwiftSoup.parseBodyFragment(translated)
        for selector in ["table", "tbody", "tr", "td", "h2", "strong", "ul", "li", "hr", "p", "a"] {
            #expect(try result.select(selector).size() == source.select(selector).size())
        }
        #expect(try result.select("h2").text() == "English: Siparişiniz hakkında güncelleme")
        #expect(try result.select("a").attr("href") == "https://example.invalid/orders?demo=1&ref=2")
        #expect(try result.select("a").attr("class") == "action")
        #expect(try result.select("table").attr("width") == "600")
        #expect(try result.select("style").html() == source.select("style").html())
        #expect(try result.select("strong").text() == "125,00 TL")
        #expect(try result.text().contains("destek@example.invalid"))
        #expect(!translated.contains("## ") && !translated.contains("____"))
    }
    @Test func generatedMarkupCanOnlyBecomeEscapedText() throws {
        let input = try MailTranslationDocument(sanitizedHTML:"<p>Merhaba dünya, iyi günler dileriz.</p><a href='https://example.invalid'>Bağlantıyı açın</a>")
        let payload = "<img src='https://evil.invalid/x' onerror='alert(1)'><script>alert(1)</script> & goodbye"
        let output = try input.assemble(input.strings.map { _ in payload })
        let parsed = try SwiftSoup.parseBodyFragment(output)
        #expect(try parsed.select("script,img,iframe").isEmpty())
        #expect(try parsed.select("a").attr("href") == "https://example.invalid")
        #expect(try parsed.text().contains("<script>alert(1)</script>"))
        #expect(output.contains("&lt;script&gt;"))
    }
    @Test func malformedMarkupUnicodeAndNestedInlineStylesRemainReadable() throws {
        for html in ["<table><tr><td><b>Merhaba</b> Deniz, siparişiniz hazır.<td>İyi günler!",
                     "<h2>مرحباً بالعالم</h2><p dir='rtl'>هذه رسالة تجريبية <em>للاختبار فقط</em></p>",
                     "<p>日本語のテストメールです。<strong>重要なお知らせ</strong></p>"] {
            let document = try MailTranslationDocument(sanitizedHTML:html)
            let result = try document.assemble(document.strings)
            #expect(try SwiftSoup.parseBodyFragment(result).text() == SwiftSoup.parseBodyFragment(html).text())
        }
    }
    @Test func richResultTicketsTimeoutAndClearCannotRevealStaleContent() async throws {
        let model = MailTranslationModel()
        await model.load("Synthetic converter text", sanitizedHTML:syntheticRefundHTML, settings:settings())
        await model.check { _, _ in .installed }; model.begin(); let request = try #require(model.request)
        model.progress(request.id, completed:1); #expect(model.translationStarted && model.completedBlocks == 1)
        model.timeout(request.id); #expect(model.phase == .failed && model.request == nil)
        model.complete(request.id,result:.success("Late HTML")); #expect(model.translated == nil)
        model.begin(); let next = try #require(model.request)
        model.complete(next.id,result:.success(try next.document.assemble(next.document.strings)))
        #expect(model.translatedIsHTML && model.showingTranslation)
        model.clear(); #expect(model.translated == nil && !model.translatedIsHTML && !model.translationStarted)
    }
    @Test func HTMLPreparationCannotReopenAfterLock() async {
        let model = MailTranslationModel(), preferences = settings()
        let pending = Task { await model.load("Synthetic converter text", sanitizedHTML:syntheticRefundHTML, settings:preferences) }
        while !model.isPreparing { await Task.yield() }
        model.clear(); await pending.value
        #expect(model.source == nil && model.translated == nil && model.request == nil)
    }
    @Test func HTMLSizeAndProseBudgetsAreEnforcedBeforeTranslation() {
        #expect(throws:(any Error).self) { try MailTranslationDocument(sanitizedHTML:String(repeating:" ",count:2*1024*1024+1)) }
        #expect(throws:(any Error).self) { try MailTranslationDocument(sanitizedHTML:"<p>" + String(repeating:"Merhaba dünya ",count:6_000) + "</p>") }
    }
    @Test func lowLatencyStrategyIsExplicitAndMatchesAvailability() {
        #if compiler(>=6.3)
        if #available(macOS 26.4, *) {
            #expect(AppleMailTranslation.configuration(source:"tr",target:"en").preferredStrategy == .lowLatency)
            #expect(AppleMailTranslation.availabilityService().preferredStrategy == .lowLatency)
        }
        #endif
    }
    @Test func installedNativeEngineTranslatesRichSyntheticMailAndReportsProgress() async throws {
        #if compiler(>=6.3)
        guard #available(macOS 26.4, *), await AppleMailTranslation.availability("tr", "en-GB") == .installed else { return }
        let document = try MailTranslationDocument(sanitizedHTML:syntheticRefundHTML)
        let request = MailTranslationModel.Request(source:"tr",target:"en-GB",document:document)
        let session = TranslationSession(installedSource:Locale.Language(identifier:"tr"),target:Locale.Language(identifier:"en-GB"),preferredStrategy:.lowLatency)
        var completed = 0
        let start = ContinuousClock.now
        let output = try await AppleMailTranslation.translate(request,session:session,progress:{ completed = $0 })
        print("Synthetic rich translation: \(document.strings.count) unique blocks, \(start.duration(to:.now)).")
        #expect(completed == document.strings.count)
        let result = try SwiftSoup.parseBodyFragment(output)
        #expect(try !result.select("h2").text().contains("Siparişiniz"))
        #expect(try result.select("table.receipt").size() == 1 && result.select("strong").text() == "125,00 TL")
        #expect(try result.select("a").attr("href") == "https://example.invalid/orders?demo=1&ref=2")
        #endif
    }
}
