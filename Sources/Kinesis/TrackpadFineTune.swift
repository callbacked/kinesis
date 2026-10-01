#if KINESIS_DEV
import Accelerate
import Foundation

/// Fine-tunes a trackpad decoder's whole network on frames the Mac's trackpad labeled, the
/// way scripts/trackpad-train.py's `fine_tune` does: Adam, a loss of contact cross-entropy
/// plus twice a Huber loss on velocity, noise on the inputs, and a pull back toward the
/// trained network. Pure computation, so it can run off the main thread.
struct TrackpadFineTune {
    struct Example: Sendable {
        /// Scaled features, as the decoder's output carries them.
        var features: [Float]
        var contact: Bool
        /// A lone finger's velocity in model units, when it had one.
        var velocity: SIMD2<Float>?
    }

    var epochs = 4
    var rate: Float = 3e-4
    var batch = 256
    var noise: Float = 0.1
    /// This times the squared distance from the trained network joins the loss.
    var anchor: Float = 1e-3
    var shuffle = true
    var seed: UInt64 = 1

    private struct Layer {
        var weights: [Float]
        var bias: [Float]
        let inputs: Int
        let outputs: Int
    }

    func run(from start: TrackpadDecoder.Network, anchoredTo trained: TrackpadDecoder.Network,
             on examples: [Example]) -> TrackpadDecoder.Network {
        // Only frames as wide as the network reads: a frame from another model never gets in.
        guard let width = start.layers.first?.inputs else { return start }
        let examples = examples.filter { $0.features.count == width }
        guard !examples.isEmpty else { return start }
        var layers = start.layers.map {
            Layer(weights: $0.weights.map(Float.init), bias: $0.bias.map(Float.init), inputs: $0.inputs, outputs: $0.bias.count)
        }
        let home = trained.layers.map { (weights: $0.weights.map(Float.init), bias: $0.bias.map(Float.init)) }
        var first = layers.map { (weights: [Float](repeating: 0, count: $0.weights.count), bias: [Float](repeating: 0, count: $0.bias.count)) }
        var second = first
        var random = SeededRandom(seed: seed)
        var step: Float = 0
        let beta1: Float = 0.9, beta2: Float = 0.999, epsilon: Float = 1e-8

        var order = Array(examples.indices)
        for _ in 0..<epochs {
            if shuffle { order.shuffle(using: &random) }
            for start in stride(from: 0, to: order.count, by: batch) {
                let rows = order[start..<min(start + batch, order.count)]
                let count = rows.count

                // Forward, keeping each layer's input and pre-activation.
                var input = [Float](repeating: 0, count: count * width)
                for (r, index) in rows.enumerated() {
                    let features = examples[index].features
                    for i in 0..<width { input[r * width + i] = features[i] + (noise > 0 ? noise * random.gaussian() : 0) }
                }
                var inputs: [[Float]] = []
                var preactivations: [[Float]] = []
                for (index, layer) in layers.enumerated() {
                    inputs.append(input)
                    var z = Self.multiply(input, Self.transpose(layer.weights, rows: layer.outputs, columns: layer.inputs),
                                          rows: count, inner: layer.inputs, columns: layer.outputs)
                    for r in 0..<count { for o in 0..<layer.outputs { z[r * layer.outputs + o] += layer.bias[o] } }
                    preactivations.append(z)
                    input = index < layers.count - 1 ? z.map(Self.gelu) : z
                }

                // The loss's slope at the outputs, averaged over the batch.
                var slope = [Float](repeating: 0, count: count * 3)
                for (r, index) in rows.enumerated() {
                    let out = input[(r * 3)..<(r * 3 + 3)].map { $0 }
                    let example = examples[index]
                    slope[r * 3] = (1 / (1 + exp(-out[0])) - (example.contact ? 1 : 0)) / Float(count)
                    if let velocity = example.velocity {
                        slope[r * 3 + 1] = 2 * min(max(out[1] - velocity.x, -1), 1) / Float(count)
                        slope[r * 3 + 2] = 2 * min(max(out[2] - velocity.y, -1), 1) / Float(count)
                    }
                }

                // Backward, then one Adam step per layer.
                step += 1
                for index in layers.indices.reversed() {
                    let layer = layers[index]
                    var weightSlope = Self.multiply(Self.transpose(slope, rows: count, columns: layer.outputs), inputs[index],
                                                    rows: layer.outputs, inner: count, columns: layer.inputs)
                    var biasSlope = [Float](repeating: 0, count: layer.outputs)
                    for r in 0..<count { for o in 0..<layer.outputs { biasSlope[o] += slope[r * layer.outputs + o] } }
                    if index > 0 {
                        var below = Self.multiply(slope, layer.weights, rows: count, inner: layer.outputs, columns: layer.inputs)
                        let z = preactivations[index - 1]
                        for k in below.indices { below[k] *= Self.geluSlope(z[k]) }
                        slope = below
                    }
                    for k in weightSlope.indices { weightSlope[k] += 2 * anchor * (layer.weights[k] - home[index].weights[k]) }
                    for k in biasSlope.indices { biasSlope[k] += 2 * anchor * (layer.bias[k] - home[index].bias[k]) }
                    let correction1 = 1 - pow(beta1, step), correction2 = 1 - pow(beta2, step)
                    for k in weightSlope.indices {
                        let g = weightSlope[k]
                        first[index].weights[k] = beta1 * first[index].weights[k] + (1 - beta1) * g
                        second[index].weights[k] = beta2 * second[index].weights[k] + (1 - beta2) * g * g
                        layers[index].weights[k] -= rate * (first[index].weights[k] / correction1)
                            / ((second[index].weights[k] / correction2).squareRoot() + epsilon)
                    }
                    for k in biasSlope.indices {
                        let g = biasSlope[k]
                        first[index].bias[k] = beta1 * first[index].bias[k] + (1 - beta1) * g
                        second[index].bias[k] = beta2 * second[index].bias[k] + (1 - beta2) * g * g
                        layers[index].bias[k] -= rate * (first[index].bias[k] / correction1)
                            / ((second[index].bias[k] / correction2).squareRoot() + epsilon)
                    }
                }
            }
        }
        return TrackpadDecoder.Network(layers: layers.map { .init(weights: $0.weights.map(Double.init), bias: $0.bias.map(Double.init)) })
    }

    /// Row-major (rows x inner) times (inner x columns).
    static func multiply(_ a: [Float], _ b: [Float], rows: Int, inner: Int, columns: Int) -> [Float] {
        var c = [Float](repeating: 0, count: rows * columns)
        vDSP_mmul(a, 1, b, 1, &c, 1, vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
        return c
    }

    static func transpose(_ a: [Float], rows: Int, columns: Int) -> [Float] {
        var c = [Float](repeating: 0, count: rows * columns)
        vDSP_mtrans(a, 1, &c, 1, vDSP_Length(columns), vDSP_Length(rows))
        return c
    }

    static func gelu(_ z: Float) -> Float { 0.5 * z * (1 + erf(z / Float(2).squareRoot())) }

    static func geluSlope(_ z: Float) -> Float {
        0.5 * (1 + erf(z / Float(2).squareRoot())) + z * exp(-0.5 * z * z) / (2 * Float.pi).squareRoot()
    }
}

/// A small seeded generator, so a fine-tune can be repeated exactly.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A standard normal sample, by the Box-Muller transform.
    mutating func gaussian() -> Float {
        let u = max(Double(next() >> 11) / Double(1 << 53), 1e-12), v = Double(next() >> 11) / Double(1 << 53)
        return Float((-2 * log(u)).squareRoot() * cos(2 * .pi * v))
    }
}
#endif
