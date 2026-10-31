// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The GPU stream player (GPUStreamPlayer, GPUStreamView) links CabooseGPUStream.xcframework:
// GFXReconstruct's Vulkan replay and MoltenVK, built by ../scripts/build-gpu-stream.sh. It is
// a build product, not checked in; without it CabooseKit builds without the player.
let gpuStream = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/Frameworks/CabooseGPUStream.xcframework/Info.plist")
let gpuLive = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/Frameworks/CabooseGPULive.xcframework/Info.plist")
// Both archives contain their own Vulkan provider. Never resolve calls against
// one provider while executing them through another.
if gpuStream && gpuLive {
    fatalError("Choose CabooseGPULive or CabooseGPUStream; both Vulkan providers cannot be linked together")
}
let gpuDependencies: [Target.Dependency] = gpuLive
    ? [.target(name: "CabooseGPULive", condition: .when(platforms: [.iOS]))]
    : (gpuStream ? [.target(name: "CabooseGPUStream")] : [])
let gpuBinaryTargets: [Target] = gpuLive
    ? [.binaryTarget(name: "CabooseGPULive", path: "Frameworks/CabooseGPULive.xcframework")]
    : (gpuStream ? [.binaryTarget(name: "CabooseGPUStream", path: "Frameworks/CabooseGPUStream.xcframework")] : [])

let gpuStreamLinking: [LinkerSetting] = [
    .linkedLibrary("c++"),
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
            dependencies: gpuDependencies,
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("z")] + (gpuStream || gpuLive ? gpuStreamLinking : [])),
        .testTarget(name: "CabooseKitTests", dependencies: ["CabooseKit"], exclude: ["Fixtures"]),
    ] + gpuBinaryTargets,
    swiftLanguageModes: [.v5]
)
