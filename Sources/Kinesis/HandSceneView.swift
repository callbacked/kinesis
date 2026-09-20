import SceneKit
import SwiftUI
import simd
import KinesisCore

enum HandHighlight: Sendable {
    case none, index, middle

    var tips: SIMD3<Float> {
        switch self {
        case .none: .zero
        case .index: SIMD3(1, 1, 0)
        case .middle: SIMD3(1, 0, 1)
        }
    }
}

enum HandViewpoint: Sendable {
    case overview, teaching
}

struct HandSceneView: NSViewRepresentable {
    var hand = BandHand.right
    var highlight = HandHighlight.none
    var revision = 0
    var sustained = false
    var viewpoint = HandViewpoint.overview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(viewpoint: viewpoint) }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.setBackground(dark: colorScheme == .dark)
        context.coordinator.setHand(hand)
        context.coordinator.show(highlight, revision: revision, sustained: sustained, animated: !reduceMotion)
    }

    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.cancelAnimation()
    }

    @MainActor final class Coordinator {
        let scene = SCNScene()
        private let material = SCNMaterial()
        private let handRoot = SCNNode()
        private var highlight: HandHighlight?
        private var revision = -1
        private var sustained = false
        private var animation: Task<Void, Never>?
        private(set) var illumination = SIMD3<Float>.zero

        init(viewpoint: HandViewpoint = .overview) {
            setBackground(dark: false)
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true
            camera.camera?.orthographicScale = viewpoint == .teaching ? 2.05 : 1.9
            camera.position = SCNVector3(0, 0, 10)
            scene.rootNode.addChildNode(camera)

            do {
                let mesh = try HandMesh.load()
                let hand = SCNNode(geometry: mesh.geometry())
                hand.name = "hand"
                material.lightingModel = .constant
                material.transparencyMode = .singleLayer
                material.shaderModifiers = [.geometry: """
                    #pragma varyings
                    float3 tipInfluence;
                    #pragma body
                    out.tipInfluence = _geometry.color.rgb;
                    """, .surface: """
                    #pragma arguments
                    float thumbLight;
                    float indexLight;
                    float middleLight;
                    float darkAppearance;
                    #pragma transparent
                    #pragma body
                    float alongHand = _surface.diffuseTexcoord.y;
                    float fade = smoothstep(0.02, 0.48, alongHand);
                    float rim = pow(1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view))), 2.0);
                    float shade = 0.48 + 0.52 * max(0.0, dot(normalize(_surface.normal), normalize(float3(-0.4, 0.6, 1.0))));
                    float glow = max(in.tipInfluence.x * thumbLight, max(in.tipInfluence.y * indexLight, in.tipInfluence.z * middleLight));
                    float3 blue = mix(float3(0.62, 0.83, 0.96), float3(0.34, 0.64, 0.84), smoothstep(0.1, 0.95, alongHand));
                    float3 lit = mix(float3(0.02, 0.44, 0.95), float3(0.32, 0.80, 1.0), darkAppearance);
                    _surface.diffuse.rgb = mix(blue * shade, lit, glow);
                    _surface.diffuse.a = fade * mix(0.64 + 0.14 * rim, 1.0, glow);
                    """, .fragment: """
                    #pragma transparent
                    #pragma body
                    _output.color = float4(_surface.diffuse.rgb * _surface.diffuse.a, _surface.diffuse.a);
                    """]
                setIllumination(.zero)
                hand.geometry?.materials = [material]
                // Palm toward the viewer, with every fingertip exposed.
                hand.eulerAngles = SCNVector3(0, Double.pi, Double.pi / 2 + 0.08)
                let bounds = hand.boundingBox
                hand.pivot = SCNMatrix4MakeTranslation(
                    (bounds.min.x + bounds.max.x) / 2,
                    (bounds.min.y + bounds.max.y) / 2,
                    (bounds.min.z + bounds.max.z) / 2)
                hand.position = SCNVector3(0.18, 0.22, 0)
                handRoot.addChildNode(hand)
                scene.rootNode.addChildNode(handRoot)
            } catch {
                let text = SCNText(string: "illustration unavailable", extrusionDepth: 0)
                text.font = .systemFont(ofSize: 0.18)
                text.firstMaterial?.diffuse.contents = NSColor.gray
                let node = SCNNode(geometry: text)
                node.position = SCNVector3(-1, 0, 0)
                scene.rootNode.addChildNode(node)
            }
        }

        func cancelAnimation() { animation?.cancel() }

        func setHand(_ hand: BandHand) {
            handRoot.scale = SCNVector3(hand == .left ? -1 : 1, 1, 1)
        }

        func setBackground(dark: Bool) {
            // Composite in SceneKit so the translucent skin keeps its color inside the native view.
            // The page's own paper color, so the hand floats on it with no box around it.
            scene.background.contents = dark
                ? NSColor(white: 0.085, alpha: 1)
                : NSColor(red: 0.96, green: 0.955, blue: 0.94, alpha: 1)
            material.setValue(dark ? 1.0 : 0.0, forKey: "darkAppearance")
        }

        func show(_ next: HandHighlight, revision: Int, sustained: Bool, animated: Bool) {
            guard next != highlight || revision != self.revision || sustained != self.sustained else { return }
            let releasing = self.sustained && !sustained && revision == self.revision
            animation?.cancel()
            highlight = next
            self.revision = revision
            self.sustained = sustained
            animation = Task { [weak self] in
                guard let self else { return }
                if next == .none || releasing {
                    await fade(to: .zero, duration: animated ? 0.25 : 0)
                    return
                }
                await fade(to: next.tips, duration: animated ? 0.08 : 0)
                guard !Task.isCancelled, !sustained else { return }
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                await fade(to: .zero, duration: animated ? 0.45 : 0)
            }
        }

        private func fade(to end: SIMD3<Float>, duration: Double) async {
            let start = illumination
            let began = CACurrentMediaTime()
            while !Task.isCancelled {
                let fraction = duration == 0 ? 1 : Float(min(1, (CACurrentMediaTime() - began) / duration))
                let eased = fraction * fraction * (3 - 2 * fraction)
                setIllumination(start + (end - start) * eased)
                if fraction >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }

        private func setIllumination(_ value: SIMD3<Float>) {
            illumination = value
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            material.setValue(value.x, forKey: "thumbLight")
            material.setValue(value.y, forKey: "indexLight")
            material.setValue(value.z, forKey: "middleLight")
            SCNTransaction.commit()
        }
    }
}

private struct HandMesh: Decodable {
    let positions: [Float]
    let normals: [Float]
    let indices: [Int32]
    let tips: [String: [Float]]

    static func load() throws -> HandMesh {
        guard let url = Bundle.kinesis.url(forResource: "hand", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let mesh = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let count = mesh.positions.count / 3
        guard count > 0, mesh.positions.count.isMultiple(of: 3), mesh.normals.count == mesh.positions.count,
              mesh.indices.count.isMultiple(of: 3), mesh.indices.allSatisfy({ $0 >= 0 && $0 < count }),
              ["thumb", "index", "middle"].allSatisfy({ mesh.tips[$0]?.count == 3 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return mesh
    }

    private static func source(_ values: [Float], semantic: SCNGeometrySource.Semantic, components: Int = 3) -> SCNGeometrySource {
        SCNGeometrySource(data: values.withUnsafeBytes { Data($0) }, semantic: semantic,
            vectorCount: values.count / components, usesFloatComponents: true, componentsPerVector: components,
            bytesPerComponent: 4, dataOffset: 0, dataStride: components * 4)
    }

    func geometry() -> SCNGeometry {
        let elements = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles,
            primitiveCount: indices.count / 3, bytesPerIndex: 4)
        let centers = ["thumb", "index", "middle"].map { name in
            let point = tips[name]!
            return SIMD3(point[0], point[1], point[2])
        }
        var colors: [Float] = []
        var coordinates: [CGPoint] = []
        for offset in stride(from: 0, to: positions.count, by: 3) {
            let vertex = SIMD3(positions[offset], positions[offset + 1], positions[offset + 2])
            for center in centers {
                let distance = simd_distance(vertex, center)
                let t = min(1, max(0, (distance - 0.08) / 0.34))
                colors.append(1 - t * t * (3 - 2 * t))
            }
            colors.append(1)
            coordinates.append(CGPoint(x: 0, y: Double(max(0, vertex.y) / 3.4143)))
        }
        return SCNGeometry(sources: [Self.source(positions, semantic: .vertex), Self.source(normals, semantic: .normal),
            Self.source(colors, semantic: .color, components: 4), SCNGeometrySource(textureCoordinates: coordinates)], elements: [elements])
    }
}
