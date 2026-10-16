// swift-tools-version: 6.0
import PackageDescription

// T8Core is pure Foundation so it builds and tests on macOS and Linux.
// The SwiftUI / CoreMIDI / AVAudioEngine application target is macOS-only.
var products: [Product] = [
    .library(name: "T8Core", targets: ["T8Core"]),
    .executable(name: "t8studio", targets: ["t8studio"]),
]

var targets: [Target] = [
    .target(
        name: "T8Core",
        path: "Sources/T8Core"
    ),
    .executableTarget(
        name: "t8studio",
        dependencies: ["T8Core"],
        path: "Sources/t8studio"
    ),
    .testTarget(
        name: "T8CoreTests",
        dependencies: ["T8Core"],
        path: "Tests/T8CoreTests",
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products.append(.executable(name: "T8PatternStudio", targets: ["T8PatternStudio"]))
targets.append(
    .executableTarget(
        name: "T8PatternStudio",
        dependencies: ["T8Core"],
        path: "Sources/T8PatternStudio",
        exclude: ["Info.plist"],
        linkerSettings: [
            .linkedFramework("CoreMIDI"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("Security"),
        ]
    )
)
#endif

let package = Package(
    name: "T8PatternStudio",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
