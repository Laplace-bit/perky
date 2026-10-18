// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Perky",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perky", targets: ["Perky"]),
        .executable(name: "PerkyLidHelper", targets: ["PerkyHelper"]),
        .executable(name: "PerkyFeatureChecks", targets: ["PerkyFeatureChecks"])
    ],
    targets: [
        .target(
            name: "PerkyCore",
            path: "Sources/PerkyCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .target(
            name: "PerkyHelperShared",
            path: "Sources/PerkyHelperShared"
        ),
        .executableTarget(
            name: "Perky",
            dependencies: ["PerkyCore", "PerkyHelperShared"],
            path: "Sources/Perky",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "PerkyHelper",
            dependencies: ["PerkyHelperShared"],
            path: "Sources/PerkyHelper",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "PerkyFeatureChecks",
            dependencies: ["PerkyCore"],
            path: "Tests/PerkyFeatureChecks",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
