// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CabooseKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CabooseKit", targets: ["CabooseKit"]),
    ],
    targets: [
        .target(name: "CabooseKit"),
        .testTarget(name: "CabooseKitTests", dependencies: ["CabooseKit"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
