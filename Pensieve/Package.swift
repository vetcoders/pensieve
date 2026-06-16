// swift-tools-version:6.0
// Pensieve — native macOS markdown editor (file-first, source-first)

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let qubeFFIProfile =
    ProcessInfo.processInfo.environment["FFI_PROFILE"] == "release" ? "release" : "debug"
let qubeFFILibraryPath = "\(packageRoot)/Vendor/qube-ffi/\(qubeFFIProfile)"

let package = Package(
    name: "Pensieve",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Pensieve", targets: ["Pensieve"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown", from: "0.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Pensieve",
            dependencies: [
                "qube_ffiFFI",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .copy("Resources/markdown.css"),
                .copy("Resources/gfm.css"),
                .copy("Resources/mermaid.min.js"),
                .copy("Resources/katex.min.js"),
                .copy("Resources/katex.inline.min.css"),
                .copy("Resources/sample.md")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", qubeFFILibraryPath,
                    "-lqube_ffi",
                    "-Xlinker", "-rpath",
                    "-Xlinker", qubeFFILibraryPath
                ])
            ]
        ),
        .systemLibrary(
            name: "qube_ffiFFI",
            path: "Sources/qube_ffiFFI"
        ),
        .testTarget(
            name: "PensieveTests",
            dependencies: [
                "Pensieve",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ],
    // Tools bumped to 6.0 for the macOS 15 target (Observation needs >= 14).
    // Pin Swift 5 language mode: this is NOT a Swift 6 strict-concurrency
    // migration — that would be a separate, much larger change.
    swiftLanguageModes: [.v5]
)
