#if KINESIS_DEV
import Foundation
import Testing
@testable import Kinesis

/// How fast the trackpad decoder runs, in a release build. It runs only on request:
///     KINESIS_BENCH=path/to/decoder.json swift test -c release -Xswiftc -DKINESIS_DEV -Xswiftc -enable-testing --filter trackpadSpeed
@Test(.enabled(if: ProcessInfo.processInfo.environment["KINESIS_BENCH"] != nil))
func trackpadSpeed() throws {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Kinesis/Lab/decoder.json")
    let path = ProcessInfo.processInfo.environment["KINESIS_BENCH"]!
    let model = try JSONDecoder().decode(TrackpadDecoderModel.self, from: Data(contentsOf: path.isEmpty ? url : URL(fileURLWithPath: path)))
    var decoder = TrackpadDecoder(model: model)
    var random = SeededRandom(seed: 3)
    let batches = 2048 * 10 / 16
    let values = (0..<batches).map { _ in (0..<128).map { _ in UInt16(2048 + Int(random.gaussian() * 60)) } }
    var outputs: [TrackpadDecoder.Output] = []
    let started = Date()
    for (k, batch) in values.enumerated() {
        if k % 4 == 0 { decoder.receiveGyro(SIMD3(400, 300, 900), bandTime: Double(k) * 16 / 2048) }
        outputs += decoder.receive(batch, bandTime: Double(k) * 16 / 2048)
    }
    let decodeTime = Date().timeIntervalSince(started)
    print("BENCH decode: \(outputs.count) frames of 10 s in \(decodeTime) s, \(decodeTime / 10 * 100) % of one core")
    let width = model.inputMean.count
    let examples = (0..<24_000).map { k in
        TrackpadFineTune.Example(features: (0..<width).map { _ in random.gaussian() }, contact: k % 3 == 0,
                                 velocity: k % 2 == 0 ? SIMD2(random.gaussian(), random.gaussian()) : nil)
    }
    let tuneStart = Date()
    _ = TrackpadFineTune().run(from: decoder.trained, anchoredTo: decoder.trained, on: examples)
    print("BENCH fine-tune of 24000 frames: \(Date().timeIntervalSince(tuneStart)) s")
}
#endif
