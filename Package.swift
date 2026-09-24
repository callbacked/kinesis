// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kinesis",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Kinesis", targets: ["Kinesis"])],
    targets: [
        .target(name: "KinesisCore"),
        // Dev builds add experiments and developer tools, such as the practice lab. Debug
        // builds are dev builds, so tests keep them compiling. Release builds are dev
        // builds only with ./scripts/build.sh --dev.
        .executableTarget(name: "Kinesis", dependencies: ["KinesisCore"], resources: [.process("Resources")],
                          swiftSettings: [.define("KINESIS_DEV", .when(configuration: .debug))]),
        .testTarget(name: "KinesisCoreTests", dependencies: ["KinesisCore"]),
        .testTarget(name: "KinesisTests", dependencies: ["Kinesis", "KinesisCore"]),
    ]
)
