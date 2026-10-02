// swift-tools-version:6.2
// Discovery manifest for `swift test` run from the repository root.
// SwiftPM does not descend into Pensieve/, where the canonical package lives.
// Paths mirror Pensieve/Package.swift. Keep the two manifests in step.

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let qubeFFIProfile =
    ProcessInfo.processInfo.environment["FFI_PROFILE"] == "release" ? "release" : "debug"
let qubeFFILibraryPath = "\(packageRoot)/Pensieve/Vendor/qube-ffi/\(qubeFFIProfile)"
let codescribeFFILibraryPath = "\(packageRoot)/Pensieve/Vendor/codescribe-ffi/\(qubeFFIProfile)"

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
                "CodescribeBridge",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Pensieve/Sources/Pensieve",
            resources: [
                .copy("Resources/markdown.css"),
                .copy("Resources/gfm.css"),
                .copy("Resources/mermaid.min.js"),
                .copy("Resources/katex.min.js"),
                .copy("Resources/katex.inline.min.css"),
                .copy("Resources/Fonts")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", qubeFFILibraryPath,
                    "-lqube_ffi",
                    "-Xlinker", "-rpath",
                    "-Xlinker", qubeFFILibraryPath,
                    "-L", codescribeFFILibraryPath,
                    "-lcodescribe_ffi",
                    "-Xlinker", "-rpath",
                    "-Xlinker", codescribeFFILibraryPath
                ])
            ]
        ),
        .systemLibrary(
            name: "qube_ffiFFI",
            path: "Pensieve/Sources/qube_ffiFFI"
        ),
        .systemLibrary(
            name: "codescribe_ffiFFI",
            path: "Pensieve/Sources/codescribe_ffiFFI"
        ),
        .target(
            name: "CodescribeBridge",
            dependencies: ["codescribe_ffiFFI"],
            path: "Pensieve/Sources/CodescribeBridge",
            linkerSettings: [
                .unsafeFlags([
                    "-L", codescribeFFILibraryPath,
                    "-lcodescribe_ffi",
                    "-Xlinker", "-rpath",
                    "-Xlinker", codescribeFFILibraryPath
                ])
            ]
        ),
        .testTarget(
            name: "PensieveTests",
            dependencies: [
                "Pensieve",
                "CodescribeBridge",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Pensieve/Tests/PensieveTests",
            linkerSettings: [
                .unsafeFlags([
                    "-L", codescribeFFILibraryPath,
                    "-lcodescribe_ffi",
                    "-Xlinker", "-rpath",
                    "-Xlinker", codescribeFFILibraryPath
                ])
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
