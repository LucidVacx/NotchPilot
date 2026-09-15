// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "NotchPilot",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "NotchPilot", targets: ["NotchPilot"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")
    ],
    targets: [
        .executableTarget(
            name: "NotchPilot",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(
            name: "HermesTerminalTests",
            dependencies: ["NotchPilot", .product(name: "SwiftTerm", package: "SwiftTerm")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
