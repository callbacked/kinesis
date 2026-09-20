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
    let poses: [(String, HandPose, SIMD3<Float>)] = [
        ("1-relaxed", .relaxed, .zero),
        ("2-pinch-index", .pinchIndex, [1, 1, 0]),
        ("3-pinch-middle", .pinchMiddle, [1, 0, 1]),
        ("4-swipe-left", .swipeLeft, [1, 1, 0]),
        ("5-swipe-right", .swipeRight, [1, 1, 0]),
        ("6-pinch-roll", HandPose.pinchIndex.with(roll: 45), [1, 1, 0]),
    ]
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
