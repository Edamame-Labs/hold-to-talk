// swift-tools-version: 6.0
import Foundation
import PackageDescription

let isAppStoreBuild = ProcessInfo.processInfo.environment["APP_STORE"] == "1"

var packageDependencies: [Package.Dependency] = [
]

if !isAppStoreBuild {
    packageDependencies.append(
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0")
    )
}

var executableDependencies: [Target.Dependency] = ["sherpa_onnx", "llama"]

if !isAppStoreBuild {
    executableDependencies.append("Sparkle")
}

let package = Package(
    name: "HoldToTalk",
    platforms: [.macOS(.v15)],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "HoldToTalk",
            dependencies: executableDependencies,
            path: "Sources/HoldToTalk",
            resources: [
                .copy("Resources/silero_vad.onnx"),
            ],
            cSettings: [
                .headerSearchPath("../../Frameworks/sherpa_onnx.xcframework/macos-arm64_x86_64/Headers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TranscribeCmd",
            dependencies: ["sherpa_onnx"],
            path: "Sources/TranscribeCmd",
            cSettings: [
                .headerSearchPath("../../Frameworks/sherpa_onnx.xcframework/macos-arm64_x86_64/Headers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .binaryTarget(
            name: "sherpa_onnx",
            path: "Frameworks/sherpa_onnx.xcframework"
        ),
        .binaryTarget(
            name: "llama",
            path: "Frameworks/llama.xcframework"
        ),
        .testTarget(
            name: "HoldToTalkTests",
            dependencies: ["HoldToTalk"],
            path: "Tests/HoldToTalkTests"
        ),
    ]
)
