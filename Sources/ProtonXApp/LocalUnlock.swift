// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import ProtonXCore

/// Local authentication only. Product stores still own restore and session epochs.
@MainActor final class LocalUnlockAuthentication: ObservableObject {
    enum Mode { case touchID, system }
    enum State { case ready, authenticating, authenticated, cancelled, failed }
    @Published private(set) var context = LAContext()
    @Published private(set) var state: State = .ready
    private(set) var mode: Mode = .touchID
    private(set) var automaticAttemptAllowed = true
    private var generation: UInt64 = 0
    private let evaluate: (@MainActor @Sendable () async throws -> Bool)?
    let supportsTouchID: Bool

    init(evaluate: (@MainActor @Sendable () async throws -> Bool)? = nil, supportsTouchID: Bool? = nil) {
        self.evaluate = evaluate
        let probe = LAContext()
        self.supportsTouchID = supportsTouchID ?? (probe.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && probe.biometryType == .touchID)
    }
    func arm() {
        guard state != .authenticating else { return }
        context.invalidate(); context = LAContext(); state = .ready
        automaticAttemptAllowed = true
    }
    func consumeAutomaticAttempt(visible: Bool, foreground: Bool, attached: Bool, busy: Bool) -> Bool {
        guard automaticAttemptAllowed, supportsTouchID, visible, foreground, attached, !busy, state == .ready else { return false }
        automaticAttemptAllowed = false
        return true
    }
    func authenticate(_ mode: Mode, reason: String) async throws -> Bool {
        guard state != .authenticating else { return false }
        automaticAttemptAllowed = false; self.mode = mode
        // Password fallback must use a context that isn't paired with an embedded view.
        let current = mode == .touchID ? context : LAContext()
        if mode == .system { context.invalidate() }
        activeContext = current
        generation &+= 1; let captured = generation
        state = .authenticating
        do {
            let success: Bool
            if let evaluate { success = try await evaluate() }
            else {
                // Keep LAContext on the main actor. Older Apple SDKs do not mark
                // it Sendable; only the callback's result crosses the boundary.
                success = try await withCheckedThrowingContinuation { continuation in
                    current.evaluatePolicy(mode == .touchID ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication, localizedReason: reason) { accepted, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: accepted) }
                    }
                }
            }
            try Task.checkCancellation()
            guard generation == captured else { throw CancellationError() }
            activeContext = nil; state = success ? .authenticated : .cancelled
            return success
        } catch {
            if generation == captured {
                activeContext = nil
                let code = (error as? LAError)?.code
                state = error is CancellationError || (error as? ProtonXError) == .cancelled || [.userCancel, .systemCancel, .appCancel, .userFallback].contains(code) ? .cancelled : .failed
            }
            throw error
        }
    }
    private var activeContext: LAContext?
    func cancel() {
        generation &+= 1; automaticAttemptAllowed = false
        activeContext?.invalidate(); activeContext = nil; context.invalidate()
        state = .cancelled
    }
}

/// The OS owns fingerprint capture and its animation; ProtonX supplies the framing.
struct LocalUnlockCard: View {
    let product: String
    @ObservedObject var authentication: LocalUnlockAuthentication
    let isActive: Bool
    let busy: Bool
    let unlock: (LocalUnlockAuthentication.Mode) -> Void
    let cancel: () -> Void
    @State private var attachedContext: LAContext?
    @State private var foreground = false

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 30).fill(PassTheme.accent.opacity(0.09))
                RoundedRectangle(cornerRadius: 30).strokeBorder(PassTheme.accent.opacity(0.16), lineWidth: 1)
                if authentication.supportsTouchID {
                    EmbeddedAuthenticationView(context: authentication.context) { context, active in
                        attachedContext = context; foreground = active
                        if !active, authentication.state == .authenticating,
                           authentication.mode == .touchID { cancel() }
                        attemptAutomatically()
                    }.id(ObjectIdentifier(authentication.context)).frame(width: 64, height: 64)
                    if authentication.state != .authenticating {
                        Image(systemName: authentication.state == .authenticated ? "checkmark.shield" : "touchid")
                            .font(.system(size: 48, weight: .light)).foregroundStyle(PassTheme.accent).accessibilityHidden(true)
                    }
                } else {
                    Image(systemName: "lock.shield").font(.system(size: 42, weight: .light)).foregroundStyle(PassTheme.accent)
                }
            }.frame(width: 112, height: 112)
            VStack(spacing: 10) {
                Text("Unlock \(product)").font(.system(size: 30, weight: .semibold))
                Text(status).font(.system(size: 14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(height: 40)
            }
            if busy {
                HStack(spacing: 8) {
                    if authentication.state == .authenticated { ProgressView().controlSize(.small) }
                    Text(authentication.state == .authenticated ? "Opening your workspace…" : "Waiting for authentication…")
                }.font(.callout).foregroundStyle(PassTheme.accent).frame(height: 38)
                if authentication.state == .authenticating && authentication.mode == .touchID {
                    Button("Use Mac password…") { unlock(.system) }
                        .buttonStyle(.plain).foregroundStyle(PassTheme.accent).accessibilityIdentifier("passwordUnlock")
                }
                Button("Cancel", action: cancel).buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                if authentication.supportsTouchID {
                    if authentication.state != .ready {
                        Button { authentication.arm() } label: {
                            Label("Try Touch ID again", systemImage: "touchid").frame(maxWidth: .infinity)
                        }.buttonStyle(PassPillStyle(primary: true)).accessibilityIdentifier("retryTouchID")
                    }
                    Button("Use Mac password…") { unlock(.system) }
                        .buttonStyle(.plain).foregroundStyle(PassTheme.accent).accessibilityIdentifier("passwordUnlock")
                } else {
                    Button { unlock(.system) } label: {
                        Label("Unlock with Mac password", systemImage: "lock.open").frame(maxWidth: .infinity)
                    }.buttonStyle(PassPillStyle(primary: true)).accessibilityIdentifier("passwordUnlock")
                }
            }
            Label("Protected by macOS", systemImage: "checkmark.shield")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }.frame(width: 360).padding(32)
            .accessibilityIdentifier("localUnlock" + product)
            .onChange(of: isActive) { _, active in
                if active { attemptAutomatically() }
                else if authentication.state == .authenticating { cancel() }
            }
            .onChange(of: busy) { _, _ in attemptAutomatically() }
            .onDisappear { if authentication.state == .authenticating { cancel() } }
    }
    private var status: String {
        if authentication.state == .authenticated { return "Authenticated. Reopening your saved \(product) session." }
        if authentication.state == .cancelled { return "Your \(product) stays locked. Try again when you’re ready." }
        if authentication.state == .failed { return "Touch ID is unavailable right now. Try again or use your Mac password." }
        return authentication.supportsTouchID ? "Rest your finger on Touch ID to open your saved \(product) session." : "Use your Mac password to open your saved \(product) session."
    }
    private func attemptAutomatically() {
        if authentication.consumeAutomaticAttempt(visible: isActive, foreground: foreground,
                                                   attached: attachedContext === authentication.context, busy: busy) { unlock(.touchID) }
    }
}

private struct EmbeddedAuthenticationView: NSViewRepresentable {
    let context: LAContext
    let activity: (LAContext, Bool) -> Void
    func makeNSView(context coordinator: Context) -> AuthenticationHost {
        let host = AuthenticationHost(authenticationContext: context)
        host.activity = { active in activity(context, active) }
        return host
    }
    func updateNSView(_ host: AuthenticationHost, context coordinator: Context) {
        host.activity = { active in activity(context, active) }
    }
    static func dismantleNSView(_ host: AuthenticationHost, coordinator: ()) { host.stop(); host.activity = nil }
}

@MainActor private final class AuthenticationHost: NSView {
    var activity: ((Bool) -> Void)?
    private var observations: [NSObjectProtocol] = []
    init(authenticationContext: LAContext) {
        super.init(frame: .zero)
        let view = LAAuthenticationView(context: authenticationContext, controlSize: .large)
        view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: centerXAnchor), view.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.report() }
            })
        }
        Task { @MainActor [weak self] in self?.report() }
    }
    private func report() { activity?(window?.isKeyWindow == true && NSApp.isActive && window?.isMiniaturized == false) }
    func stop() { observations.forEach(NotificationCenter.default.removeObserver); observations = [] }
}
