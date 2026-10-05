// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ProtonX",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ProtonXCore", targets: ["ProtonXCore"]),
               .executable(name: "ProtonX", targets: ["ProtonXApp"])],
    targets: [.target(name: "CBridgeTransport", linkerSettings: [.linkedLibrary("curl")]),
              .target(name: "ProtonXCore", dependencies: ["CBridgeTransport"]),
              .executableTarget(name: "ProtonXApp", dependencies: ["ProtonXCore"]),
              .testTarget(name: "ProtonXCoreTests", dependencies: ["ProtonXCore"], resources: [.copy("Fixtures")])],
    swiftLanguageModes: [.v6]
)
