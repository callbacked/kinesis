#if KINESIS_DEV
import Foundation
import Testing
@testable import Kinesis

/// The Swift decoder must compute what scripts/trackpad-train.py trained on. The fixture
/// holds synthetic sEMG, a random network, and the Python recipe's outputs for them,
/// with the running reference on. `scripts/trackpad-train.py --fixture` rewrites it.
@Test func theLiveDecoderMatchesThePythonRecipe() throws {
    let fixture = try Fixture.load()
    var decoder = TrackpadDecoder(model: fixture.model)
    let outputs = fixture.play(into: &decoder)
    #expect(outputs.count == fixture.contact.count)
    for (index, output) in outputs.enumerated() where index < fixture.contact.count {
        #expect(abs(output.contact - fixture.contact[index]) < 1e-6)
        #expect(abs(output.velocity.x - fixture.velocity[index][0]) < 1e-4 * max(1, abs(fixture.velocity[index][0])))
        #expect(abs(output.velocity.y - fixture.velocity[index][1]) < 1e-4 * max(1, abs(fixture.velocity[index][1])))
        #expect(abs(output.raise - fixture.raise[index]) < 1e-6)
    }
}

/// Synthetic sEMG and gyro with band and arrival times, a random network, and the Python
/// recipe's outputs. `scripts/trackpad-train.py --fixture` rewrites it.
private struct Fixture: Decodable {
    var model: TrackpadDecoderModel
    var samples: [UInt16]
    var emgBand: [Double]
    var emgArrival: [Double]
    var gyroBand: [Double]
    var gyroArrival: [Double]
    var gyroValues: [[Double]]
    var contact: [Double]
    var velocity: [[Double]]
    var raise: [Double]

    static func load() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/trackpad-decoder.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Feeds sEMG batches and gyro samples in the order they arrived, as live.
    func play(into decoder: inout TrackpadDecoder) -> [TrackpadDecoder.Output] {
        let events = emgArrival.indices.map { (emgArrival[$0], true, $0) } + gyroArrival.indices.map { (gyroArrival[$0], false, $0) }
        var outputs: [TrackpadDecoder.Output] = []
        for (_, isEMG, index) in events.sorted(by: { $0.0 < $1.0 }) {
            if isEMG {
                outputs += decoder.receive(Array(samples[index * 128..<(index + 1) * 128]), bandTime: emgBand[index])
            } else {
                let v = gyroValues[index]
                decoder.receiveGyro(SIMD3(v[0], v[1], v[2]), bandTime: gyroBand[index])
            }
        }
        return outputs
    }
}
#endif

#if KINESIS_DEV
/// Learning inside Kinesis must compute what scripts/trackpad-train.py's fine_tune does:
/// the same weights after three passes, without noise or shuffling.
@Test func fineTuningMatchesPyTorch() throws {
    struct Layer: Decodable { var weights: [[Double]]; var bias: [Double] }
    struct Network: Decodable { var layers: [Layer] }
    struct Settings: Decodable { var epochs: Int; var rate: Double; var batch: Int; var anchor: Double }
    struct Fixture: Decodable {
        var start: Network
        var tuned: Network
        var features: [[Double]]
        var contact: [Bool]
        var velocity: [[Double]]
        var settings: Settings
    }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/trackpad-fine-tune.json")
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    func network(_ n: Network) -> TrackpadDecoder.Network {
        TrackpadDecoder.Network(layers: n.layers.map { .init(weights: $0.weights.flatMap { $0 }, bias: $0.bias) })
    }
    let examples = fixture.features.indices.map { k in
        TrackpadFineTune.Example(features: fixture.features[k].map(Float.init), contact: fixture.contact[k],
                                 velocity: abs(fixture.velocity[k][0]) < 1e8 ? SIMD2(Float(fixture.velocity[k][0]), Float(fixture.velocity[k][1])) : nil)
    }
    let tune = TrackpadFineTune(epochs: fixture.settings.epochs, rate: Float(fixture.settings.rate), batch: fixture.settings.batch,
                                noise: 0, anchor: Float(fixture.settings.anchor), shuffle: false)
    let start = network(fixture.start)
    let result = tune.run(from: start, anchoredTo: start, on: examples)
    let expected = network(fixture.tuned)
    var moved = 0.0
    for (got, want) in zip(result.layers, expected.layers) {
        for (a, b) in zip(got.weights + got.bias, want.weights + want.bias) { #expect(abs(a - b) < 1e-4) }
    }
    for (got, was) in zip(result.layers, start.layers) {
        moved = max(moved, zip(got.weights, was.weights).map { abs($0 - $1) }.max() ?? 0)
    }
    #expect(moved > 0.01)
}
#endif

#if KINESIS_DEV
/// A steady error goes away within a few seconds of touching, and a short real slide
/// mostly comes through.
@Test func driftCorrectionRemovesASteadyErrorButKeepsASlide() {
    var drift = DriftCorrection()
    var last = SIMD2<Double>.zero
    for _ in 0..<(15 * 50) { last = drift.correct(SIMD2(0, -20), frame: 0.02) }
    #expect(abs(last.y) < 1)
    var travelled = 0.0
    for _ in 0..<25 { travelled += drift.correct(SIMD2(0, 100), frame: 0.02).y * 0.02 }
    #expect(travelled > 0.8 * 100 * 0.5)
}

/// The ring keeps the newest items, oldest first.
@Test func ringKeepsTheNewestInOrder() {
    var ring = Ring<Int>(capacity: 3)
    for k in 1...5 { ring.append(k) }
    #expect(ring.items == [3, 4, 5])
    #expect(ring.count == 3)
    ring.removeAll()
    #expect(ring.items.isEmpty)
}
#endif

#if KINESIS_DEV
/// Without "include typing", the recorder keeps only a key's side of the keyboard.
@Test func keySidesFollowTheBandHand() {
    // j (38) is a right-hand key, f (3) a left-hand key, 49 the space bar, 122 F1.
    #expect(PassiveRecorder.side(of: 38, hand: .right) == .bandHand)
    #expect(PassiveRecorder.side(of: 3, hand: .right) == .otherHand)
    #expect(PassiveRecorder.side(of: 38, hand: .left) == .otherHand)
    #expect(PassiveRecorder.side(of: 3, hand: .left) == .bandHand)
    #expect(PassiveRecorder.side(of: 49, hand: .right) == .space)
    #expect(PassiveRecorder.side(of: 122, hand: .right) == .other)
}
#endif
