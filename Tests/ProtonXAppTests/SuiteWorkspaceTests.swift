import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@Suite @MainActor struct SuiteWorkspaceTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ProtonXNavigationTests." + UUID().uuidString)!
    }
    @Test func firstLaunchHomeDoesNotCreateProductStores() {
        let defaults = isolatedDefaults()
        var passStarts = 0, mailStarts = 0
        let suite = SuiteWorkspace(defaults: defaults, makePass: { passStarts += 1; return PassStore(previewOnly: true) },
                                   makeMail: { mailStarts += 1; return NativeMailStore(previewOnly: true) })
        #expect(suite.selected == nil)
        #expect(passStarts == 0 && mailStarts == 0)
        #expect(!suite.canCreate && !suite.canRefresh)
        suite.select(.mail)
        #expect(mailStarts == 1 && passStarts == 0)
        suite.select(nil); suite.select(.mail)
        #expect(mailStarts == 1)
    }
    @Test(arguments: ["home", "last", "pass", "mail", "invalid"])
    func explicitLauncherOverridesEveryStartupPreference(_ preference: String) {
        let defaults = isolatedDefaults()
        defaults.set(preference, forKey: "suiteStartup"); defaults.set("pass", forKey: "suiteLastProduct")
        let suite = SuiteWorkspace(defaults: defaults, initialProduct: .mail,
                                   makePass: { PassStore(previewOnly: true) }, makeMail: { NativeMailStore(previewOnly: true) })
        #expect(suite.selected == .mail && suite.pass == nil && suite.mail != nil)
    }
    @Test func restoreLastProductAndHomePreference() {
        let defaults = isolatedDefaults()
        defaults.set("mail", forKey: "suiteLastProduct")
        let suite = SuiteWorkspace(defaults: defaults, makeMail: { NativeMailStore(previewOnly: true) })
        #expect(suite.selected == .mail)
        suite.select(nil)
        #expect(defaults.string(forKey: "suiteLastProduct") == "mail")
        defaults.set("home", forKey: "suiteStartup")
        let next = SuiteWorkspace(defaults: defaults)
        #expect(next.selected == nil && next.mail == nil && next.pass == nil)
    }
    @Test func switchesRetainSelectionQueriesAndUnsavedMailWithoutSavingToPreferences() {
        let defaults = isolatedDefaults()
        let suite = SuiteWorkspace(defaults: defaults, previewOnly: true,
                                   makePass: { let pass = PassStore(previewOnly: true); pass.enterDemo(); return pass },
                                   makeMail: { NativeMailStore(previewOnly: true) })
        suite.select(.mail)
        let mail = suite.mail!
        mail.query = "coffee"; mail.selectedItem = 12; mail.compose()
        let editor = mail.editorState!
        editor.to = "test@example.com"; editor.subject = "SYNTHETIC unsaved subject"; editor.text = "SYNTHETIC unsaved body"
        suite.select(.pass)
        let pass = suite.pass!
        pass.query = "example"; let selected = pass.selectedItem
        suite.select(nil); suite.select(.mail)
        #expect(suite.mail === mail && mail.editorState === editor)
        #expect(mail.query == "coffee" && mail.selectedItem == 12)
        #expect(editor.content.subject == "SYNTHETIC unsaved subject" && editor.content.text == "SYNTHETIC unsaved body")
        #expect(!suite.canCreate && !suite.canRefresh)
        suite.select(.pass)
        #expect(suite.pass === pass && pass.query == "example" && pass.selectedItem == selected)
        #expect(defaults.string(forKey: "suiteLastProduct") == nil)
        #expect(!defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("SYNTHETIC") == true })
    }
    @Test func lockingClearsHiddenMailDraftAndPassDetails() {
        let suite = SuiteWorkspace(defaults: isolatedDefaults(), previewOnly: true,
                                   makePass: { let pass = PassStore(previewOnly: true); pass.enterDemo(); return pass })
        suite.select(.mail); suite.mail!.compose(); suite.mail!.editorState!.text = "SYNTHETIC unsaved"
        suite.select(.pass); suite.lock()
        #expect(suite.mail?.phase == .welcome && suite.mail?.draft == nil && suite.mail?.editorState == nil)
        #expect(suite.pass?.phase == .locked && suite.pass?.detail == nil)
        suite.select(.mail)
        #expect(suite.mail?.phase == .welcome && suite.mail?.editorState == nil)
    }
    @Test func closingDraftDropsEditorAndNextDraftStartsFresh() {
        let mail = NativeMailStore(previewOnly: true)
        mail.compose(); let editor = mail.editorState!
        editor.text = "SYNTHETIC discarded"; mail.discardDraft()
        #expect(mail.editorState == nil)
        mail.compose()
        #expect(mail.editorState !== editor && mail.editorState?.text == "")
    }
    @Test func quickAccessRequestSurvivesLazyOpeningAndCancelsOnSwitchOrLock() {
        let suite = SuiteWorkspace(defaults: isolatedDefaults(), previewOnly: true)
        suite.requestPassSearch()
        #expect(suite.selected == .pass && suite.pass != nil && suite.passSearchRequested)
        suite.select(.mail)
        #expect(!suite.passSearchRequested)
        suite.requestPassSearch(); suite.lock()
        #expect(!suite.passSearchRequested)
    }
    @Test func previewIgnoresRealStartupPreferences() {
        let defaults = isolatedDefaults(); defaults.set("mail", forKey: "suiteLastProduct"); defaults.set("pass", forKey: "suiteStartup")
        let suite = SuiteWorkspace(defaults: defaults, previewOnly: true)
        #expect(suite.selected == nil && suite.mail == nil && suite.pass == nil)
    }
}
