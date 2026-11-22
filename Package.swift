// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Lumi",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Lumi", targets: ["Lumi"])
    ],
    targets: [
        .executableTarget(
            name: "Lumi",
            path: "Sources/Lumi",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "LumiTests",
            dependencies: ["Lumi"],
            path: "Tests/LumiTests"
        )
    ]
)
