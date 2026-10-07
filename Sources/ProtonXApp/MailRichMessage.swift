import SwiftUI
import WebKit

/// Only the helper's sanitized HTML is accepted here. WebKit adds an independent
/// network/script boundary; it never receives an account session or file base URL.
enum MailReaderPolicy {
    static let blockRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    static let imageRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^protonx-image://asset","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":".*"},"action":{"type":"block-cookies"}}]"#
    static let maxHeight: CGFloat = 50_000
    // Trusted native code in the isolated client world; message JavaScript stays disabled.
    static let activateImages = """
    for (const image of document.querySelectorAll('img[data-protonx-remote-src]')) {
        try {
            const url = new URL(image.getAttribute('data-protonx-remote-src'));
            if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || !url.hostname) continue;
            image.referrerPolicy = 'no-referrer';
            image.src = 'protonx-image://asset?url=' + encodeURIComponent(url.href);
        } catch (_) {}
    }
    """
    static let observeLayout = """
    const report = () => window.webkit.messageHandlers.protonXMailLayout.postMessage(Math.ceil(document.body.getBoundingClientRect().height));
    new ResizeObserver(report).observe(document.body);
    report();
    """
    static func document(_ sanitizedHTML: String, allowsRemoteImages: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src \(allowsRemoteImages ? "protonx-image:" : "'none'"); font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer"><meta name="color-scheme" content="light"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html { background:white; color:#17141c; color-scheme:only light; }
        body { margin:0; padding:28px; font:15px/1.55 -apple-system, sans-serif; overflow-wrap:anywhere; }
        iframe, object, embed, form, input, button, video, audio { display:none !important; }
        \(allowsRemoteImages ? "img { max-width:100%; }" : "img { display:none !important; }")
        * { animation:none !important; transition:none !important; }
        a { color:#6844d9; } pre { white-space:pre-wrap; overflow-wrap:anywhere; }
        blockquote { margin-left:12px; padding-left:16px; border-left:3px solid #ded9e9; }
        </style></head><body>\(sanitizedHTML)</body></html>
        """
    }
    static func externalURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme),
              url.user == nil, url.password == nil,
              !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if scheme != "mailto" { guard let host = url.host, !host.isEmpty else { return nil } }
        return url
    }
}

struct MailMessageContent: View {
    let text: String
    let sanitizedHTML: String?
    @State private var plainText = false
    @State private var allowsRemoteImages = false
    @State private var height: CGFloat = 240
    @State private var failed = false
    @State private var link: URL?
    var body: some View {
        VStack(spacing: 0) {
            if sanitizedHTML != nil {
                HStack {
                    Label(allowsRemoteImages ? "Remote images allowed" : "Remote images blocked", systemImage: allowsRemoteImages ? "photo" : "hand.raised").foregroundStyle(.secondary)
                    Button(allowsRemoteImages ? "Block images" : "Load images") { allowsRemoteImages.toggle() }
                        .buttonStyle(.plain).foregroundStyle(MailTheme.accent)
                        .disabled(plainText || failed)
                        .help("For this message only. Loading images contacts external servers and can tell the sender you opened it.")
                        .accessibilityIdentifier("mailRemoteImages")
                    Spacer()
                    Button(plainText ? "Formatted message" : "Plain text") { plainText.toggle() }
                        .disabled(failed).buttonStyle(.plain).foregroundStyle(MailTheme.accent)
                }.font(.caption).padding(12)
            }
            if let sanitizedHTML, !plainText, !failed {
                MailHTMLView(html: sanitizedHTML, height: $height, failed: $failed, openLink: { link = $0 }, allowsRemoteImages: allowsRemoteImages)
                    .id(allowsRemoteImages)
                    .frame(height: height).background(MailTheme.paper)
                    .environment(\.colorScheme, .light)
            } else { MailMessagePaper(text: text) }
            if failed { Text("Formatted view unavailable. Showing plain text.").font(.caption).foregroundStyle(.secondary).padding(12) }
        }
        .alert("Open this link?", isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } })) {
            Button("Cancel", role: .cancel) { link = nil }
            Button("Open") { if let link { NSWorkspace.shared.open(link) }; link = nil }
        } message: { Text(link?.absoluteString ?? "") }
    }
}

@MainActor
final class MailPaperWebView: WKWebView {
    var resized: (() -> Void)?
    var imageLoader: MailRemoteImages?
    var hasVerticalOverflow = false
    private var scrollMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopScrollMonitoring()
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window,
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)),
                  self.forwardVerticalScroll(event) else { return event }
            return nil
        }
    }
    /// A full-height WebKit document consumes wheel events even at its edges.
    /// Route vertical gestures to SwiftUI's enclosing scroll view; exceptionally
    /// tall bounded documents keep WebKit scrolling for their overflow.
    @discardableResult func forwardVerticalScroll(_ event: NSEvent) -> Bool {
        guard event.scrollingDeltaY != 0, !hasVerticalOverflow else { return false }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { scroll.scrollWheel(with: event); return true }
            ancestor = view.superview
        }
        return false
    }
    func stopScrollMonitoring() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.width - newSize.width) > 1
        super.setFrameSize(newSize)
        if changed { resized?() }
    }
}

struct MailHTMLView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    @Binding var failed: Bool
    let openLink: (URL) -> Void
    var allowsRemoteImages = false
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> MailPaperWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let imageLoader = allowsRemoteImages ? MailRemoteImages() : nil
        if let imageLoader { configuration.setURLSchemeHandler(imageLoader, forURLScheme:MailRemoteImages.scheme) }
        let view = MailPaperWebView(frame: .zero, configuration: configuration)
        view.imageLoader = imageLoader
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.underPageBackgroundColor = .white
        view.setAccessibilityIdentifier("mailHTMLPaper")
        view.resized = { [weak view, weak coordinator = context.coordinator] in
            if let view { coordinator?.measure(view) }
        }
        context.coordinator.configure(view)
        return view
    }
    func updateNSView(_ view: MailPaperWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(view)
    }
    static func dismantleNSView(_ view: MailPaperWebView, coordinator: Coordinator) {
        coordinator.active = false
        view.imageLoader?.invalidate(); view.imageLoader = nil
        view.stopScrollMonitoring()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "protonXMailLayout", contentWorld: .defaultClient)
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil; view.resized = nil
        // Keep resource blocking installed until WebKit releases the discarded view.
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MailHTMLView
        var active = true
        var ready = false
        var loaded: String?
        var navigation: WKNavigation?
        var allowsDocumentLoad = false
        init(_ parent: MailHTMLView) { self.parent = parent }
        private weak var paper: MailPaperWebView?
        private final class LayoutHandler: NSObject, WKScriptMessageHandler {
            weak var owner: Coordinator?
            init(_ owner: Coordinator) { self.owner = owner }
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.absoluteString == "about:blank",
                      let height = message.body as? NSNumber else { return }
                owner?.applyHeight(height.doubleValue)
            }
        }
        func configure(_ view: MailPaperWebView) {
            paper = view
            let controller = view.configuration.userContentController
            controller.add(LayoutHandler(self), contentWorld: .defaultClient, name: "protonXMailLayout")
            let identifier = parent.allowsRemoteImages ? "ProtonX-Mail-Images-v1" : "ProtonX-Mail-Block-All-v1"
            let rules = parent.allowsRemoteImages ? MailReaderPolicy.imageRules : MailReaderPolicy.blockRules
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { [weak self, weak view] rules, _ in
                guard let self, self.active, let view else { return }
                guard let rules else { self.parent.failed = true; return }
                view.configuration.userContentController.add(rules)
                self.ready = true; self.load(view)
            }
        }
        func load(_ view: WKWebView) {
            guard active, ready, loaded != parent.html else { return }
            loaded = parent.html
            allowsDocumentLoad = true
            navigation = view.loadHTMLString(MailReaderPolicy.document(parent.html, allowsRemoteImages: parent.allowsRemoteImages), baseURL: nil)
        }
        func measure(_ view: WKWebView) {
            guard active, ready, !view.isLoading else { return }
            let expected = loaded
            // Trusted constant code in an isolated world. No message code or interpolated text.
            view.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().height)", in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.active, self.loaded == expected else { return }
                if case .success(let value) = result, let number = value as? NSNumber { self.applyHeight(number.doubleValue) }
            }
        }
        func applyHeight(_ height: Double) {
            guard active, height.isFinite, height >= 0 else { return }
            paper?.hasVerticalOverflow = height > Double(MailReaderPolicy.maxHeight)
            let next = min(MailReaderPolicy.maxHeight, max(240, CGFloat(height)))
            if abs(parent.height - next) > 1 { parent.height = next }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            // Native evaluation runs in the isolated world even when automatic
            // content/user-script execution is disabled by the page preferences.
            let script = MailReaderPolicy.observeLayout + "\n" + (parent.allowsRemoteImages ? MailReaderPolicy.activateImages : "") + "\nundefined;"
            webView.evaluateJavaScript(script, in:nil, in:.defaultClient) { [weak self] _ in
                guard let self, self.active else { return }
                self.measure(webView)
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if active, navigation === self.navigation { parent.failed = true }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if active, navigation === self.navigation { parent.failed = true }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if active { parent.failed = true } }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard active else { return .cancel }
            if action.navigationType == .linkActivated {
                if let url = action.request.url, let allowed = MailReaderPolicy.externalURL(url) { parent.openLink(allowed) }
                return .cancel
            }
            // Only our initial in-memory about:blank document is allowed. No frames,
            // redirects, refresh navigation, downloads or file URLs.
            let initial = action.navigationType == .other && action.targetFrame?.isMainFrame == true
                && action.request.url?.absoluteString == "about:blank" && allowsDocumentLoad
            if initial { allowsDocumentLoad = false }
            return initial ? .allow : .cancel
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
