// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CabooseMenu",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CabooseMenu", targets: ["CabooseMenu"])],
    targets: [.executableTarget(name: "CabooseMenu")]
)
