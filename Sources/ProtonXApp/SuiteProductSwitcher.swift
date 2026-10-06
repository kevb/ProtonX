import SwiftUI
import ProtonXCore

/// Opening a product activates its existing window; sessions remain independent.
struct SuiteProductSwitcher: View {
    let current: String
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Menu {
            Button { show("pass") } label: { Label("ProtonX Pass", systemImage: current == "pass" ? "checkmark" : "key") }
            Button { show("mail") } label: { Label("ProtonX Mail", systemImage: current == "mail" ? "checkmark" : "envelope") }
        } label: {
            Label("ProtonX", systemImage: "square.grid.2x2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Open Pass or Mail · ⌘1 / ⌘2")
        .accessibilityLabel("Switch ProtonX product")
        .accessibilityIdentifier("productSwitcher")
    }
    private func show(_ product: String) { openWindow(id: product); NSApp.activate(ignoringOtherApps: true) }
}

private struct ActiveProductKey: FocusedValueKey { typealias Value = ProtonXCore.ProductRoute }
private struct ProductCanCreateKey: FocusedValueKey { typealias Value = Bool }
private struct ProductCanRefreshKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var protonXProduct: ProtonXCore.ProductRoute? { get { self[ActiveProductKey.self] } set { self[ActiveProductKey.self] = newValue } }
    var protonXCanCreate: Bool? { get { self[ProductCanCreateKey.self] } set { self[ProductCanCreateKey.self] = newValue } }
    var protonXCanRefresh: Bool? { get { self[ProductCanRefreshKey.self] } set { self[ProductCanRefreshKey.self] = newValue } }
}
