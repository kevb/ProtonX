import AppKit
import AuthenticationServices
import ProtonXCore

/// The account page runs only during sign-in, in the system authentication UI.
/// The upstream SDK polls and decrypts the fork; no callback token enters the UI.
@MainActor
final class NativeWebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var requestID: UUID?
    func start(url: URL, onCancel: @escaping @MainActor () -> Void) throws {
        cancel()
        let id = UUID(); requestID = id
        let next = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in
                guard self?.requestID == id else { return }
                self?.requestID = nil; self?.session = nil
                onCancel()
            }
        }
        next.presentationContextProvider = self
        // Keep sign-in separate from browser accounts/cookies on this Mac.
        next.prefersEphemeralWebBrowserSession = true
        session = next
        guard next.start() else {
            cancel()
            throw ProtonXError.invalidInput("The macOS sign-in window could not open. Try again with the Pass window active.")
        }
    }
    func cancel() {
        requestID = nil
        let previous = session; session = nil
        previous?.cancel()
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
}
