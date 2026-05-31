// swift-tools-version:5.9
// Pensieve — native macOS markdown editor (file-first, source-first)

import PackageDescription

let package = Package(
    name: "Pensieve",
    platforms: [
        .macOS(.v13)
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
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .copy("Resources/markdown.css"),
                .copy("Resources/gfm.css"),
                .copy("Resources/mermaid.min.js"),
                .copy("Resources/sample.md")
            ]
        ),
        .testTarget(
            name: "PensieveTests",
            dependencies: [
                "Pensieve",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
