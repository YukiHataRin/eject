// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Eject",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Eject",
            path: "Sources/Eject",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
