// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kinesis",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Kinesis", targets: ["Kinesis"])],
    targets: [
        .target(name: "KinesisCore"),
        // The practice lab builds into debug builds, so tests keep it compiling, and into
        // release builds only with KINESIS_LAB=1 ./scripts/build.sh.
        .executableTarget(name: "Kinesis", dependencies: ["KinesisCore"], resources: [.process("Resources")],
                          swiftSettings: [.define("KINESIS_LAB", .when(configuration: .debug))]),
        .testTarget(name: "KinesisCoreTests", dependencies: ["KinesisCore"]),
        .testTarget(name: "KinesisTests", dependencies: ["Kinesis", "KinesisCore"]),
    ]
)
