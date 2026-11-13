// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Catchword",
    platforms: [.macOS("12.0")],
    products: [
        .executable(name: "Catchword", targets: ["Catchword"])
    ],
    targets: [
        .executableTarget(
            name: "Catchword",
            path: "Sources/Catchword",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Translation"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
