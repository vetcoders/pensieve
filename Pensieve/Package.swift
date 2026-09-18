// swift-tools-version:6.2
// Pensieve — native macOS markdown editor (file-first, source-first)

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let qubeFFIProfile =
    ProcessInfo.processInfo.environment["FFI_PROFILE"] == "release" ? "release" : "debug"
let qubeFFILibraryPath = "\(packageRoot)/Vendor/qube-ffi/\(qubeFFIProfile)"
let codescribeFFILibraryPath = "\(packageRoot)/Vendor/codescribe-ffi/\(qubeFFIProfile)"

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
            resources: [
                .copy("Resources/markdown.css"),
                .copy("Resources/gfm.css"),
                .copy("Resources/mermaid.min.js"),
                .copy("Resources/katex.min.js"),
                .copy("Resources/katex.inline.min.css"),
                // Bundled OFL theme fonts (family→files manifest in
                // BundledFonts.swift). `.copy` preserves the per-family
                // directory tree verbatim — including each family's OFL.txt
                // license next to its faces — so the runtime registrar can walk
                // it and CoreText reads genuine TrueType data. `.process` would
                // flatten/rename and is meant for image/localized assets.
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
            path: "Sources/qube_ffiFFI"
        ),
        .systemLibrary(
            name: "codescribe_ffiFFI",
            path: "Sources/codescribe_ffiFFI"
        ),
        // Vendored UniFFI bindings for the codescribe engine (hotkeys facade,
        // transcription listener, agent streaming). Kept in a dedicated module
        // because two uniffi-generated files in one module redeclare the same
        // public free functions (startRecording, transcribeFile, ...).
        .target(
            name: "CodescribeBridge",
            dependencies: ["codescribe_ffiFFI"],
            path: "Sources/CodescribeBridge",
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
