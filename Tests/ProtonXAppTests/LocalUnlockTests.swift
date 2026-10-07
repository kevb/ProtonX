// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import LocalAuthentication
import SwiftUI
import Testing
@testable import ProtonXApp

private actor AuthenticationReplyGate {
    private var reply: CheckedContinuation<Bool, Never>?
    private var earlyReply: Bool?
    func wait() async -> Bool {
        if let earlyReply { return earlyReply }
        return await withCheckedContinuation { reply = $0 }
    }
    func release(_ value: Bool) { earlyReply = value; reply?.resume(returning: value); reply = nil }
}

@Test @MainActor func automaticUnlockNeedsVisibleForegroundAttachedIdleProductAndRunsOnce() {
    let authentication = LocalUnlockAuthentication(evaluate: { true }, supportsTouchID: true)
    for flags in [(false, true, true, false), (true, false, true, false), (true, true, false, false), (true, true, true, true)] {
        #expect(!authentication.consumeAutomaticAttempt(visible: flags.0, foreground: flags.1, attached: flags.2, busy: flags.3))
    }
    #expect(authentication.consumeAutomaticAttempt(visible: true, foreground: true, attached: true, busy: false))
    #expect(!authentication.consumeAutomaticAttempt(visible: true, foreground: true, attached: true, busy: false))
    authentication.cancel()
    #expect(!authentication.consumeAutomaticAttempt(visible: true, foreground: true, attached: true, busy: false))
    authentication.arm()
    #expect(authentication.consumeAutomaticAttempt(visible: true, foreground: true, attached: true, busy: false))
}

@Test @MainActor func noBiometricsNeverAutomaticallyOpensPasswordDialog() async throws {
    var attempts = 0
    let authentication = LocalUnlockAuthentication(evaluate: { attempts += 1; return true }, supportsTouchID: false)
    #expect(!authentication.consumeAutomaticAttempt(visible: true, foreground: true, attached: true, busy: false))
    #expect(attempts == 0)
    #expect(try await authentication.authenticate(.system, reason: "Synthetic test"))
    #expect(attempts == 1); #expect(authentication.mode == .system); #expect(authentication.state == .authenticated)
}

@Test @MainActor func cancelledAuthenticationNeedsExplicitRetryAndFreshContext() async throws {
    let authentication = LocalUnlockAuthentication(evaluate: { throw LAError(.userCancel) }, supportsTouchID: true)
    let old = authentication.context
    do { _ = try await authentication.authenticate(.touchID, reason: "Synthetic test"); Issue.record("Expected cancellation") } catch {}
    #expect(authentication.state == .cancelled)
    #expect(!authentication.consumeAutomaticAttempt(visible: true, foreground: true, attached: true, busy: false))
    authentication.arm(); #expect(authentication.context !== old); #expect(authentication.state == .ready)
}

@Test @MainActor func lockRejectsLateBiometricSuccessAndConcurrentAttempts() async throws {
    let gate = AuthenticationReplyGate()
    let authentication = LocalUnlockAuthentication(evaluate: { await gate.wait() }, supportsTouchID: true)
    let first = Task { try await authentication.authenticate(.touchID, reason: "Synthetic test") }
    while authentication.state != .authenticating { await Task.yield() }
    #expect(!(try await authentication.authenticate(.system, reason: "Synthetic duplicate")))
    authentication.cancel(); await gate.release(true)
    do { _ = try await first.value; Issue.record("Late success must be rejected") } catch {}
    #expect(authentication.state == .cancelled); #expect(!authentication.automaticAttemptAllowed)
}

@Test @MainActor func biometricFailureKeepsProductLockedAndAllowsSystemFallback() async throws {
    var attempts = 0
    let authentication = LocalUnlockAuthentication(evaluate: {
        attempts += 1
        if attempts == 1 { throw LAError(.biometryLockout) }
        return true
    }, supportsTouchID: true)
    do { _ = try await authentication.authenticate(.touchID, reason: "Synthetic test"); Issue.record("Expected lockout") } catch {}
    #expect(authentication.state == .failed)
    #expect(try await authentication.authenticate(.system, reason: "Synthetic fallback"))
    #expect(authentication.state == .authenticated)
}

@Test @MainActor func syntheticUnlockCardRendersInBothAppearances() throws {
    // Synthetic evaluator only: never evaluates LocalAuthentication or starts a helper.
    for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        let authentication = LocalUnlockAuthentication(evaluate: { false }, supportsTouchID: true)
        authentication.cancel()
        let host = NSHostingView(rootView: LocalUnlockCard(product: "Mail", authentication: authentication, isActive: false, busy: false, unlock: { _ in }, cancel: {})
            .frame(width: 700, height: 600).background(PassTheme.canvas))
        host.appearance = NSAppearance(named: appearance); host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/protonx-unlock-\(name).png"))
        #expect(bitmap.pixelsWide > 0); #expect(bitmap.pixelsHigh > 0)
    }
}
