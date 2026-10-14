// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumaDisplay",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LumaDisplay", targets: ["LumaDisplay"])],
    targets: [
        .target(name: "DisplayCore"),
        .executableTarget(name: "LumaDisplay", dependencies: ["DisplayCore"]),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"])
    ]
)
