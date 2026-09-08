// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notchly",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Notchly", targets: ["Notchly"])],
    dependencies: [.package(path: "Vendor/MediaRemoteAdapter")],
    targets: [
        .executableTarget(
            name: "Notchly",
            dependencies: [.product(name: "MediaRemoteAdapter", package: "MediaRemoteAdapter")]
        )
    ]
)
