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
    @Test func idleLockClearsHiddenDemoDraftsWithoutArmingRealAuthentication() {
        let suite = SuiteWorkspace(previewOnly:true, initialProduct:.mail,
                                   makePass:{ let pass = PassStore(previewOnly:true); pass.enterDemo(); return pass })
        suite.mail!.compose(); suite.mail!.editorState!.text = "SYNTHETIC unsaved"
        suite.select(.pass); suite.lock(forAutomaticLock:true)
        #expect(suite.mail?.draft == nil && suite.mail?.editorState == nil)
        #expect(suite.pass?.detail == nil && suite.pass?.items.isEmpty == true)
        #expect(suite.mail?.localAuthentication.automaticAttemptAllowed == false)
        #expect(suite.pass?.localAuthentication.automaticAttemptAllowed == false)
    }
    @Test func inactivityTimerUsesAutomaticLockPathAndWaitsForNextDeadline() {
        // No configure(): no event monitors, timers, menu item or account operations.
        let integration = SystemIntegration()
        var automaticLocks = 0, manualLocks = 0
        integration.lockSuiteAutomatically = { automaticLocks += 1 }
        integration.lockSuite = { manualLocks += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        integration.checkInactivity(at:now,timeout:300)
        #expect(automaticLocks == 0 && manualLocks == 0)
        integration.checkInactivity(at:now+301,timeout:300)
        integration.checkInactivity(at:now+306,timeout:300)
        #expect(automaticLocks == 1 && manualLocks == 0)
        integration.checkInactivity(at:now+602,timeout:300)
        #expect(automaticLocks == 2 && manualLocks == 0)
        integration.lockSuiteAutomatically = nil
        integration.checkInactivity(at:now+903,timeout:300)
        #expect(manualLocks == 1)
    }
    @Test func overlappingSystemLocksSuspendBeforeLockingAndWaitForEveryResume() {
        let integration = SystemIntegration()
        var events: [String] = []
        integration.suspendAuthentication = { events.append($0 ? "suspend" : "resume") }
        integration.lockSuiteAutomatically = { events.append("automatic") }
        integration.lockSuite = { events.append("manual") }
        for reason in SystemIntegration.SystemLockReason.allCases {
            integration.updateSystemLock(reason, locked: true)
            integration.updateSystemLock(reason, locked: true)
        }
        #expect(events == Array(repeating: ["suspend", "automatic"], count: 4).flatMap { $0 })
        for reason in [SystemIntegration.SystemLockReason.sleep, .displaySleep, .sessionInactive] {
            integration.updateSystemLock(reason, locked: false)
        }
        #expect(events.last == "automatic")
        integration.updateSystemLock(.screenLocked, locked: false)
        integration.updateSystemLock(.screenLocked, locked: false)
        #expect(events.last == "resume" && events.filter { $0 == "resume" }.count == 1)
    }
    @Test func lazyProductsInheritSystemSuspensionAndManualLockSurvivesResume() {
        let suite = SuiteWorkspace(defaults: isolatedDefaults(), previewOnly: true)
        suite.suspendAuthentication(true)
        for product in [ProductRoute.pass, .mail, .calendar] { suite.select(product) }
        #expect(suite.pass?.localAuthentication.systemSuspended == true)
        #expect(suite.mail?.localAuthentication.systemSuspended == true)
        #expect(suite.calendar?.localAuthentication.systemSuspended == true)
        suite.lock(); suite.suspendAuthentication(false)
        #expect(suite.pass?.localAuthentication.automaticAttemptAllowed == false)
        #expect(suite.mail?.localAuthentication.automaticAttemptAllowed == false)
        #expect(suite.calendar?.localAuthentication.automaticAttemptAllowed == false)
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
