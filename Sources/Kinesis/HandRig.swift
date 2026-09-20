import Foundation
import SceneKit
import simd
import KinesisCore

/// A whole-hand pose: how far each finger curls, where the thumb sits, and how
/// far the wrist has rolled. All angles are degrees. The thumb values were
/// solved against the rig so its tip really meets each target.
struct HandPose: Equatable {
    /// Flexion at the knuckle, the middle joint, and the last joint.
    var index: SIMD3<Float>
    var middle: SIMD3<Float>
    var ring: SIMD3<Float>
    var pinky: SIMD3<Float>
    /// The thumb's base joint turns on all three axes; its other two joints only flex.
    var thumbBase: SIMD3<Float>
    var thumbMiddle: Float
    var thumbEnd: Float
    var roll: Float = 0

    static let relaxed = HandPose(index: [18, 24, 12], middle: [22, 28, 14], ring: [26, 32, 16], pinky: [30, 34, 18],
                                  thumbBase: [0, 0, 0], thumbMiddle: 8, thumbEnd: 10)
    static let pinchIndex = HandPose(index: [42, 52, 26], middle: [22, 28, 14], ring: [26, 32, 16], pinky: [30, 34, 18],
                                     thumbBase: [-26.9, 7.3, -1.6], thumbMiddle: 15, thumbEnd: 5)
    static let pinchMiddle = HandPose(index: [8, 14, 8], middle: [48, 56, 28], ring: [26, 32, 16], pinky: [30, 34, 18],
                                      thumbBase: [-33.1, 10.1, -2.1], thumbMiddle: 19.1, thumbEnd: 6.2)

    /// A loose fist with the thumb's pad on the side of the index finger. Every thumb value
    /// was solved skin to skin against the rig, so the pad rests on the finger and never
    /// sinks into it. Left and right slide the pad along the finger.
    static func swipe(index: SIMD3<Float> = [50, 70, 35], _ thumbBase: SIMD3<Float>, _ thumbMiddle: Float, _ thumbEnd: Float) -> HandPose {
        HandPose(index: index, middle: [56, 76, 38], ring: [60, 80, 40], pinky: [64, 82, 42],
                 thumbBase: thumbBase, thumbMiddle: thumbMiddle, thumbEnd: thumbEnd)
    }
    static let swipeRest = swipe([-24.2, -4.2, -3.8], 11.0, 10.4)
    static let swipeLeft = swipe([-25.7, 6.3, -0.2], 8.6, 6.7)
    static let swipeRight = swipe([-21.9, -14.1, 0.1], 11.0, 19.2)
    /// Up ends off the finger: the thumb straightens, lifts clear of the fist, and overextends.
    static let swipeUp = swipe([15.9, -40.0, -25.0], -8.0, -11.5)
    /// Down curls the thumb in over the side of the finger, and the index comes in to meet it.
    static let swipeDown = swipe(index: [48.6, 53.0, 26.5], [-6.4, -1.7, 3.0], 35.3, 62.8)
    /// The thumb reaches up before it comes down, so it goes over the finger and not through it.
    static let swipeWindup = swipeRest.blended(toward: swipeUp, by: 0.4)

    static func swipeEnd(_ direction: SwipeDirection) -> HandPose {
        switch direction {
        case .left: swipeLeft
        case .right: swipeRight
        case .up: swipeUp
        case .down: swipeDown
        }
    }

    /// Left and right start from the far end of the finger. Up and down start from rest.
    static func swipeStart(_ direction: SwipeDirection) -> HandPose {
        switch direction {
        case .left: swipeRight
        case .right: swipeLeft
        case .up, .down: swipeRest
        }
    }

    /// A swipe acted out: each pose, and how many milliseconds the hand heads for it.
    static func swipeKeys(_ direction: SwipeDirection) -> [(pose: HandPose, hold: Int)] {
        let start = swipeStart(direction), end = swipeEnd(direction)
        return direction == .down ? [(start, 110), (swipeWindup, 130), (end, 340)] : [(start, 150), (end, 330)]
    }

    func blended(toward other: HandPose, by amount: Float) -> HandPose {
        var values = vector
        let target = other.vector
        for index in values.indices { values[index] += (target[index] - values[index]) * amount }
        return HandPose(vector: values)
    }

    static let width = 18

    var vector: [Float] {
        [index.x, index.y, index.z, middle.x, middle.y, middle.z, ring.x, ring.y, ring.z, pinky.x, pinky.y, pinky.z,
         thumbBase.x, thumbBase.y, thumbBase.z, thumbMiddle, thumbEnd, roll]
    }

    init(index: SIMD3<Float>, middle: SIMD3<Float>, ring: SIMD3<Float>, pinky: SIMD3<Float>,
         thumbBase: SIMD3<Float>, thumbMiddle: Float, thumbEnd: Float, roll: Float = 0) {
        self.index = index
        self.middle = middle
        self.ring = ring
        self.pinky = pinky
        self.thumbBase = thumbBase
        self.thumbMiddle = thumbMiddle
        self.thumbEnd = thumbEnd
        self.roll = roll
    }

    init(vector v: [Float]) {
        self.init(index: [v[0], v[1], v[2]], middle: [v[3], v[4], v[5]], ring: [v[6], v[7], v[8]], pinky: [v[9], v[10], v[11]],
                  thumbBase: [v[12], v[13], v[14]], thumbMiddle: v[15], thumbEnd: v[16], roll: v[17])
    }
}

/// The exported hand: a rest-pose mesh, its joints, and four bone weights per vertex.
struct HandMesh: Decodable {
    struct Joint: Decodable {
        let name: String
        let parent: Int
        let rest: [Float]
    }

    let positions: [Float]
    let normals: [Float]
    let indices: [Int32]
    let tips: [String: [Float]]
    let joints: [Joint]
    let boneIndices: [UInt16]
    let boneWeights: [Float]

    static func load() throws -> HandMesh {
        guard let url = Bundle.kinesis.url(forResource: "hand", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let mesh = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let count = mesh.positions.count / 3
        guard count > 0, mesh.positions.count.isMultiple(of: 3), mesh.normals.count == mesh.positions.count,
              mesh.indices.count.isMultiple(of: 3), mesh.indices.allSatisfy({ $0 >= 0 && $0 < count }),
              ["thumb", "index", "middle"].allSatisfy({ mesh.tips[$0]?.count == 3 }),
              !mesh.joints.isEmpty, mesh.joints.allSatisfy({ $0.rest.count == 16 && $0.parent < mesh.joints.count }),
              mesh.boneIndices.count == count * 4, mesh.boneWeights.count == count * 4,
              mesh.boneIndices.allSatisfy({ Int($0) < mesh.joints.count }) else {
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
            // The glow is baked at rest, so it rides each fingertip wherever the rig takes it.
            for center in centers {
                let distance = simd_distance(vertex, center)
                let t = min(1, max(0, (distance - 0.08) / 0.62))
                colors.append(1 - t * t * (3 - 2 * t))
            }
            colors.append(1)
            coordinates.append(CGPoint(x: 0, y: Double(max(0, vertex.y) / 3.4143)))
        }
        return SCNGeometry(sources: [Self.source(positions, semantic: .vertex), Self.source(normals, semantic: .normal),
            Self.source(colors, semantic: .color, components: 4), SCNGeometrySource(textureCoordinates: coordinates)], elements: [elements])
    }

    var weightSource: SCNGeometrySource { Self.source(boneWeights, semantic: .boneWeights, components: 4) }

    var indexSource: SCNGeometrySource {
        SCNGeometrySource(data: boneIndices.withUnsafeBytes { Data($0) }, semantic: .boneIndices,
            vectorCount: boneIndices.count / 4, usesFloatComponents: false, componentsPerVector: 4,
            bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
    }
}

/// The hand's skeleton in the scene. It turns a `HandPose` into joint rotations,
/// and moves between poses on springs, so a new gesture bends the motion that is
/// already under way instead of cutting it off.
@MainActor final class HandRig {
    let root = SCNNode()
    let skin = SCNNode()
    private var bones: [SCNNode] = []
    private var restLocal: [simd_float4x4] = []
    private var restWorld: [simd_float4x4] = []
    private var indexOf: [String: Int] = [:]
    private var current = HandPose.relaxed.vector
    private var velocity = [Float](repeating: 0, count: HandPose.width)
    private var target = HandPose.relaxed.vector
    private var driver: Task<Void, Never>?
    /// The roll turns the whole hand around the pinch, so the view owns it, not a joint.
    var onRoll: ((Float) -> Void)?
    /// Where the thumb and index meet in a pinch, in the hand's own space.
    static let pinchPoint = SIMD3<Float>(-0.434, 1.917, -1.257)
    /// Spring stiffness as an angular frequency. Higher is snappier.
    private let frequency: Float = 34

    init(mesh: HandMesh, material: SCNMaterial) {
        let rest = mesh.joints.map { joint in
            simd_float4x4(columns: (SIMD4(joint.rest[0], joint.rest[1], joint.rest[2], joint.rest[3]),
                                    SIMD4(joint.rest[4], joint.rest[5], joint.rest[6], joint.rest[7]),
                                    SIMD4(joint.rest[8], joint.rest[9], joint.rest[10], joint.rest[11]),
                                    SIMD4(joint.rest[12], joint.rest[13], joint.rest[14], joint.rest[15])))
        }
        restWorld = rest
        bones = mesh.joints.map { joint in
            let node = SCNNode()
            node.name = joint.name
            return node
        }
        for (index, joint) in mesh.joints.enumerated() {
            indexOf[joint.name] = index
            let local = joint.parent < 0 ? rest[index] : rest[joint.parent].inverse * rest[index]
            restLocal.append(local)
            bones[index].simdTransform = local
            (joint.parent < 0 ? root : bones[joint.parent]).addChildNode(bones[index])
        }
        let geometry = mesh.geometry()
        geometry.materials = [material]
        skin.geometry = geometry
        skin.name = "hand"
        let skinner = SCNSkinner(baseGeometry: geometry, bones: bones,
                                 boneInverseBindTransforms: rest.map { NSValue(scnMatrix4: SCNMatrix4($0.inverse)) },
                                 boneWeights: mesh.weightSource, boneIndices: mesh.indexSource)
        skinner.skeleton = bones.first
        skin.skinner = skinner
        apply(current)
    }

    func cancel() { driver?.cancel() }

    /// Where the hand is now, and where it is heading.
    var pose: HandPose { HandPose(vector: current) }
    var goal: HandPose { HandPose(vector: target) }

    /// Where the visible skin sits under the current pose, seen through `view`. The
    /// wrist fades to nothing, so only skin that can be seen is counted.
    func visibleBounds(of mesh: HandMesh, through view: simd_float4x4) -> (low: SIMD2<Float>, high: SIMD2<Float>) {
        let skinning = bones.enumerated().map { index, bone in
            root.simdConvertTransform(bone.simdWorldTransform, from: nil) * restWorld[index].inverse
        }
        var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
        for vertex in 0..<(mesh.positions.count / 3) where mesh.positions[vertex * 3 + 1] > 0.1 {
            let rest = SIMD4(mesh.positions[vertex * 3], mesh.positions[vertex * 3 + 1], mesh.positions[vertex * 3 + 2], 1)
            var skinned = SIMD4<Float>.zero
            for slot in 0..<4 {
                let weight = mesh.boneWeights[vertex * 4 + slot]
                if weight > 0 { skinned += weight * (skinning[Int(mesh.boneIndices[vertex * 4 + slot])] * rest) }
            }
            let seen = view * skinned
            low = simd_min(low, SIMD2(seen.x, seen.y))
            high = simd_max(high, SIMD2(seen.x, seen.y))
        }
        return (low, high)
    }

    /// A joint's position as another joint sees it. Each joint's +y is the back of
    /// its finger, so this says whether the thumb is above or below a finger.
    func position(of joint: String, seenFrom frame: String) -> SIMD3<Float>? {
        guard let joint = indexOf[joint], let frame = indexOf[frame] else { return nil }
        return bones[frame].simdConvertPosition(bones[joint].simdWorldPosition, from: nil)
    }

    /// A joint's position in the hand's own space, under the current pose.
    func position(of joint: String) -> SIMD3<Float>? {
        indexOf[joint].map { root.simdConvertPosition(bones[$0].simdWorldPosition, from: nil) }
    }

    /// Sets the pose at once, with no motion. Used for renders and Reduce Motion.
    func snap(to pose: HandPose) {
        driver?.cancel()
        current = pose.vector
        target = current
        velocity = [Float](repeating: 0, count: HandPose.width)
        apply(current)
    }

    /// Tests turn this off and step the rig by hand, so motion is exact and repeatable.
    var drivesItself = true

    /// Moves the springs on by one frame. Returns true once the hand is at rest.
    @discardableResult func advance(by dt: Float) -> Bool { step(by: dt) }

    /// Heads for a pose. Whatever the hand is doing now carries into the new motion.
    func move(to pose: HandPose) {
        target = pose.vector
        guard drivesItself, driver == nil || driver?.isCancelled == true else { return }
        driver = Task { [weak self] in
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                let now = CACurrentMediaTime()
                let settled = self.step(by: Float(min(now - last, 1.0 / 30)))
                last = now
                if settled {
                    self.driver = nil
                    return
                }
            }
        }
    }

    /// Advances a critically damped spring on every angle. Returns true at rest.
    /// A long frame is split into short steps, so a stall never makes the hand overshoot.
    private func step(by dt: Float) -> Bool {
        var settled = true
        let pieces = max(1, Int((dt / 0.004).rounded(.up)))
        let slice = dt / Float(pieces)
        for index in current.indices {
            for _ in 0..<pieces {
                let offset = current[index] - target[index]
                let acceleration = -frequency * frequency * offset - 2 * frequency * velocity[index]
                velocity[index] += acceleration * slice
                current[index] += velocity[index] * slice
            }
            if abs(current[index] - target[index]) > 0.05 || abs(velocity[index]) > 0.5 { settled = false }
        }
        if settled {
            current = target
            velocity = [Float](repeating: 0, count: HandPose.width)
        }
        apply(current)
        return settled
    }

    private func apply(_ values: [Float]) {
        let pose = HandPose(vector: values)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for (finger, curl) in [("index-finger", pose.index), ("middle-finger", pose.middle),
                               ("ring-finger", pose.ring), ("pinky-finger", pose.pinky)] {
            set(finger + "-phalanx-proximal", [-curl.x, 0, 0])
            set(finger + "-phalanx-intermediate", [-curl.y, 0, 0])
            set(finger + "-phalanx-distal", [-curl.z, 0, 0])
        }
        set("thumb-metacarpal", pose.thumbBase)
        set("thumb-phalanx-proximal", [-pose.thumbMiddle, 0, 0])
        set("thumb-phalanx-distal", [-pose.thumbEnd, 0, 0])
        SCNTransaction.commit()
        onRoll?(pose.roll)
    }

    private func set(_ joint: String, _ degrees: SIMD3<Float>) {
        guard let index = indexOf[joint] else { return }
        let radians = degrees * (.pi / 180)
        let turn = simd_quatf(angle: radians.x, axis: [1, 0, 0]) * simd_quatf(angle: radians.y, axis: [0, 1, 0])
            * simd_quatf(angle: radians.z, axis: [0, 0, 1])
        bones[index].simdTransform = restLocal[index] * simd_float4x4(turn)
    }
}
