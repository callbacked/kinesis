#if KINESIS_DEV
import Foundation
import KinesisCore

/// A trained trackpad decoder, as scripts/trackpad-train.py exports it.
struct TrackpadDecoderModel: Decodable {
    struct Band: Decodable {
        var low: Double
        var high: Double
        /// Second-order sections, each b0 b1 b2 a0 a1 a2, as scipy writes them.
        var sos: [[Double]]
    }

    struct Gyro: Decodable {
        /// Frames of gyro the network reads: now and the ones before.
        var lags: Int
        /// Raw counts per unit.
        var scale: Double
    }

    struct Layer: Decodable {
        /// Output-major: one row of input weights per output.
        var weights: [[Double]]
        var bias: [Double]
    }

    /// The click detector: a small network of its own that reads the same scaled features and
    /// says how sure it is that a finger was just raised on purpose.
    struct Raise: Decodable {
        var layers: [Layer]
        /// A click fires over this.
        var threshold: Double
        /// Frames after a click before another can fire.
        var lockout: Int
    }

    var rate: Double
    var hop: Int
    /// Frames per covariance.
    var window: Int
    /// Which past frames the network reads, 0 being the newest.
    var lags: [Int]
    /// The share of the average variance added to the diagonal.
    var shrink: Double
    var bands: [Band]
    /// Per band, the training wearings' average log covariance, 8 x 8: where a wearing starts.
    var reference: [[[Double]]]
    var velocityScale: Double
    var inputMean: [Double]
    var inputStd: [Double]
    var layers: [Layer]
    var gyro: Gyro?
    var raise: Raise?
    var trainedOn: [String]?

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kinesis/Lab/decoder.json")
    }

    struct Mismatch: LocalizedError {
        var errorDescription: String? { "the decoder file doesn't fit this build. run scripts/trackpad-train.py again." }
    }

    static func load() throws -> TrackpadDecoderModel {
        let model = try JSONDecoder().decode(TrackpadDecoderModel.self, from: Data(contentsOf: file))
        guard model.fits else { throw Mismatch() }
        return model
    }

    /// Whether the network's layers chain from this recipe's features to three outputs.
    var fits: Bool {
        let width = lags.count * bands.count * 36 + (gyro?.lags ?? 0) * 3
        guard inputMean.count == width, inputStd.count == width, layers.last?.bias.count == 3,
              rate > 0, hop > 0, window > 0, !lags.isEmpty, lags.allSatisfy({ $0 >= 0 }), velocityScale.isFinite,
              (gyro.map { $0.lags > 0 && $0.scale > 0 } ?? true),
              inputStd.allSatisfy({ $0 > 0 && $0.isFinite }), inputMean.allSatisfy(\.isFinite),
              bands.allSatisfy({ $0.sos.allSatisfy { $0.count == 6 && $0[3] != 0 } }),
              reference.allSatisfy({ $0.count == 8 && $0.allSatisfy { $0.count == 8 } })
        else { return false }
        func chains(_ layers: [Layer], to outputs: Int) -> Bool {
            var inputs = width
            for layer in layers {
                guard layer.weights.count == layer.bias.count, layer.weights.allSatisfy({ $0.count == inputs }) else { return false }
                inputs = layer.bias.count
            }
            return inputs == outputs
        }
        return chains(layers, to: 3) && (raise.map { chains($0.layers, to: 1) } ?? true) && reference.count == bands.count
    }
}

/// Runs a trackpad decoder live, one sEMG batch at a time, with only past samples.
/// Per band: the channel covariance over the last `window` frames, re-centered on a
/// running average of this wearing's covariances, then flattened by a matrix log.
/// A small network reads those numbers from a few past frames. The same recipe as
/// scripts/trackpad-train.py.
struct TrackpadDecoder {
    struct Output: Equatable {
        /// 0 to 1: how sure it is that a finger is on the surface.
        var contact: Double
        /// Millimeters a second, across (positive right) and along (positive away).
        var velocity: SIMD2<Double>
        /// Which sample of the batch ended this frame, to place it in time.
        var sample = 0
        /// What the network read, scaled: learning trains on it.
        var features: [Double] = []
        /// 0 to 1: how sure the click detector is that a finger was just raised. 0 without one.
        var raise = 0.0
    }

    /// The network after the features: hidden layers with GELU, then the output layer, whose
    /// three outputs are the contact logit and the velocity in units of `velocityScale`.
    struct Network: Codable, Equatable {
        struct Layer: Codable, Equatable {
            var weights: [Double]    // output-major
            var bias: [Double]
            var inputs: Int { weights.count / max(1, bias.count) }
        }

        var layers: [Layer]

        /// Contact logit and velocity in model units, for scaled features.
        func run(_ features: [Double]) -> [Double] {
            var input = features
            for (index, layer) in layers.enumerated() {
                let inputs = layer.inputs
                var next = layer.bias
                for o in next.indices {
                    let row = o * inputs
                    var sum = next[o]
                    for i in 0..<inputs { sum += layer.weights[row + i] * input[i] }
                    next[o] = index < layers.count - 1 ? 0.5 * sum * (1 + erf(sum / 2.0.squareRoot())) : sum
                }
                input = next
            }
            return input
        }
    }

    private struct Section {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        /// Transposed direct form II, as scipy's sosfilt.
        mutating func step(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    let model: TrackpadDecoderModel
    /// How long the running reference averages over, in seconds. 0 keeps the trained reference.
    var adaptSeconds = 60.0
    private var sections: [[[Section]]]      // band, channel, section
    private var offset: [Double]?
    private var count = 0
    private var hopSums: [[Double]]           // band, 8 x 8 sum over this frame's samples
    private var recent: [[[Double]]] = []     // newest last, the last `window` frames' sums per band
    private var mean: [[Double]]              // band, running mean log covariance
    private var history: [[Double]] = []      // newest first, tangent features per frame
    private var gyroSamples: [(band: Double, values: SIMD3<Double>)] = []   // received so far, by band time
    private var gyroMean: SIMD3<Double>?
    private var gyroHistory: [SIMD3<Double>] = []                           // newest first
    /// Learning replaces it. `trained` is what scripts/trackpad-train.py exported.
    var network: Network
    let trained: Network
    /// The click detector, never fine-tuned.
    let raiseNetwork: Network?
    private let pairs: [(Int, Int, Double)]   // upper triangle, with √2 off the diagonal

    init(model: TrackpadDecoderModel) {
        self.model = model
        let prototype = model.bands.map { band in
            band.sos.map { s in Section(b0: s[0] / s[3], b1: s[1] / s[3], b2: s[2] / s[3], a1: s[4] / s[3], a2: s[5] / s[3]) }
        }
        sections = prototype.map { band in Array(repeating: band, count: 8) }
        hopSums = Array(repeating: Array(repeating: 0, count: 64), count: model.bands.count)
        mean = model.reference.map { $0.flatMap { $0 } }
        network = Network(layers: model.layers.map { .init(weights: $0.weights.flatMap { $0 }, bias: $0.bias) })
        trained = network
        raiseNetwork = model.raise.map { Network(layers: $0.layers.map { .init(weights: $0.weights.flatMap { $0 }, bias: $0.bias) }) }
        pairs = (0..<8).flatMap { i in (i..<8).map { j in (i, j, i == j ? 1.0 : 2.0.squareRoot()) } }
    }

    /// Takes one gyro sample and its band time in seconds, as it arrives.
    mutating func receiveGyro(_ values: SIMD3<Double>, bandTime: Double) {
        guard model.gyro != nil else { return }
        // A band restart starts its clock over: what came before no longer lines up.
        if let last = gyroSamples.last, bandTime < last.band - 1 {
            gyroSamples = []
            gyroMean = nil
            gyroHistory = []
        }
        let index = gyroSamples.lastIndex { $0.band <= bandTime }.map { $0 + 1 } ?? 0
        gyroSamples.insert((bandTime, values), at: index)
        if gyroSamples.count > 256 { gyroSamples.removeFirst(gyroSamples.count - 256) }
    }

    /// Takes one batch, 16 samples of 8 channels, sample-major, and the band time of its
    /// first sample in seconds. Returns an output for every feature frame it completes,
    /// once there is enough history.
    mutating func receive(_ values: [UInt16], bandTime: Double = 0) -> [Output] {
        var outputs: [Output] = []
        let samples = values.count / 8
        if offset == nil {
            offset = (0..<8).map { channel in
                (0..<samples).map { Double(values[$0 * 8 + channel]) }.reduce(0, +) / Double(max(1, samples))
            }
        }
        var filtered = [Double](repeating: 0, count: 8)
        for sample in 0..<samples {
            for band in 0..<model.bands.count {
                for channel in 0..<8 {
                    var y = Double(values[sample * 8 + channel]) - offset![channel]
                    for k in 0..<sections[band][channel].count { y = sections[band][channel][k].step(y) }
                    filtered[channel] = y
                }
                for i in 0..<8 {
                    for j in i..<8 { hopSums[band][i * 8 + j] += filtered[i] * filtered[j] }
                }
            }
            count += 1
            if count == model.hop, var output = completeFrame(at: bandTime + Double(sample) / model.rate) {
                output.sample = sample
                outputs.append(output)
            }
        }
        return outputs
    }

    private mutating func completeFrame(at bandTime: Double) -> Output? {
        for band in 0..<hopSums.count {
            for i in 0..<8 { for j in 0..<i { hopSums[band][i * 8 + j] = hopSums[band][j * 8 + i] } }
        }
        recent.append(hopSums)
        if recent.count > model.window { recent.removeFirst() }
        hopSums = Array(repeating: Array(repeating: 0, count: 64), count: model.bands.count)
        count = 0

        let rate = adaptSeconds > 0 ? 1 / (adaptSeconds * model.rate / Double(model.hop)) : 0
        var features: [Double] = []
        features.reserveCapacity(model.bands.count * pairs.count)
        for band in 0..<model.bands.count {
            var cov = [Double](repeating: 0, count: 64)
            for frame in recent { for k in 0..<64 { cov[k] += frame[band][k] } }
            let scale = 1 / Double(recent.count * model.hop)
            for k in 0..<64 { cov[k] *= scale }
            let trace = (0..<8).reduce(0) { $0 + cov[$1 * 9] }
            for i in 0..<8 { cov[i * 9] += model.shrink * trace / 8 }

            if rate > 0 {
                let logCov = Self.map(cov) { log(max($0, 1e-12)) }
                for k in 0..<64 { mean[band][k] += rate * (logCov[k] - mean[band][k]) }
            }
            let whiten = Self.map(mean[band]) { exp(-0.5 * $0) }
            let centered = Self.map(Self.multiply(Self.multiply(whiten, cov), whiten)) { log(max($0, 1e-12)) }
            for (i, j, weight) in pairs { features.append(centered[i * 8 + j] * weight) }
        }
        if let gyro = model.gyro {
            // The newest gyro sampled by the frame's end, less its running average.
            var value = SIMD3<Double>.zero
            // Radio batches can arrive out of order: look back a quarter second at most, as training does.
            if let sample = gyroSamples.suffix(from: max(0, (gyroSamples.lastIndex { $0.band <= bandTime } ?? -1) - 31))
                .last(where: { $0.band <= bandTime })?.values {
                if let mean = gyroMean {
                    gyroMean = mean + rate * (sample - mean)
                } else {
                    gyroMean = sample
                }
                value = (sample - gyroMean!) / gyro.scale
            }
            gyroHistory.insert(value, at: 0)
            if gyroHistory.count > gyro.lags { gyroHistory.removeLast() }
        }
        history.insert(features, at: 0)
        let needed = (model.lags.max() ?? 0) + 1
        if history.count > needed { history.removeLast() }
        guard history.count == needed else { return nil }

        var input = model.lags.flatMap { history[$0] }
        if let gyro = model.gyro {
            for k in 0..<gyro.lags {
                let value = k < gyroHistory.count ? gyroHistory[k] : .zero
                input += [value.x, value.y, value.z]
            }
        }
        for k in input.indices { input[k] = (input[k] - model.inputMean[k]) / model.inputStd[k] }
        let out = network.run(input)
        let raise = raiseNetwork.map { 1 / (1 + exp(-$0.run(input)[0])) } ?? 0
        return Output(contact: 1 / (1 + exp(-out[0])), velocity: SIMD2(out[1], out[2]) * model.velocityScale,
                      features: input, raise: raise)
    }

    /// `function` applied to a symmetric 8 x 8 matrix's eigenvalues, row-major.
    static func map(_ matrix: [Double], _ function: (Double) -> Double) -> [Double] {
        let (values, vectors) = eigen(matrix)
        let mapped = values.map(function)
        var out = [Double](repeating: 0, count: 64)
        for i in 0..<8 {
            for j in i..<8 {
                var sum = 0.0
                for k in 0..<8 { sum += vectors[i * 8 + k] * mapped[k] * vectors[j * 8 + k] }
                out[i * 8 + j] = sum
                out[j * 8 + i] = sum
            }
        }
        return out
    }

    /// Eigenvalues, and eigenvectors as columns, of a symmetric 8 x 8 matrix by cyclic Jacobi rotations.
    static func eigen(_ matrix: [Double]) -> (values: [Double], vectors: [Double]) {
        var a = matrix
        var v = [Double](repeating: 0, count: 64)
        for i in 0..<8 { v[i * 9] = 1 }
        let size = a.reduce(0) { $0 + $1 * $1 }
        for _ in 0..<60 {
            var off = 0.0
            for p in 0..<8 { for q in (p + 1)..<8 { off += a[p * 8 + q] * a[p * 8 + q] } }
            if off <= 1e-30 * size { break }
            for p in 0..<7 {
                for q in (p + 1)..<8 where a[p * 8 + q] != 0 {
                    let theta = (a[q * 8 + q] - a[p * 8 + p]) / (2 * a[p * 8 + q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<8 {
                        let kp = a[k * 8 + p], kq = a[k * 8 + q]
                        a[k * 8 + p] = c * kp - s * kq
                        a[k * 8 + q] = s * kp + c * kq
                    }
                    for k in 0..<8 {
                        let pk = a[p * 8 + k], qk = a[q * 8 + k]
                        a[p * 8 + k] = c * pk - s * qk
                        a[q * 8 + k] = s * pk + c * qk
                    }
                    for k in 0..<8 {
                        let kp = v[k * 8 + p], kq = v[k * 8 + q]
                        v[k * 8 + p] = c * kp - s * kq
                        v[k * 8 + q] = s * kp + c * kq
                    }
                }
            }
        }
        return ((0..<8).map { a[$0 * 9] }, v)
    }

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 64)
        for i in 0..<8 {
            for k in 0..<8 {
                let x = a[i * 8 + k]
                for j in 0..<8 { out[i * 8 + j] += x * b[k * 8 + j] }
            }
        }
        return out
    }
}
#endif
