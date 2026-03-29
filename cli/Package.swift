// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nothing-ctl",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "nothing-ctl",
            path: "Sources/nothing-ctl",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
            ]
        )
    ]
)
