// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The GPU stream player (GPUStreamPlayer, GPUStreamView) links CabooseGPUStream.xcframework:
// GFXReconstruct's Vulkan replay and MoltenVK, built by ../scripts/build-gpu-stream.sh. It is
// a build product, not checked in; without it CabooseKit builds without the player.
let gpuStream = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/Frameworks/CabooseGPUStream.xcframework/Info.plist")

let gpuStreamLinking: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .linkedLibrary("z"),
    .linkedFramework("Foundation"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("IOSurface"),
    .linkedFramework("Metal"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("UIKit", .when(platforms: [.iOS])),
    .linkedFramework("AppKit", .when(platforms: [.macOS])),
    .linkedFramework("IOKit", .when(platforms: [.macOS])),
]

let package = Package(
    name: "CabooseKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CabooseKit", targets: ["CabooseKit"]),
    ],
    targets: [
        .target(
            name: "CabooseKit",
            dependencies: gpuStream ? ["CabooseGPUStream"] : [],
            linkerSettings: gpuStream ? gpuStreamLinking : []),
        .testTarget(name: "CabooseKitTests", dependencies: ["CabooseKit"], exclude: ["Fixtures"]),
    ] + (gpuStream ? [.binaryTarget(name: "CabooseGPUStream", path: "Frameworks/CabooseGPUStream.xcframework")] : []),
    swiftLanguageModes: [.v5]
)
