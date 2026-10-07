// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import ProtonXCore

@MainActor protocol ProductWindowTarget: AnyObject {
    var isAvailable: Bool { get }
    func bringForward()
}

/// One owner for product-opening intent. URL delivery can precede SwiftUI's
/// window creation; activation must wait for the requested native window.
@MainActor final class ProductWindows {
    static let shared = ProductWindows()
    private final class Reference {
        weak var target: (any ProductWindowTarget)?
        init(_ target: any ProductWindowTarget) { self.target = target }
    }
    private var windows: [ProductRoute: Reference] = [:]
    private var opener: ((ProductRoute) -> Void)?
    private var launchFinished = false
    private var generation = 0
    private(set) var pending: ProductRoute?
    private let enqueue: (@escaping @MainActor () -> Void) -> Void

    init(enqueue: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
        DispatchQueue.main.async(execute: action)
    }) { self.enqueue = enqueue }

    func installOpener(_ opener: @escaping (ProductRoute) -> Void) {
        self.opener = opener
        openPending()
    }
    func didFinishLaunching() {
        launchFinished = true
        openPending()
    }
    func open(_ product: ProductRoute) {
        generation += 1
        pending = product
        openPending()
    }
    func open(urls: [URL]) {
        // The last valid product is the user's latest intent. No account or
        // session data is accepted in these links.
        if let product = urls.compactMap({ ProductRoute(url: $0) }).last { open(product) }
    }
    func register(_ target: any ProductWindowTarget, for product: ProductRoute) {
        windows[product] = Reference(target)
        if pending == product { focusPending() }
    }
    private func openPending() {
        guard launchFinished, let product = pending, let opener else { return }
        if windows[product]?.target?.isAvailable != true { opener(product) }
        focusPending()
    }
    private func focusPending() {
        guard launchFinished, let product = pending else { return }
        let ticket = generation
        // SwiftUI must finish attaching/ordering the new scene first. Do not
        // activate whichever window happened to be key before URL delivery.
        enqueue { [weak self] in
            guard let self, self.generation == ticket, self.pending == product,
                  let window = self.windows[product]?.target, window.isAvailable else { return }
            window.bringForward()
            self.pending = nil
        }
    }
}

@MainActor private final class NativeProductWindow: ProductWindowTarget {
    weak var window: NSWindow?
    private var closed = false
    // Only read in deinit outside MainActor; notification removal is thread safe.
    nonisolated(unsafe) private var closeObserver: NSObjectProtocol?
    var isAvailable: Bool { window != nil && !closed }
    init(_ window: NSWindow) {
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed = true }
        }
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    func bringForward() {
        guard isAvailable, let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ProductWindowRegistration: NSViewRepresentable {
    let product: ProductRoute
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(product: product) }
    func updateNSView(_ nsView: RegistrationView, context: Context) { nsView.registerWindow() }
    final class RegistrationView: NSView {
        let product: ProductRoute
        private var target: NativeProductWindow?
        init(product: ProductRoute) { self.product = product; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerWindow() }
        func registerWindow() {
            guard let window else { target = nil; return }
            if target?.window === window && target?.isAvailable == true { return }
            let target = NativeProductWindow(window)
            self.target = target
            ProductWindows.shared.register(target, for: product)
        }
    }
}

private struct ProductWindowNavigation: ViewModifier {
    let product: ProductRoute
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.background(ProductWindowRegistration(product: product).frame(width: 0, height: 0))
            .onAppear { ProductWindows.shared.installOpener { openWindow(id: $0.rawValue) } }
    }
}

extension View {
    func productWindow(_ product: ProductRoute) -> some View { modifier(ProductWindowNavigation(product: product)) }
}
