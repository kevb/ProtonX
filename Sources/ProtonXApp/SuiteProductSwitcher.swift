import SwiftUI
import ProtonXCore

private struct ActiveProductKey: FocusedValueKey { typealias Value = ProtonXCore.ProductRoute }
private struct ProductCanCreateKey: FocusedValueKey { typealias Value = Bool }
private struct ProductCanRefreshKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var protonXProduct: ProtonXCore.ProductRoute? { get { self[ActiveProductKey.self] } set { self[ActiveProductKey.self] = newValue } }
    var protonXCanCreate: Bool? { get { self[ProductCanCreateKey.self] } set { self[ProductCanCreateKey.self] = newValue } }
    var protonXCanRefresh: Bool? { get { self[ProductCanRefreshKey.self] } set { self[ProductCanRefreshKey.self] = newValue } }
}
