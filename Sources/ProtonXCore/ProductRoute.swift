import Foundation

/// Public launch links only choose a window. They cannot carry account/session data.
public enum ProductRoute: String, Sendable {
    case pass, mail, calendar
    public var displayName: String { switch self { case .pass: "Pass"; case .mail: "Mail"; case .calendar: "Calendar" } }
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "protonx", let host = url.host,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil,
              let product = Self(rawValue: host.lowercased()) else { return nil }
        self = product
    }
}
