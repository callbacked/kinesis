import AppKit
import SceneKit
import Testing
import simd
import KinesisCore
@testable import Kinesis

@Suite(.serialized) struct HandSceneTests {
@Test(arguments: [HandViewpoint.overview, .teaching], [BandHand.right, .left])
@MainActor func gesturesLightTheTipsWithoutMovingTheHand(viewpoint: HandViewpoint, side: BandHand) async throws {
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
    }
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
