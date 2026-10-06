import Foundation
import AppKit
import WebKit
import Testing
import Network
@testable import ProtonXApp

private final class SyntheticReaderEndpoint: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "ProtonX.synthetic.reader")
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.withLock { self?.count += 1 }
            connection.start(queue: queue)
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
        listener.start(queue: queue)
    }
    deinit { listener.cancel() }
}

@Suite(.serialized) @MainActor struct MailReaderTests {
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(8) {
            if (try? await predicate()) == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Synthetic WebKit reader did not finish")
    }
    private func script(_ view: WKWebView, _ source: String) async throws -> Any? {
        try await view.evaluateJavaScript(source, in: nil, contentWorld: .defaultClient)
    }
    @Test func preservesStructureAndBlocksMessageCode() async throws {
        let endpoint = try SyntheticReaderEndpoint()
        try await wait { endpoint.listener.port != nil }
        let url = "http://127.0.0.1:\(try #require(endpoint.listener.port).rawValue)/synthetic"
        let html = """
        <h1>Account update</h1><p>Hello <strong>Alex &amp; Sam</strong>.</p>
        <table><tr><th>Plan</th><th>Cost</th></tr><tr><td>Demo</td><td>10</td></tr></table>
        <ol><li>First</li><li>Second</li></ol><blockquote>Earlier reply</blockquote>
        <a href="https://example.com/help">Help</a>
        <script>document.documentElement.dataset.syntheticExecuted='yes';</script><p id="click-test" onclick="document.documentElement.dataset.syntheticExecuted='yes'">Click</p>
        <script src="\(url)/script"></script><img src="\(url)/pixel"><iframe src="\(url)/frame"></iframe>
        <style>@import url('\(url)/style'); p { background-image:url('\(url)/css'); }</style>
        """
        var height: CGFloat = 240
        var failed = false
        var openedLink: URL?
        let parent = MailHTMLView(html: html, height: .init(get: { height }, set: { height = $0 }), failed: .init(get: { failed }, set: { failed = $0 }), openLink: { openedLink = $0 })
        let coordinator = MailHTMLView.Coordinator(parent)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = MailPaperWebView(frame: NSRect(x: 0, y: 0, width: 620, height: 240), configuration: config)
        view.navigationDelegate = coordinator; view.uiDelegate = coordinator
        coordinator.configure(view)
        defer { MailHTMLView.dismantleNSView(view, coordinator: coordinator) }
        try await wait { (try await self.script(view, "document.querySelectorAll('table tr').length")) as? Int == 2 }
        #expect(!failed)
        #expect(try await script(view, "document.querySelector('h1').textContent") as? String == "Account update")
        #expect(try await script(view, "document.querySelector('strong').textContent") as? String == "Alex & Sam")
        #expect(try await script(view, "document.querySelectorAll('li').length") as? Int == 2)
        #expect(try await script(view, "document.documentElement.dataset.syntheticExecuted === undefined") as? Bool == true)
        #expect(try await script(view, "getComputedStyle(document.documentElement).backgroundColor") as? String == "rgb(255, 255, 255)")
        #expect(try await script(view, "document.querySelector('img').naturalWidth") as? Int == 0)
        #expect(try await script(view, "performance.getEntriesByType('resource').filter(x => x.transferSize > 0).length") as? Int == 0)
        try await Task.sleep(for: .milliseconds(250))
        #expect(endpoint.requests == 0)
        #expect(openedLink == nil)
        _ = try await script(view, "document.querySelector('a').click()")
        try await wait { openedLink != nil }
        #expect(openedLink?.absoluteString == "https://example.com/help")
        #expect(view.url?.absoluteString == "about:blank")
        _ = try await script(view, "document.querySelector('#click-test').click()")
        #expect(try await script(view, "document.documentElement.dataset.syntheticExecuted === undefined") as? Bool == true)
        #expect(endpoint.requests == 0)
        // Replacing selected content must reload the in-memory document safely.
        coordinator.parent = MailHTMLView(html: "<p>Replacement synthetic body</p>", height: parent.$height, failed: parent.$failed, openLink: { _ in })
        coordinator.load(view)
        try await wait { (try await self.script(view, "document.body.innerText")) as? String == "Replacement synthetic body" }
    }
    @Test func externalLinksHaveAClosedSchemePolicy() {
        for value in ["https://example.com/help", "http://example.com/", "mailto:alex@example.com"] {
            #expect(MailReaderPolicy.externalURL(URL(string: value)!) != nil)
        }
        for value in ["javascript:alert(1)", "data:text/html,hello", "file:///etc/passwd", "protonx://private", "https://user:password@example.com/"] {
            #expect(MailReaderPolicy.externalURL(URL(string: value)!) == nil)
        }
        #expect(MailReaderPolicy.document("<h1>Synthetic</h1>").contains("default-src 'none'"))
    }
}
