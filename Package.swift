// swift-tools-version:5.10
//
// Prism — Studio Lighting for macOS
//
// Targets
//  - PrismCore   : platform-independent engine (models, color science, DMX rendering,
//                  effects, music analysis, command language, remote protocol, persistence).
//                  Builds and tests on Linux and macOS.
//  - PrismServer : embedded HTTP + WebSocket server for the phone/web remote (SwiftNIO).
//                  Builds and tests on Linux and macOS.
//  - PrismDevServer : headless executable that runs the engine + remote server with a
//                  simulated rig. Used to develop/test the web remote on Linux/CI.
//  - PrismApp    : the macOS SwiftUI application (macOS only).
//
import PackageDescription
import Foundation

// Set PRISM_CORE_ONLY=1 to build/test just PrismCore (no swift-nio). Used by agents on the
// low-resource Linux dev VM (`scripts/core-test.sh`); CI always builds everything.
let coreOnly = ProcessInfo.processInfo.environment["PRISM_CORE_ONLY"] == "1"

var products: [Product] = [
    .library(name: "PrismCore", targets: ["PrismCore"]),
]

var targets: [Target] = [
    .target(
        name: "PrismCore",
        path: "Sources/PrismCore"
    ),
    .testTarget(
        name: "PrismCoreTests",
        dependencies: ["PrismCore"],
        path: "Tests/PrismCoreTests"
    ),
]

var dependencies: [Package.Dependency] = []

if !coreOnly {
    dependencies.append(.package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"))
    products += [
        .library(name: "PrismServer", targets: ["PrismServer"]),
        .executable(name: "PrismDevServer", targets: ["PrismDevServer"]),
    ]
    targets += [
        .target(
            name: "PrismServer",
            dependencies: [
                "PrismCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: "Sources/PrismServer"
        ),
        .executableTarget(
            name: "PrismDevServer",
            dependencies: ["PrismCore", "PrismServer"],
            path: "Sources/PrismDevServer"
        ),
        .testTarget(
            name: "PrismServerTests",
            dependencies: ["PrismServer", "PrismCore"],
            path: "Tests/PrismServerTests"
        ),
    ]
}

#if os(macOS)
if !coreOnly {
products.append(.executable(name: "Prism", targets: ["PrismApp"]))
targets.append(
    .executableTarget(
        name: "PrismApp",
        dependencies: ["PrismCore", "PrismServer"],
        path: "Sources/PrismApp",
        linkerSettings: [
            .linkedFramework("IOKit"),
            .linkedFramework("CoreMIDI"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("CoreAudio"),
            .linkedFramework("Speech"),
        ]
    )
)
targets.append(
    .testTarget(
        name: "PrismAppTests",
        dependencies: ["PrismApp", "PrismCore"],
        path: "Tests/PrismAppTests"
    )
)
}
#endif

let package = Package(
    name: "Prism",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
