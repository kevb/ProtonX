// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ProtonX",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ProtonXCore", targets: ["ProtonXCore"]),
               .executable(name: "ProtonX", targets: ["ProtonXApp"]),
               .executable(name: "ProtonXValidation", targets: ["ProtonXValidation"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.1")],
    targets: [.target(name: "CBridgeTransport", linkerSettings: [.linkedLibrary("curl")]),
              .target(name: "ProtonXCore", dependencies: ["CBridgeTransport"]),
              .executableTarget(name: "ProtonXApp", dependencies: ["ProtonXCore", .product(name: "SwiftSoup", package: "SwiftSoup")]),
              .executableTarget(name: "ProtonXValidation", dependencies: ["ProtonXCore"], path: "Tools/ProtonXValidation"),
              .testTarget(name: "ProtonXAppTests", dependencies: ["ProtonXApp", "ProtonXCore", .product(name: "SwiftSoup", package: "SwiftSoup")]),
              .testTarget(name: "ProtonXCoreTests", dependencies: ["ProtonXCore"], resources: [.copy("Fixtures")])],
    swiftLanguageModes: [.v6]
)
