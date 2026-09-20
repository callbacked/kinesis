import AppKit
import Metal
import SceneKit
import Testing
import KinesisCore
@testable import Kinesis

/// Renders the rigged hand in each pose with SceneKit's offscreen renderer. It
/// runs only when KINESIS_RENDER_DIR names a directory.
@Test @MainActor func handPosesRenderForReview() throws {
    guard let directory = ProcessInfo.processInfo.environment["KINESIS_RENDER_DIR"] else { return }
    let coordinator = HandSceneView.Coordinator(viewpoint: .overview)
    let rig = try #require(coordinator.rig)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = coordinator.scene
    renderer.pointOfView = coordinator.camera
    var poses: [(String, HandPose, SIMD3<Float>)] = [
        ("1-relaxed", .relaxed, .zero),
        ("2-pinch-index", .pinchIndex, [1, 1, 0]),
        ("3-pinch-middle", .pinchMiddle, [1, 0, 1]),
        ("4-swipe-left", .swipeLeft, [1, 1, 0]),
        ("5-swipe-right", .swipeRight, [1, 1, 0]),
        ("7-swipe-up", .swipeUp, [1, 1, 0]),
        ("8-swipe-down", .swipeDown, [1, 1, 0]),
        ("6-pinch-roll", HandPose.pinchIndex.with(roll: 45), [1, 1, 0]),
    ]
    // Candidate poses come from a file while they are being solved: name to pose vector.
    if let file = ProcessInfo.processInfo.environment["KINESIS_POSE_FILE"] {
        let candidates = try JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        poses = candidates.sorted { $0.key < $1.key }.map { ($0.key, HandPose(vector: $0.value), [1, 1, 0]) }
    }
    for dark in [false, true] {
        coordinator.setBackground(dark: dark)
        for (name, pose, light) in poses {
            rig.snap(to: pose)
            coordinator.setIllumination(light)
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 520, height: 520), antialiasingMode: .multisampling4X)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("hand-\(dark ? "dark" : "light")-\(name).png"))
        }
    }
}

/// Renders each swipe frame by frame, at full speed and slowed down, for a review video.
/// The rig is stepped by hand, so the frames are exact. It runs only when
/// KINESIS_MOTION_DIR names a directory.
@Test @MainActor func handSwipesRenderAsFrames() throws {
    guard let directory = ProcessInfo.processInfo.environment["KINESIS_MOTION_DIR"] else { return }
    let coordinator = HandSceneView.Coordinator(viewpoint: .overview)
    let rig = try #require(coordinator.rig)
    rig.drivesItself = false
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = coordinator.scene
    renderer.pointOfView = coordinator.camera
    coordinator.setBackground(dark: ProcessInfo.processInfo.environment["KINESIS_MOTION_DARK"] != nil)
    let swipes: [(String, SwipeDirection)] = [("1-up", .up), ("2-down", .down), ("3-left", .left), ("4-right", .right)]
    for (name, direction) in swipes {
        for slowdown in [1, 4] {
            rig.snap(to: .relaxed)
            var frame = 0
            let keys = [(pose: HandPose.relaxed, hold: 250)] + HandPose.swipeKeys(direction) + [(pose: HandPose.relaxed, hold: 500)]
            for (step, key) in keys.enumerated() {
                rig.move(to: key.pose)
                let frames = key.hold * 60 * slowdown / 1000
                for tick in 0..<frames {
                    rig.advance(by: 1.0 / 60 / Float(slowdown))
                    let acting = step > 0 && step < keys.count - 1
                    let fade = step == 0 ? 0 : max(0, 1 - Float(tick) / Float(frames) * 2)
                    coordinator.setIllumination(SIMD3(1, 1, 0) * (acting ? 1 : fade))
                    let image = renderer.snapshot(atTime: 0, with: CGSize(width: 520, height: 520), antialiasingMode: .multisampling4X)
                    let tiff = try #require(image.tiffRepresentation)
                    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                    let file = "swipe-\(name)-\(slowdown)x-\(String(format: "%04d", frame)).png"
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
                    frame += 1
                }
            }
        }
    }
}
