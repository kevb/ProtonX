import Foundation
import Testing
import ProtonXCore
@testable import ProtonXApp

@MainActor private final class SyntheticProductWindow: ProductWindowTarget {
    var isAvailable = true
    var focusCount = 0
    func bringForward() { focusCount += 1 }
}

@MainActor private final class DeferredProductActions {
    var actions: [@MainActor () -> Void] = []
    func drain() {
        let pending = actions; actions.removeAll()
        pending.forEach { $0() }
    }
}

@Suite @MainActor struct ProductWindowTests {
    @Test func coldMailLinkWaitsForLaunchOpenerAndRequestedWindow() {
        let queue = DeferredProductActions()
        let router = ProductWindows(enqueue: { queue.actions.append($0) })
        let pass = SyntheticProductWindow(), mail = SyntheticProductWindow()
        var opened: [ProductRoute] = []
        router.open(urls: [URL(string: "protonx://mail")!])
        router.register(pass, for: .pass)
        router.installOpener { opened.append($0) }
        queue.drain()
        #expect(opened.isEmpty)
        #expect(pass.focusCount == 0)
        router.didFinishLaunching()
        queue.drain()
        #expect(opened == [.mail])
        #expect(router.pending == .mail)
        router.register(mail, for: .mail)
        #expect(mail.focusCount == 0) // Wait until SwiftUI has ordered the scene.
        queue.drain()
        #expect(mail.focusCount == 1)
        #expect(pass.focusCount == 0)
        #expect(router.pending == nil)
    }

    @Test func launchCanFinishBeforeTheFirstSwiftUIOpenerAppears() {
        let queue = DeferredProductActions()
        let router = ProductWindows(enqueue: { queue.actions.append($0) })
        let mail = SyntheticProductWindow()
        var opened: [ProductRoute] = []
        router.didFinishLaunching()
        router.open(.mail)
        router.installOpener { opened.append($0); router.register(mail, for: $0) }
        queue.drain()
        #expect(opened == [.mail])
        #expect(mail.focusCount == 1)
        // Registering/re-rendering other scenes after completion cannot steal focus.
        let pass = SyntheticProductWindow()
        router.register(pass, for: .pass)
        router.installOpener { opened.append($0) }
        queue.drain()
        #expect(pass.focusCount == 0)
        #expect(mail.focusCount == 1)
    }

    @Test func warmLaunchReusesTheRequestedWindowWithoutReopeningScenes() {
        let queue = DeferredProductActions()
        let router = ProductWindows(enqueue: { queue.actions.append($0) })
        let pass = SyntheticProductWindow(), mail = SyntheticProductWindow()
        var opened: [ProductRoute] = []
        router.installOpener { opened.append($0) }
        router.didFinishLaunching()
        router.register(pass, for: .pass); router.register(mail, for: .mail)
        router.open(.mail); queue.drain()
        router.open(.pass); queue.drain()
        router.open(.mail); queue.drain()
        #expect(opened.isEmpty)
        #expect(mail.focusCount == 2)
        #expect(pass.focusCount == 1)
    }

    @Test func latestRequestWinsEvenWhenOlderWindowCreationFinishesLast() {
        let queue = DeferredProductActions()
        let router = ProductWindows(enqueue: { queue.actions.append($0) })
        let pass = SyntheticProductWindow(), mail = SyntheticProductWindow()
        router.installOpener { _ in }; router.didFinishLaunching()
        router.open(.mail)
        router.register(mail, for: .mail)
        router.open(.pass)
        router.register(pass, for: .pass)
        queue.drain()
        #expect(mail.focusCount == 0)
        #expect(pass.focusCount == 1)
        router.register(mail, for: .mail); queue.drain()
        #expect(mail.focusCount == 0)
    }

    @Test func closedOrReleasedWindowsAreRecreated() {
        let queue = DeferredProductActions()
        let router = ProductWindows(enqueue: { queue.actions.append($0) })
        let closed = SyntheticProductWindow(); closed.isAvailable = false
        var released: SyntheticProductWindow? = SyntheticProductWindow()
        var opened: [ProductRoute] = []
        router.register(closed, for: .mail)
        router.register(released!, for: .pass); released = nil
        router.installOpener { opened.append($0) }; router.didFinishLaunching()
        router.open(.mail); queue.drain()
        #expect(closed.focusCount == 0)
        router.open(.pass); queue.drain()
        #expect(opened == [.mail, .pass])
        let replacement = SyntheticProductWindow()
        router.register(replacement, for: .pass); queue.drain()
        #expect(replacement.focusCount == 1)
    }

    @Test func invalidURLsCannotChangePendingProduct() {
        let queue = DeferredProductActions()
        let router = ProductWindows(enqueue: { queue.actions.append($0) })
        router.open(.mail)
        router.open(urls: [URL(string: "protonx://pass?password=SYNTHETIC")!, URL(string: "https://pass")!])
        #expect(router.pending == .mail)
        router.open(urls: [URL(string: "protonx://mail")!, URL(string: "protonx://pass")!, URL(string: "protonx://drive")!])
        #expect(router.pending == .pass)
    }
}

@Suite @MainActor struct SuiteRoutingTests {
    @Test func sharedWindowSelectsLatestProductAndWarmRoutesNeverCreateAnotherWindow() {
        let queue = DeferredProductActions()
        let router = ProductWindows(enqueue: { queue.actions.append($0) })
        let window = SyntheticProductWindow()
        var selected: [ProductRoute] = [], opened: [ProductRoute] = []
        router.installSelector { product in
            // Selection must happen before the shared window is activated.
            #expect(window.focusCount == selected.count)
            selected.append(product)
        }
        router.installOpener { opened.append($0) }
        router.didFinishLaunching()
        router.register(window, for: .pass); router.register(window, for: .mail)
        router.open(.pass); router.open(.mail); queue.drain()
        #expect(selected == [.mail] && window.focusCount == 1 && opened.isEmpty)
        router.open(.pass); queue.drain()
        #expect(selected == [.mail, .pass] && window.focusCount == 2 && opened.isEmpty)
        router.showSuite()
        #expect(selected == [.mail, .pass] && window.focusCount == 3)
    }
}
