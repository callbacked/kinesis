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

/// Offscreen renders cannot draw SceneKit, so the render gallery hands in a picture of the hand.
private struct HandStandInKey: EnvironmentKey {
    static let defaultValue: NSImage? = nil
}

extension EnvironmentValues {
    var handStandIn: NSImage? {
        get { self[HandStandInKey.self] }
        set { self[HandStandInKey.self] = newValue }
    }
}

/// The hand on the page: the live scene, or its stand-in when there is one.
struct HandView: View {
    let scene: HandSceneView
    @Environment(\.handStandIn) private var standIn
    var body: some View {
        if let standIn { Image(nsImage: standIn).resizable().scaledToFit() } else { scene }
    }
}

struct HandSceneView: NSViewRepresentable {
    var hand = BandHand.right
    var highlight = HandHighlight.none
    /// The gesture to act out when `revision` changes.
    var gesture: RecognizedGesture?
    var revision = 0
    /// True while a pinch is held. The hand pinches for exactly as long as you do.
    var sustained = false
    /// Degrees of wrist roll to show while a pinch is held, for the dial.
    var roll = 0.0
    var viewpoint = HandViewpoint.overview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(viewpoint: viewpoint) }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.setBackground(dark: colorScheme == .dark)
        context.coordinator.setHand(hand)
        context.coordinator.show(highlight, gesture: gesture, revision: revision, sustained: sustained,
                                 roll: Float(roll), animated: !reduceMotion)
    }

    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.cancelAnimation()
    }

    @MainActor final class Coordinator {
        let scene = SCNScene()
        let camera = SCNNode()
        private let material = SCNMaterial()
        private let handRoot = SCNNode()
        private(set) var rig: HandRig?
        private var highlight: HandHighlight?
        private var revision = -1
        private var sustained = false
        private var releasedAt = -Double.infinity
        private var animation: Task<Void, Never>?
        private var motion: Task<Void, Never>?
        private(set) var illumination = SIMD3<Float>.zero

        init(viewpoint: HandViewpoint = .overview) {
            setBackground(dark: false)
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true
            camera.position = SCNVector3(0, 0, 10)
            scene.rootNode.addChildNode(camera)

            do {
                let mesh = try HandMesh.load()
                material.lightingModel = .constant
                material.transparencyMode = .singleLayer
                material.isDoubleSided = true
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
                    float3 glowColor;
                    #pragma transparent
                    #pragma body
                    float alongHand = _surface.diffuseTexcoord.y;
                    float fade = smoothstep(0.02, 0.4, alongHand);
                    float rim = pow(1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view))), 2.0);
                    float shade = 0.5 + 0.5 * max(0.0, dot(normalize(_surface.normal), normalize(float3(-0.4, 0.6, 1.0))));
                    float glow = max(in.tipInfluence.x * thumbLight, max(in.tipInfluence.y * indexLight, in.tipInfluence.z * middleLight));
                    // A white hand on the light field: nearly flat, with just enough cool shadow
                    // and edge to read. On the dark field it is
                    // porcelain in low light, a few steps above the ground, never a white cutout.
                    float3 paleLight = mix(float3(0.99, 0.99, 0.992), float3(0.72, 0.745, 0.775), 1.0 - shade);
                    paleLight *= 1.0 - 0.3 * rim;
                    float3 paleDark = mix(float3(0.63, 0.655, 0.68), float3(0.215, 0.232, 0.25), 1.0 - shade);
                    paleDark += 0.10 * rim;
                    float3 skin = mix(paleLight, paleDark, darkAppearance);
                    _surface.diffuse.rgb = mix(skin, glowColor, glow * 0.92);
                    _surface.diffuse.a = fade;
                    """, .fragment: """
                    #pragma transparent
                    #pragma body
                    // The scene is drawn in linear light, but the window blends this view in display
                    // space. Premultiplying in display space keeps the wrist's fade the hand's own
                    // colour all the way out. A plain multiply left a bright, hard-edged fringe.
                    _output.color = float4(_surface.diffuse.rgb * pow(_surface.diffuse.a, 2.2), _surface.diffuse.a);
                    """]
                setIllumination(.zero)
                let rig = HandRig(mesh: mesh, material: material)
                self.rig = rig
                let posed = SCNNode()
                posed.addChildNode(rig.root)
                posed.addChildNode(rig.skin)
                // Frame the relaxed hand with room to spare, so the wrist's fade always
                // finishes inside the view and no edge ever cuts through the hand.
                let facing = Self.facing
                let bounds = rig.visibleBounds(of: mesh, through: facing)
                let middle = (bounds.low + bounds.high) / 2
                let reach = max(bounds.high.x - bounds.low.x, bounds.high.y - bounds.low.y)
                camera.camera?.orthographicScale = Double(reach / 2 / (viewpoint == .teaching ? 0.66 : 0.72))
                var place = matrix_identity_float4x4
                place.columns.3 = SIMD4(-middle.x, -middle.y, 0, 1)
                let view = place * facing
                posed.simdTransform = view
                // The dial is a knob held in a pinch, so the hand turns around the
                // pinch along the forearm's line, and the pinch stays where it is.
                let pivot = view * SIMD4(HandRig.pinchPoint, 1)
                let forearm = simd_normalize((view * SIMD4<Float>(0, 1, 0, 0)).xyz)
                rig.onRoll = { [weak posed] degrees in
                    guard let posed else { return }
                    var toPivot = matrix_identity_float4x4, back = matrix_identity_float4x4
                    toPivot.columns.3 = SIMD4(-pivot.x, -pivot.y, -pivot.z, 1)
                    back.columns.3 = SIMD4(pivot.x, pivot.y, pivot.z, 1)
                    let turn = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: forearm))
                    SCNTransaction.begin()
                    SCNTransaction.disableActions = true
                    posed.simdTransform = back * turn * toPivot * view
                    SCNTransaction.commit()
                }
                handRoot.addChildNode(posed)
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

        /// The way Meta shows these gestures: seen from the thumb side, the wrist
        /// low on the right and the fingers reaching up to the left, so a pinch
        /// reads in silhouette. In hand space the fingers run along +y, the back
        /// of the hand faces +z, and the thumb sits toward -x.
        private static let facing: simd_float4x4 = {
            // Fingers to the left, the back of the hand up, the thumb side toward the camera.
            let side = simd_float4x4(columns: (SIMD4(0, 0, -1, 0), SIMD4(-1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))
            func turn(_ degrees: Float, _ axis: SIMD3<Float>) -> simd_float4x4 {
                simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: axis))
            }
            return turn(-34, [0, 0, 1]) * turn(24, [1, 0, 0]) * turn(-28, [0, 1, 0]) * side
        }()

        func cancelAnimation() {
            animation?.cancel()
            motion?.cancel()
            rig?.cancel()
        }

        func setHand(_ hand: BandHand) {
            handRoot.scale = SCNVector3(hand == .left ? -1 : 1, 1, 1)
        }

        func setBackground(dark: Bool) {
            // No ground of its own: the window's field shows through, so the hand floats on it.
            scene.background.contents = NSColor.clear
            material.setValue(dark ? 1.0 : 0.0, forKey: "darkAppearance")
            let glow = KinesisStyle.glow(dark: dark)
            material.setValue(SCNVector3(CGFloat(glow.x), CGFloat(glow.y), CGFloat(glow.z)), forKey: "glowColor")
        }

        func show(_ next: HandHighlight, gesture: RecognizedGesture? = nil, revision: Int, sustained: Bool,
                  roll: Float = 0, animated: Bool) {
            let fired = revision != self.revision
            let held = sustained != self.sustained
            if sustained, animated { rig?.move(to: pinch(for: next).with(roll: roll)) }
            guard next != highlight || fired || held else { return }
            let releasing = self.sustained && !sustained && !fired
            let now = CACurrentMediaTime()
            if self.sustained && !sustained { releasedAt = now }
            animation?.cancel()
            highlight = next
            self.revision = revision
            self.sustained = sustained
            if animated { move(gesture: fired ? gesture : nil, highlight: next, sustained: sustained, held: held, at: now) }
            animation = Task { [weak self] in
                guard let self else { return }
                if next == .none || releasing {
                    await fade(to: .zero, duration: animated ? 0.25 : 0)
                    return
                }
                await fade(to: next.tips, duration: animated ? 0.08 : 0)
                guard !Task.isCancelled, !sustained else { return }
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                await fade(to: .zero, duration: animated ? 0.5 : 0)
            }
        }

        private func pinch(for highlight: HandHighlight) -> HandPose {
            highlight == .middle ? .pinchMiddle : .pinchIndex
        }

        /// A held pinch is mirrored as it happens. A tap that was just mirrored is
        /// not acted out a second time. Swipes have no live signal, so they replay.
        private func move(gesture: RecognizedGesture?, highlight: HandHighlight, sustained: Bool, held: Bool, at now: Double) {
            guard let rig else { return }
            if sustained { motion?.cancel(); return }
            if held && gesture == nil {
                motion?.cancel()
                rig.move(to: .relaxed)
                return
            }
            guard let gesture else { return }
            let mirrored = now - releasedAt < 0.45
            motion?.cancel()
            motion = Task { [weak self] in
                guard let self, let rig = self.rig else { return }
                func pause(_ milliseconds: Int) async -> Bool {
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    return !Task.isCancelled
                }
                switch gesture {
                case .swipe(let direction):
                    for key in HandPose.swipeKeys(direction) {
                        rig.move(to: key.pose)
                        guard await pause(key.hold) else { return }
                    }
                case .tap(let tap):
                    guard !mirrored else { rig.move(to: .relaxed); return }
                    let pinch = tap.finger == "middle" ? HandPose.pinchMiddle : .pinchIndex
                    rig.move(to: pinch)
                    guard await pause(150) else { return }
                    if tap.action != "tap" {
                        rig.move(to: HandPose.relaxed.blended(toward: pinch, by: 0.4))
                        guard await pause(110) else { return }
                        rig.move(to: pinch)
                        guard await pause(150) else { return }
                    }
                }
                rig.move(to: .relaxed)
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

        func setIllumination(_ value: SIMD3<Float>) {
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

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

extension HandPose {
    func with(roll: Float) -> HandPose {
        var pose = self
        pose.roll = roll
        return pose
    }
}
