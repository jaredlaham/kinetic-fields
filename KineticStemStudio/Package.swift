// swift-tools-version: 5.10
import PackageDescription

// StemCore is Foundation-only so it builds and tests on macOS and Linux.
// The SwiftUI / AVFoundation / CoreMIDI app target is macOS-only.
var products: [Product] = [
    .library(name: "StemCore", targets: ["StemCore"]),
]

var targets: [Target] = [
    .target(name: "StemCore", path: "Sources/StemCore"),
    .testTarget(name: "StemCoreTests", dependencies: ["StemCore"], path: "Tests/StemCoreTests"),
]

#if os(macOS)
products.append(.executable(name: "KineticStemStudio", targets: ["KineticStemStudio"]))
targets.append(
    .executableTarget(
        name: "KineticStemStudio",
        dependencies: ["StemCore"],
        path: "Sources/KineticStemStudio",
        exclude: ["Info.plist"],
        linkerSettings: [
            .linkedFramework("AVFoundation"),
            .linkedFramework("CoreMIDI"),
            .linkedFramework("AudioToolbox"),
        ]
    )
)
#endif

let package = Package(
    name: "KineticStemStudio",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
