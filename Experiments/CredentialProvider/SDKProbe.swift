import AppKit
import AuthenticationServices

/// Compile-only macOS 14 API probe. Not embedded, registered or enabled by ProtonX.
/// Every request is denied. No account storage, shared Keychain, identity publication or IPC.
@MainActor final class CredentialProviderProbe: ASCredentialProviderViewController {
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        let candidates = serviceIdentifiers.compactMap { service -> OriginCandidate? in
            switch service.type {
            case .URL: return OriginCandidate(url: service.identifier)
            case .domain: return OriginCandidate(domain: service.identifier)
            default: return nil // Includes app identifiers on newer SDKs; not website origins.
            }
        }
        // Proves the system request can reach a native controller. Production must
        // bind a chosen item to an authenticated, unlocked broker before disclosure.
        _ = candidates
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue))
    }
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue))
    }
}
