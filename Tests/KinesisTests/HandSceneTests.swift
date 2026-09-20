import AppKit
import SceneKit
import Testing
import simd
import KinesisCore
@testable import Kinesis

@Suite(.serialized) struct HandSceneTests {
@Test(arguments: [HandViewpoint.overview, .teaching], [BandHand.right, .left])
@MainActor func withReduceMotionGesturesLightTheTipsAndTheHandStaysStill(viewpoint: HandViewpoint, side: BandHand) async throws {
    let coordinator = HandSceneView.Coordinator(viewpoint: viewpoint)
    coordinator.setHand(side)
    let renderer = SCNRenderer(device: nil, options: nil)
    renderer.scene = coordinator.scene
    renderer.pointOfView = coordinator.scene.rootNode.childNodes.first { $0.camera != nil }
    let hand = try #require(coordinator.scene.rootNode.childNode(withName: "hand", recursively: true))
    let vertices = try #require(hand.geometry?.sources(for: .vertex).first?.data)
    func render(_ highlight: HandHighlight, dark: Bool) async throws -> (Data, [SIMD3<Float>]) {
        coordinator.setBackground(dark: dark)
        coordinator.show(highlight, revision: dark ? 1 : 0, sustained: true, animated: false)
        await Task.yield()
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 512, height: 320), antialiasingMode: .multisampling4X)
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var pixels: [SIMD3<Float>] = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                pixels.append(SIMD3(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent)))
            }
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["KINESIS_RENDER_DIR"] {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("hand-\(side)-\(viewpoint)-\(highlight)-\(dark ? "dark" : "light").png"))
        }
        return (png, pixels)
    }
    for dark in [false, true] {
        let idle = try await render(.none, dark: dark)
        let index = try await render(.index, dark: dark)
        let middle = try await render(.middle, dark: dark)
        let changes = zip(idle.1, index.1).filter { simd_distance($0, $1) > 0.08 }.count
        #expect(changes > 80)
        #expect(changes < idle.1.count / 8)
        #expect(index.0 != middle.0)
        #expect(hand.geometry?.sources(for: .vertex).first?.data == vertices)
        // No motion was asked for, so the rig never left its resting pose.
        #expect(coordinator.rig?.pose == .relaxed)
    }
    coordinator.cancelAnimation()
}

@Test @MainActor func thePosesBringTheThumbToTheFingerTheyName() throws {
    let rig = try #require(HandSceneView.Coordinator().rig)
    func gap(_ finger: String) throws -> Float {
        simd_distance(try #require(rig.position(of: "thumb-tip")), try #require(rig.position(of: finger)))
    }
    rig.snap(to: .relaxed)
    #expect(try gap("index-finger-tip") > 1 && gap("middle-finger-tip") > 1)
    // A pad's width apart: the tips are joints inside the skin, so touching pads leave a small gap.
    rig.snap(to: .pinchIndex)
    #expect(try gap("index-finger-tip") < 0.4 && gap("middle-finger-tip") > 0.8)
    rig.snap(to: .pinchMiddle)
    #expect(try gap("middle-finger-tip") < 0.4 && gap("index-finger-tip") > 0.8)
    // The pinch the dial turns around is the pinch the rig makes.
    rig.snap(to: .pinchIndex)
    let index = try #require(rig.position(of: "index-finger-tip")), thumb = try #require(rig.position(of: "thumb-tip"))
    #expect(simd_distance((index + thumb) / 2, HandRig.pinchPoint) < 0.05)
    // A swipe slides the thumb along the index finger, from one end to the other.
    rig.snap(to: .swipeStart(.left))
    let start = try #require(rig.position(of: "thumb-tip"))
    rig.snap(to: .swipeEnd(.left))
    #expect(simd_distance(start, try #require(rig.position(of: "thumb-tip"))) > 0.35)
}

@Test @MainActor func aNewGestureBendsTheMotionInsteadOfCuttingIt() throws {
    let rig = try #require(HandSceneView.Coordinator().rig)
    // Stepped by hand at sixty frames a second, so the motion is exact and repeatable.
    rig.drivesItself = false
    rig.move(to: .pinchIndex)
    var last = rig.pose.vector
    var largestStep: Float = 0
    var frames = 0
    while frames < 240 {
        // A second gesture arrives while the first is still under way.
        if frames == 4 { rig.move(to: .swipeEnd(.left)) }
        let settled = rig.advance(by: 1.0 / 60)
        let now = rig.pose.vector
        largestStep = max(largestStep, zip(now, last).map { abs($0 - $1) }.max() ?? 0)
        last = now
        frames += 1
        if settled && frames > 4 { break }
    }
    // A cut to the new pose would cover its 60-odd degrees in one frame. The spring
    // never moves an angle more than a fraction of that, even when retargeted mid-flight.
    #expect(largestStep > 1 && largestStep < 18)
    // It arrives, and it does not take all day: well under half a second.
    #expect(rig.pose == .swipeEnd(.left) && frames < 30)
    // One long stalled frame must not throw the hand past its pose. From rest, every
    // angle stays between where it started and where it is going.
    let from = rig.pose.vector, goal = HandPose.relaxed.vector
    rig.move(to: .relaxed)
    rig.advance(by: 1.0 / 8)
    for (value, (start, end)) in zip(rig.pose.vector, zip(from, goal)) {
        #expect(value >= min(start, end) - 0.5 && value <= max(start, end) + 0.5)
    }
}

@Test @MainActor func aHeldPinchIsMirroredOnceAndSwipesReplay() async throws {
    let coordinator = HandSceneView.Coordinator()
    let rig = try #require(coordinator.rig)
    // The band reports the press: the hand pinches for as long as you do.
    coordinator.show(.middle, revision: 1, sustained: true, animated: true)
    #expect(rig.goal == .pinchMiddle)
    // The release and the recognized tap arrive together. The pinch already happened on screen.
    coordinator.show(.middle, gesture: .tap(.middleTap), revision: 2, sustained: false, animated: true)
    try await Task.sleep(for: .milliseconds(60))
    #expect(rig.goal == .relaxed)
    // A swipe has no live signal, so it is acted out from one end to the other.
    try await Task.sleep(for: .milliseconds(500))
    coordinator.show(.index, gesture: .swipe(.right), revision: 3, sustained: false, animated: true)
    try await Task.sleep(for: .milliseconds(60))
    #expect(rig.goal == .swipeStart(.right))
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.goal == .swipeEnd(.right))
    // The dial turns the held pinch.
    coordinator.show(.index, revision: 3, sustained: true, roll: 40, animated: true)
    #expect(rig.goal == HandPose.pinchIndex.with(roll: 40))
    coordinator.cancelAnimation()
}

@Test @MainActor func handGlowHoldsUntilReleaseAndNewInputCancelsOldFades() async throws {
    let coordinator = HandSceneView.Coordinator()
    coordinator.show(.index, revision: 1, sustained: false, animated: true)
    try await Task.sleep(for: .milliseconds(350))
    coordinator.show(.middle, revision: 2, sustained: true, animated: true)
    try await Task.sleep(for: .milliseconds(600))
    #expect(simd_distance(coordinator.illumination, SIMD3(1, 0, 1)) < 0.001)
    coordinator.show(.middle, revision: 2, sustained: false, animated: true)
    try await Task.sleep(for: .milliseconds(350))
    #expect(simd_length(coordinator.illumination) < 0.001)
}

}
