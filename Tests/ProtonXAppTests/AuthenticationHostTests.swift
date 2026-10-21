// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Testing
@testable import ProtonXApp

/// Real native view attachment, synthetic contexts only. Never evaluates a policy,
/// opens a product helper, reads Keychain data or presents authentication.
@Suite @MainActor struct AuthenticationHostTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        return window
    }
    private func controls(in view: NSView) -> [LAAuthenticationView] {
        (view as? LAAuthenticationView).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
    }
    @Test func hiddenProductsDoNotAttachNativeControls() throws {
        let window = makeWindow(); defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        let hosts = (0..<3).map { _ in AuthenticationHost(frame: .zero) }
        let contexts = hosts.map { _ in LAContext() }
        for (host, context) in zip(hosts, contexts) {
            host.configure(context: context, enabled: false, activity: { _, _ in })
            root.addSubview(host)
        }
        #expect(controls(in: root).isEmpty)
        hosts[0].configure(context: contexts[0], enabled: true, activity: { _, _ in })
        #expect(controls(in: root).count == 1)
        #expect(controls(in: hosts[0]).first?.context === contexts[0])
        hosts[0].configure(context: contexts[0], enabled: false, activity: { _, _ in })
        #expect(controls(in: root).isEmpty)
    }
    @Test func rapidProductSwitchesDetachPreviousControlBeforeReplacement() throws {
        let window = makeWindow(); defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        let hosts = (0..<3).map { _ in AuthenticationHost(frame: .zero) }
        var contexts = hosts.map { _ in LAContext() }
        hosts.forEach(root.addSubview)
        for turn in 0..<120 {
            let selected = turn % hosts.count
            let previous = controls(in: root).first
            // Reproduce incoming-before-outgoing SwiftUI updates. The outgoing
            // host remains enabled until after the new control has attached.
            contexts[selected] = LAContext()
            hosts[selected].configure(context: contexts[selected], enabled: true, activity: { _, _ in })
            #expect(previous?.superview == nil)
            #expect(controls(in: root).count == 1)
            #expect(controls(in: root).first?.context === contexts[selected])
            for index in hosts.indices where index != selected {
                hosts[index].configure(context: contexts[index], enabled: false, activity: { _, _ in })
            }
            #expect(controls(in: root).count == 1)
        }
        hosts.forEach { $0.stop() }
        #expect(controls(in: root).isEmpty)
    }
    @Test func retainedSwiftUICardsAttachOnlyTheSelectedProduct() async throws {
        let window = makeWindow(); defer { window.contentView = nil; window.close() }
        let authentications = (0..<3).map { _ in LocalUnlockAuthentication(evaluate: { false }, supportsTouchID: true) }
        let hosting = NSHostingView(rootView: SyntheticUnlockCards(authentications: authentications, selected: 0))
        window.contentView = hosting
        for turn in 0..<30 {
            let selected = turn % 3
            authentications[selected].arm()
            hosting.rootView = SyntheticUnlockCards(authentications: authentications, selected: selected)
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            let views = controls(in: hosting)
            #expect(views.count == 1)
            #expect(views.first?.context === authentications[selected].context)
        }
    }
    @Test func contextReplacementReusesHostAndDetachesOldNativeView() throws {
        let window = makeWindow(); defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        let host = AuthenticationHost(frame: .zero), first = LAContext(), next = LAContext()
        root.addSubview(host)
        host.configure(context: first, enabled: true, activity: { _, _ in })
        let oldView = try #require(controls(in: host).first)
        host.configure(context: first, enabled: true, activity: { _, _ in })
        #expect(controls(in: host).first === oldView)
        host.configure(context: next, enabled: true, activity: { _, _ in })
        #expect(oldView.superview == nil)
        #expect(controls(in: root).count == 1 && controls(in: root).first?.context === next)
    }
    @Test func ownershipIsPerWindowAndMovingHostReleasesPreviousWindow() throws {
        let first = makeWindow(), second = makeWindow()
        defer { first.contentView = nil; second.contentView = nil; first.close(); second.close() }
        let firstRoot = try #require(first.contentView), secondRoot = try #require(second.contentView)
        let a = AuthenticationHost(frame: .zero), b = AuthenticationHost(frame: .zero)
        let aContext = LAContext(), bContext = LAContext()
        firstRoot.addSubview(a); secondRoot.addSubview(b)
        a.configure(context: aContext, enabled: true, activity: { _, _ in })
        b.configure(context: bContext, enabled: true, activity: { _, _ in })
        #expect(controls(in: firstRoot).count == 1 && controls(in: secondRoot).count == 1)
        secondRoot.addSubview(a)
        #expect(controls(in: firstRoot).isEmpty && controls(in: b).isEmpty)
        #expect(controls(in: secondRoot).count == 1 && controls(in: a).first?.context === aContext)
        a.removeFromSuperview()
        #expect(controls(in: secondRoot).isEmpty)
    }
    @Test func queuedCallbacksCannotReportDetachedProductOrStaleContext() async throws {
        let window = makeWindow(); defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        let first = AuthenticationHost(frame: .zero), next = AuthenticationHost(frame: .zero)
        let oldContext = LAContext(), nextContext = LAContext(), replacement = LAContext()
        var oldReports = 0, reports: [LAContext] = []
        root.addSubview(first); root.addSubview(next)
        first.configure(context: oldContext, enabled: true, activity: { _, _ in oldReports += 1 })
        next.configure(context: nextContext, enabled: true, activity: { context, _ in reports.append(context) })
        next.configure(context: replacement, enabled: true, activity: { context, _ in reports.append(context) })
        for _ in 0..<20 { await Task.yield() }
        #expect(oldReports == 0 && !reports.isEmpty && reports.allSatisfy { $0 === replacement })
        next.stop(); let count = reports.count
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(reports.count == count && controls(in: root).isEmpty)
    }
}

private struct SyntheticUnlockCards: View {
    let authentications: [LocalUnlockAuthentication]
    let selected: Int
    var body: some View {
        ZStack {
            ForEach(authentications.indices, id: \.self) { index in
                LocalUnlockCard(product: ["Pass", "Mail", "Calendar"][index], authentication: authentications[index],
                                isActive: selected == index, busy: false, unlock: { _ in }, cancel: { authentications[index].cancel() })
                    .opacity(selected == index ? 1 : 0)
            }
        }
    }
}
