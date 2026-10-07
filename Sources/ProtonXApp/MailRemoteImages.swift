import Foundation
import WebKit

/// Per-message, memory-only image transport. WebKit cannot make arbitrary HTTP
/// requests; it receives bounded image bytes through this dedicated scheme.
@MainActor final class MailRemoteImages: NSObject, WKURLSchemeHandler {
    static let scheme = "protonx-image"
    private let session: URLSession
    private let budget = Budget()
    private var requests = 0
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var active = true
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        super.init()
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard active, requests < 64, let requestURL = urlSchemeTask.request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              components.host == "asset", components.path.isEmpty,
              components.queryItems?.count == 1,
              let item = components.queryItems?.first, item.name == "url",
              let value = item.value, value.utf8.count <= 8192,
              let url = URL(string: value), Self.allowed(url) else {
            urlSchemeTask.didFailWithError(Self.failure); return
        }
        requests += 1
        tasks[key] = Task { [weak self, session, budget] in
            do {
                let (data, mime) = try await Self.download(url, session: session, budget: budget)
                guard let self, self.active, !Task.isCancelled, self.tasks.removeValue(forKey:key) != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url:requestURL, mimeType:mime, expectedContentLength:data.count, textEncodingName:nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard let self, self.active, !Task.isCancelled, self.tasks.removeValue(forKey:key) != nil else { return }
                urlSchemeTask.didFailWithError(Self.failure)
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey:ObjectIdentifier(urlSchemeTask))?.cancel()
    }
    func invalidate() {
        active = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); session.invalidateAndCancel()
    }
    private nonisolated static var failure: NSError { NSError(domain:"ProtonX.Mail.Images", code:1) }
    nonisolated static func allowed(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
    private actor Budget {
        var remaining = 16 * 1024 * 1024
        func consume(_ count: Int) throws {
            guard count <= remaining else { throw MailRemoteImages.failure }
            remaining -= count
        }
    }
    private nonisolated static func download(_ url: URL, session: URLSession, budget: Budget) async throws -> (Data, String) {
        var request = URLRequest(url:url)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for:request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let mime = response.mimeType?.lowercased(),
              ["image/png","image/jpeg","image/gif","image/webp","image/avif","image/heic"].contains(mime),
              response.expectedContentLength <= 4 * 1024 * 1024 else { throw failure }
        var data = Data(), pending = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4 * 1024 * 1024 else { throw failure }
            if pending == 0 { try await budget.consume(64 * 1024); pending = 64 * 1024 }
            data.append(byte); pending -= 1
        }
        return (data, mime)
    }
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, MailRemoteImages.allowed(url),
                  response.url?.scheme != "https" || url.scheme == "https" else { completionHandler(nil); return }
            var clean = URLRequest(url:url); clean.httpShouldHandleCookies = false
            completionHandler(clean)
        }
    }
}
