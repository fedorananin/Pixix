// swift-tools-version: 6.2
import Foundation
import PackageDescription

// With only the Command Line Tools installed, the Swift Testing macro plugin is not always passed to the
// compiler, so name it explicitly. With Xcode the plugin is found on its own and this folder is not needed.
let commandLineToolsPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testingPlugin: [SwiftSetting] = FileManager.default.fileExists(atPath: commandLineToolsPlugins)
    ? [.unsafeFlags(["-plugin-path", commandLineToolsPlugins])]
    : []

let package = Package(
    name: "Pixix",
    platforms: [.macOS(.v26)],
    targets: [
        // Vendored libwebp 1.6.0. Used only to write WebP; reading goes through ImageIO.
        .target(
            name: "CWebP",
            path: "Sources/CWebP",
            exclude: ["licenses"],
            sources: ["libwebp"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("libwebp"),
                .define("NDEBUG"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(name: "PixixCodec", dependencies: ["CWebP"]),
        .target(name: "PixixEngine", dependencies: ["PixixCodec"]),
        .executableTarget(name: "Pixix", dependencies: ["PixixCodec", "PixixEngine"]),
        .testTarget(name: "PixixCodecTests", dependencies: ["PixixCodec"], swiftSettings: testingPlugin),
        .testTarget(name: "PixixEngineTests", dependencies: ["PixixEngine", "PixixCodec"], swiftSettings: testingPlugin),
    ]
)
