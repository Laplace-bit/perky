// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Perky",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perky", targets: ["Perky"]),
        .executable(name: "PerkyLidHelper", targets: ["PerkyHelper"])
    ],
    targets: [
        .target(
            name: "PerkyHelperShared",
            path: "Sources/PerkyHelperShared"
        ),
        .executableTarget(
            name: "Perky",
            dependencies: ["PerkyHelperShared"],
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
        .testTarget(
            name: "PerkyTests",
            dependencies: ["Perky"],
            path: "Tests/PerkyTests"
        )
    ]
)
