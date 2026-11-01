// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The GPU executor that draws every window's picture (docs/gpu-live.md) links
// CabooseGPULive.xcframework: the live Vulkan decoder and MoltenVK, built and packaged by
// ../scripts/build-live-gpu.sh. It is a build product, not checked in; without it CabooseKit
// builds without the executor, and the app shows no window pictures.
let gpuLive = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/Frameworks/CabooseGPULive.xcframework/Info.plist")
let gpuDependencies: [Target.Dependency] = gpuLive
    ? [.target(name: "CabooseGPULive", condition: .when(platforms: [.iOS]))] : []
let gpuBinaryTargets: [Target] = gpuLive
    ? [.binaryTarget(name: "CabooseGPULive", path: "Frameworks/CabooseGPULive.xcframework")] : []

let gpuLiveLinking: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .linkedFramework("Foundation"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("IOSurface"),
    .linkedFramework("Metal"),
    .linkedFramework("QuartzCore"),
    // Phone-decoded video in GPU windows (docs/gpu-media.md).
    .linkedFramework("VideoToolbox"),
    .linkedFramework("CoreMedia"),
    .linkedFramework("CoreVideo"),
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
        // The zstd stream decoder for live GPU commands (docs/gpu-live.md): zstd 1.5.7's
        // single-file decompressor, built in through caboose_zstd.c.
        .target(name: "CabooseZstd", exclude: ["vendor"]),
        .target(
            name: "CabooseKit",
            dependencies: ["CabooseZstd"] + gpuDependencies,
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("z")] + (gpuLive ? gpuLiveLinking : [])),
        .testTarget(name: "CabooseKitTests", dependencies: ["CabooseKit"], exclude: ["Fixtures"]),
    ] + gpuBinaryTargets,
    swiftLanguageModes: [.v5]
)
