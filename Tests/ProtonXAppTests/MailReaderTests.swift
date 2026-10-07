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

private final class SyntheticImageProtocol: URLProtocol, @unchecked Sendable {
    final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { values } }
        func add(_ request: URLRequest) { lock.withLock { values.append(request) } }
        func clear() { lock.withLock { values.removeAll() } }
    }
    static let records = Records()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "images.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.records.add(request)
        let pixel = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        let unsafe = request.url?.path == "/not-image"
        let oversized = request.url?.path == "/oversized"
        let response = HTTPURLResponse(url:request.url!, statusCode:200, httpVersion:"HTTP/1.1", headerFields:["Content-Type":unsafe ? "text/html" : "image/png", "Content-Length":oversized ? String(4 * 1024 * 1024 + 1) : String(pixel.count)])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:pixel)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SyntheticImageTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private let lock = NSLock()
    private var ended = false, failed = false
    private var data = Data()
    var finished: Bool { lock.withLock { ended } }
    var rejected: Bool { lock.withLock { failed } }
    var bytes: Data { lock.withLock { data } }
    init(_ source: String) {
        var components = URLComponents(string:"protonx-image://asset")!
        components.queryItems = [URLQueryItem(name:"url",value:source)]
        request = URLRequest(url:components.url!)
    }
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ bytes: Data) { lock.withLock { data.append(bytes) } }
    func didFinish() { lock.withLock { ended = true } }
    func didFailWithError(_ error: any Error) { lock.withLock { failed = true } }
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
    @Test func imageOptInLoadsOnlyImagesAndNewMessageStartsBlocked() async throws {
        SyntheticImageProtocol.records.clear()
        let url = "https://images.example.invalid/synthetic"
        let html = """
        <img data-protonx-remote-src="\(url)/image" width="1" height="1">
        <img data-protonx-remote-src="file:///etc/passwd">
        <img data-protonx-remote-src="https://user:secret@example.invalid/image">
        <script>document.documentElement.dataset.executed='yes'; fetch('\(url)/fetch');</script>
        <script src="\(url)/script"></script><iframe src="\(url)/frame"></iframe>
        <link rel="stylesheet" href="\(url)/style"><style>@import url('\(url)/import');</style>
        """
        var height: CGFloat = 240
        var failed = false
        let parent = MailHTMLView(html: html, height: .init(get: { height }, set: { height = $0 }), failed: .init(get: { failed }, set: { failed = $0 }), openLink: { _ in }, allowsRemoteImages: true)
        let coordinator = MailHTMLView.Coordinator(parent)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let cookie = try #require(HTTPCookie(properties: [.domain:"images.example.invalid", .path:"/", .name:"synthetic", .value:"fixture"]))
        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [SyntheticImageProtocol.self]
        let loader = MailRemoteImages(configuration:transport)
        config.setURLSchemeHandler(loader, forURLScheme:MailRemoteImages.scheme)
        let view = MailPaperWebView(frame: NSRect(x:0,y:0,width:620,height:240), configuration:config)
        view.imageLoader = loader
        view.navigationDelegate = coordinator; view.uiDelegate = coordinator
        coordinator.configure(view)
        defer { MailHTMLView.dismantleNSView(view, coordinator:coordinator) }
        try await wait { (try await self.script(view, "document.querySelectorAll('img').length")) as? Int == 3 }
        try await wait { (try await self.script(view, "document.querySelector('img').naturalWidth")) as? Int == 1 }
        #expect(!failed)
        #expect(SyntheticImageProtocol.records.requests.count == 1)
        let request = try #require(SyntheticImageProtocol.records.requests.first)
        #expect(request.url?.path == "/synthetic/image")
        #expect(request.value(forHTTPHeaderField:"Cookie") == nil)
        #expect(request.value(forHTTPHeaderField:"Referer") == nil)
        #expect(try await script(view, "document.documentElement.dataset.executed === undefined") as? Bool == true)
        #expect(try await script(view, "document.querySelectorAll('img')[1].getAttribute('src') === null") as? Bool == true)
        #expect(try await script(view, "document.querySelectorAll('img')[2].getAttribute('src') === null") as? Bool == true)
        // A new view has no inherited opt-in even with the same remote address.
        let blocked = MailHTMLView(html:html, height:parent.$height, failed:parent.$failed, openLink:{ _ in })
        let blockedCoordinator = MailHTMLView.Coordinator(blocked)
        let blockedConfig = WKWebViewConfiguration()
        blockedConfig.websiteDataStore = .nonPersistent()
        blockedConfig.defaultWebpagePreferences.allowsContentJavaScript = false
        let nextView = MailPaperWebView(frame:view.frame, configuration:blockedConfig)
        nextView.navigationDelegate = blockedCoordinator
        blockedCoordinator.configure(nextView)
        defer { MailHTMLView.dismantleNSView(nextView, coordinator:blockedCoordinator) }
        try await wait { (try await self.script(nextView, "document.querySelectorAll('img').length")) as? Int == 3 }
        try await Task.sleep(for:.milliseconds(200))
        #expect(SyntheticImageProtocol.records.requests.count == 1)
        #expect(try await script(nextView, "document.querySelector('img').naturalWidth") as? Int == 0)
    }
    @Test func layoutTracksLateGrowthAndScrollingMovesTheOuterReader() async throws {
        var height: CGFloat = 240
        var failed = false
        let parent = MailHTMLView(html:"<p>Short synthetic message</p>", height:.init(get:{ height },set:{ height=$0 }), failed:.init(get:{ failed },set:{ failed=$0 }),openLink:{ _ in })
        let coordinator = MailHTMLView.Coordinator(parent)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = MailPaperWebView(frame:NSRect(x:0,y:0,width:620,height:240),configuration:config)
        view.navigationDelegate = coordinator
        coordinator.configure(view)
        defer { MailHTMLView.dismantleNSView(view,coordinator:coordinator) }
        try await wait { (try await self.script(view,"document.querySelector('p').textContent")) as? String == "Short synthetic message" }
        _ = try await script(view,"const section=document.createElement('div'); section.style.height='2000px'; section.textContent='Synthetic bottom'; document.body.appendChild(section); undefined;")
        try await wait { height >= 2000 }
        #expect(!failed)
        #expect(!view.hasVerticalOverflow)
        final class FlippedDocument: NSView { override var isFlipped:Bool { true } }
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:620,height:300))
        scroll.hasVerticalScroller = true
        let document = FlippedDocument(frame:NSRect(x:0,y:0,width:620,height:height))
        scroll.documentView = document
        view.frame = document.bounds; document.addSubview(view)
        let window = NSWindow(contentRect:scroll.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        let wheel = try #require(CGEvent(scrollWheelEvent2Source:nil, units:.pixel, wheelCount:1, wheel1:-120, wheel2:0, wheel3:0))
        let event = try #require(NSEvent(cgEvent:wheel))
        #expect(view.forwardVerticalScroll(event))
        try await wait { scroll.contentView.bounds.origin.y > 0 }
        #expect(scroll.contentView.bounds.origin.y > 0)
        coordinator.applyHeight(70_000)
        #expect(height == MailReaderPolicy.maxHeight)
        #expect(view.hasVerticalOverflow)
        #expect(!view.forwardVerticalScroll(event))
        coordinator.active = false
        coordinator.applyHeight(400)
        #expect(height == MailReaderPolicy.maxHeight)
    }
    @Test func nativeImageTransportRejectsActiveOversizedAndCredentialResourcesAndCancelsOnClose() async throws {
        SyntheticImageProtocol.records.clear()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticImageProtocol.self]
        let loader = MailRemoteImages(configuration:configuration)
        let view = WKWebView(frame:.zero)
        defer { loader.invalidate() }
        for source in ["https://images.example.invalid/not-image", "https://images.example.invalid/oversized", "file:///etc/passwd", "https://synthetic:secret@images.example.invalid/image"] {
            let task = SyntheticImageTask(source)
            loader.webView(view,start:task)
            try await wait { task.rejected }
            #expect(!task.finished && task.bytes.isEmpty)
        }
        #expect(SyntheticImageProtocol.records.requests.count == 2)
        let pending = SyntheticImageTask("https://images.example.invalid/late")
        loader.webView(view,start:pending)
        loader.invalidate()
        try await Task.sleep(for:.milliseconds(100))
        #expect(!pending.finished && !pending.rejected && pending.bytes.isEmpty)
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
