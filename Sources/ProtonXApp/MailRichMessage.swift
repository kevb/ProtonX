import SwiftUI
import WebKit

/// Only the helper's sanitized HTML is accepted here. WebKit adds an independent
/// network/script boundary; it never receives an account session or file base URL.
enum MailReaderPolicy {
    static let blockRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    static func document(_ sanitizedHTML: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="color-scheme" content="light"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html { background:white; color:#17141c; color-scheme:only light; }
        body { margin:0; padding:28px; font:15px/1.55 -apple-system, sans-serif; overflow-wrap:anywhere; }
        img, iframe, object, embed, form, input, button, video, audio { display:none !important; }
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
    @State private var height: CGFloat = 240
    @State private var failed = false
    @State private var link: URL?
    var body: some View {
        VStack(spacing: 0) {
            if sanitizedHTML != nil {
                HStack {
                    Label("Remote images blocked", systemImage: "hand.raised").foregroundStyle(.secondary)
                    Spacer()
                    Button(plainText ? "Formatted message" : "Plain text") { plainText.toggle() }
                        .disabled(failed).buttonStyle(.plain).foregroundStyle(MailTheme.accent)
                }.font(.caption).padding(12)
            }
            if let sanitizedHTML, !plainText, !failed {
                MailHTMLView(html: sanitizedHTML, height: $height, failed: $failed, openLink: { link = $0 })
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
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> MailPaperWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = MailPaperWebView(frame: .zero, configuration: configuration)
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
        func configure(_ view: MailPaperWebView) {
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ProtonX-Mail-Block-All-v1", encodedContentRuleList: MailReaderPolicy.blockRules) { [weak self, weak view] rules, _ in
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
            navigation = view.loadHTMLString(MailReaderPolicy.document(parent.html), baseURL: nil)
        }
        func measure(_ view: WKWebView) {
            guard active, ready, !view.isLoading else { return }
            let expected = loaded
            // Trusted constant code in an isolated world. No message code or interpolated text.
            view.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().height)", in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.active, self.loaded == expected else { return }
                if case .success(let value) = result, let number = value as? NSNumber,
                   number.doubleValue.isFinite {
                    self.parent.height = min(50_000, max(240, CGFloat(number.doubleValue)))
                }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            measure(webView)
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
