// swift-tools-version:5.9
// VCNotes — native macOS markdown editor (file-first, source-first)

import PackageDescription

let package = Package(
    name: "VCNotes",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VCNotes", targets: ["VCNotes"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown", from: "0.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0")
    ],
    targets: [
        .executableTarget(
            name: "VCNotes",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .copy("Resources/markdown.css"),
                .copy("Resources/gfm.css"),
                .copy("Resources/sample.md")
            ]
        ),
        .testTarget(
            name: "VCNotesTests",
            dependencies: ["VCNotes"]
        )
    ]
)
