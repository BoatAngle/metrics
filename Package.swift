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
                // Carbon RegisterEventHotKey for the global hotkey (feature #46).
                .linkedFramework("Carbon"),
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
        // Tiny Foundation-only CLI companion (Package 9). Talks to the app's
        // control socket; no SwiftUI, no shared code.
        .executableTarget(
            name: "metricsctl",
            path: "Sources/metricsctl"
        ),
    ]
)
