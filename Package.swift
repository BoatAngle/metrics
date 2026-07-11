// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Metrics",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SMCCore",
            path: "Sources/SMCCore"
        ),
        .target(
            name: "WidgetShared",
            path: "Sources/WidgetShared"
        ),
        .executableTarget(
            name: "Metrics",
            dependencies: ["SMCCore", "WidgetShared"],
            path: "Sources/Metrics",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("WidgetKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "MetricsWidgets",
            dependencies: ["WidgetShared"],
            path: "Sources/MetricsWidgets",
            linkerSettings: [
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "MetricsFanHelper",
            dependencies: ["SMCCore"],
            path: "Sources/MetricsFanHelper",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
