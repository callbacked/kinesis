#if KINESIS_DEV
import Foundation
import KinesisCore
import simd

/// A developer tool, only in dev builds: one trackpad decoder, shared by everything that
/// wants its output, which learns while "record while I work" records. The Mac's trackpad
/// labels each frame: a finger on it or not, and a lone finger's velocity. Every couple of
/// minutes of that, the whole network is fine-tuned in the background on this wearing's
/// frames, starting from the trained network each time. So it fits how the band sits
/// now within minutes of normal use, with no calibration.
@MainActor final class LiveTrackpad {
    static let shared = LiveTrackpad()

    /// Seconds of labeled frames before the first fine-tune, and between later ones.
    static let tuneEvery = 120.0
    /// Frames kept for fine-tuning: those with a sliding finger, and all others. The oldest go first.
    static let slidingFrames = 12_000
    static let otherFrames = 12_000
    /// A frame is labeled once the trackpad has had this long to report it.
    static let labelDelay = 0.1

    private(set) var problem: String?
    /// Seconds of trackpad-labeled frames on this wearing.
    private(set) var learned = 0.0
    /// Fine-tunes finished on this wearing.
    private(set) var tunes = 0
    /// How many recordings the model trained on.
    var trainedOn: Int { decoder?.model.trainedOn?.count ?? 0 }
    /// Seconds per decoded frame.
    var frameSeconds: Double { decoder.map { Double($0.model.hop) / $0.model.rate } ?? 0.02 }
    /// The click detector's settings, when the model has one.
    var raise: TrackpadDecoderModel.Raise? { decoder?.model.raise }

    private weak var model: BandModel?
    private var decoder: TrackpadDecoder?
    private var modelDate: Date?
    private var holders: Set<String> = []
    private var listeners: [String: (TrackpadDecoder.Output) -> Void] = [:]
    private var teaching = false
    private var wearing = 0
    /// The Mac's clock minus the band's, for a batch that came through with the least delay.
    private var clockShift: Double?
    private var lastShiftUpdate = 0.0
    private var pending: [(time: Double, features: [Double])] = []
    private var touches: [(time: Double, fingers: [SIMD2<Float>], palms: Int)] = []
    private var previous: (time: Double, finger: SIMD2<Double>)?
    private var sliding = Ring<TrackpadFineTune.Example>(capacity: slidingFrames)
    private var other = Ring<TrackpadFineTune.Example>(capacity: otherFrames)
    /// Sure desk touches: frames while the finger cursor's Control clutch is held.
    private var desk = Ring<TrackpadFineTune.Example>(capacity: 6_000)
    private var deskHeldSince: Double?
    private var learnedAtTune = 0.0
    private var tuning = false
    private var lastCheck = 0.0
    private var lastAttempt = 0.0

    private init() {}

    private nonisolated static var folder: URL { TrackpadDecoderModel.file.deletingLastPathComponent() }
    private static var savedNetwork: URL { folder.appendingPathComponent("decoder-live.plist") }
    private nonisolated static var savedFrames: URL { folder.appendingPathComponent("decoder-live.frames") }

    private struct Saved: Codable {
        var modelDate: Date
        var wearing: Int
        var network: TrackpadDecoder.Network
        var learned: Double
        var tunes: Int
    }

    /// Starts the decoder for `name`, which gets every output. Returns a problem to show, if any.
    @discardableResult
    func hold(_ name: String, model: BandModel, listener: ((TrackpadDecoder.Output) -> Void)? = nil) -> String? {
        self.model = model
        if decoder == nil {
            do {
                try load()
            } catch let mismatch as TrackpadDecoderModel.Mismatch {
                problem = mismatch.errorDescription
                return problem
            } catch {
                problem = "no decoder yet. run scripts/trackpad-train.py first."
                return problem
            }
        }
        guard model.live, model.developerMode else { return "connect the band and turn on developer mode first." }
        problem = nil
        let first = holders.isEmpty
        holders.insert(name)
        listeners[name] = listener
        if first {
            model.holdRawEMG("trackpad decoder", true)
            model.rawEMGListeners["trackpad decoder"] = { [weak self] batch, arrived in self?.receive(batch, at: arrived) }
            model.gyroListeners["trackpad decoder"] = { [weak self] values, stamp, _ in
                self?.decoder?.receiveGyro(values, bandTime: Double(stamp) / 1e6)
            }
        }
        return nil
    }

    func release(_ name: String) {
        guard holders.remove(name) != nil else { return }
        listeners[name] = nil
        guard holders.isEmpty, let model else { return }
        model.rawEMGListeners["trackpad decoder"] = nil
        model.gyroListeners["trackpad decoder"] = nil
        model.holdRawEMG("trackpad decoder", false)
        save(frames: false)
        pending = []
        previous = nil
        // A later start begins a fresh stream: new filters and history, the same learned network.
        if let current = decoder {
            decoder = TrackpadDecoder(model: current.model)
            decoder?.network = current.network
        }
    }

    /// Keeps what this wearing learned, frames too, when Kinesis quits.
    func shutdown() {
        save(frames: true, waiting: true)
    }

    /// Called by the passive recorder: whether it is recording now, so the trackpad is
    /// being read, and which wearing of the band this is.
    func setTeaching(_ value: Bool, wearing: Int, model: BandModel) {
        if wearing != self.wearing {
            save(frames: true)
            self.wearing = wearing
            if decoder != nil { restore() }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if value, teaching, !holders.contains("learning"), now - lastAttempt > 30 {
            // It couldn't start before, with no model or one that doesn't fit: try again now and then.
            lastAttempt = now
            if problem != nil { decoder = nil }
            hold("learning", model: model)
        }
        guard value != teaching else { return }
        teaching = value
        if value {
            lastAttempt = now
            hold("learning", model: model)
        } else {
            release("learning")
            touches = []
        }
    }

    /// Called by the finger cursor: Control held on the desk, a sure touch, or not. Frames from
    /// 100 ms after it went down, while it stays down, join the fine-tuning as touches.
    func setDeskTouch(_ held: Bool) {
        deskHeldSince = held ? (deskHeldSince ?? ProcessInfo.processInfo.systemUptime) : nil
    }

    /// Called by the passive recorder for every trackpad frame: when it arrived, the fingers
    /// touching in millimeters, and how many palms.
    func receiveTrackpad(at arrived: Double, fingers: [SIMD2<Float>], palms: Int) {
        guard teaching else { return }
        touches.append((arrived, fingers, palms))
        if touches.count > 400 { touches.removeFirst(touches.count - 400) }
    }

    private func load() throws {
        let values = try FileManager.default.attributesOfItem(atPath: TrackpadDecoderModel.file.path)
        decoder = TrackpadDecoder(model: try TrackpadDecoderModel.load())
        modelDate = values[.modificationDate] as? Date ?? .distantPast
        restore()
    }

    /// What this wearing learned before a relaunch, if it learned on the same model; otherwise a fresh start.
    private func restore() {
        guard var decoder else { return }
        sliding.removeAll()
        other.removeAll()
        desk.removeAll()
        pending = []
        previous = nil
        touches = []
        learned = 0
        tunes = 0
        learnedAtTune = 0
        decoder.network = decoder.trained
        if let data = try? Data(contentsOf: Self.savedNetwork),
           let saved = try? PropertyListDecoder().decode(Saved.self, from: data),
           saved.modelDate == modelDate, saved.wearing == wearing,
           saved.network.layers.map(\.weights.count) == decoder.trained.layers.map(\.weights.count) {
            decoder.network = saved.network
            learned = saved.learned
            tunes = saved.tunes
            learnedAtTune = saved.learned
            readFrames(width: decoder.model.inputMean.count)
        }
        self.decoder = decoder
    }

    /// What the saved frames file belongs to. Frames of another model, wearing or width are ignored.
    private struct FramesHeader: Equatable {
        static let size = 24
        var modelDate: Double
        var wearing: Int64
        var width: Int32

        func encoded() -> Data {
            var data = Data("KLF2".utf8)
            withUnsafeBytes(of: modelDate) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: wearing) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: width) { data.append(contentsOf: $0) }
            return data
        }

        init(modelDate: Double, wearing: Int64, width: Int32) {
            self.modelDate = modelDate
            self.wearing = wearing
            self.width = width
        }

        init?(_ data: Data) {
            guard data.count >= Self.size, data.prefix(4) == Data("KLF2".utf8) else { return nil }
            (modelDate, wearing, width) = data.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: 4, as: Double.self), $0.loadUnaligned(fromByteOffset: 12, as: Int64.self),
                 $0.loadUnaligned(fromByteOffset: 20, as: Int32.self))
            }
        }
    }

    /// Saves the learned network. With `frames`, also the fine-tuning frames, off the main
    /// thread unless `waiting`, as at quit, when the write has to finish first.
    private func save(frames: Bool, waiting: Bool = false) {
        guard let decoder, let modelDate, learned > 0 else { return }
        let saved = Saved(modelDate: modelDate, wearing: wearing, network: decoder.network, learned: learned, tunes: tunes)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(saved).write(to: Self.savedNetwork, options: .atomic)
        guard frames else { return }
        let header = FramesHeader(modelDate: modelDate.timeIntervalSinceReferenceDate, wearing: Int64(wearing),
                                  width: Int32(decoder.model.inputMean.count))
        let examples = sliding.items + other.items
        if waiting {
            Self.writeFrames(examples, header: header)
        } else {
            Task.detached(priority: .utility) { Self.writeFrames(examples, header: header) }
        }
    }

    /// The fine-tuning frames, raw, after a header: per frame a contact byte, a velocity
    /// byte, two velocity floats, and the features.
    private nonisolated static func writeFrames(_ examples: [TrackpadFineTune.Example], header: FramesHeader) {
        var data = header.encoded()
        data.reserveCapacity(FramesHeader.size + examples.count * (10 + 4 * Int(header.width)))
        for example in examples where example.features.count == Int(header.width) {
            data.append(example.contact ? 1 : 0)
            data.append(example.velocity == nil ? 0 : 1)
            let velocity = example.velocity ?? .zero
            withUnsafeBytes(of: velocity.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: velocity.y) { data.append(contentsOf: $0) }
            example.features.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try? data.write(to: savedFrames, options: .atomic)
    }

    /// Reads the saved frames off the main thread, then puts them ahead of anything learned
    /// since, if they still belong to this model and wearing.
    private func readFrames(width: Int) {
        guard let modelDate else { return }
        let expected = FramesHeader(modelDate: modelDate.timeIntervalSinceReferenceDate, wearing: Int64(wearing), width: Int32(width))
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: Self.savedFrames), FramesHeader(data) == expected else { return }
            let size = 10 + 4 * width
            var examples: [TrackpadFineTune.Example] = []
            data.withUnsafeBytes { raw in
                for start in stride(from: FramesHeader.size, to: raw.count - size + 1, by: size) {
                    let velocity = SIMD2(raw.loadUnaligned(fromByteOffset: start + 2, as: Float.self),
                                         raw.loadUnaligned(fromByteOffset: start + 6, as: Float.self))
                    let features = [Float](unsafeUninitializedCapacity: width) { buffer, count in
                        for k in 0..<width { buffer[k] = raw.loadUnaligned(fromByteOffset: start + 10 + 4 * k, as: Float.self) }
                        count = width
                    }
                    examples.append(.init(features: features, contact: raw[start] == 1, velocity: raw[start + 1] == 1 ? velocity : nil))
                }
            }
            await MainActor.run { LiveTrackpad.shared.merge(saved: examples, for: expected) }
        }
    }

    private func merge(saved: [TrackpadFineTune.Example], for header: FramesHeader) {
        guard let modelDate, header.modelDate == modelDate.timeIntervalSinceReferenceDate, header.wearing == Int64(wearing) else { return }
        let newer = (sliding.items, other.items)
        sliding.removeAll()
        other.removeAll()
        for example in saved + newer.0 + newer.1 {
            if example.velocity != nil { sliding.append(example) } else { other.append(example) }
        }
    }

    private func receive(_ batch: EMGBatch, at arrived: Double) {
        guard decoder != nil else { return }
        let bandTime = Double(batch.timestampUs) / 1e6
        // The smallest delay seen, let up by a millisecond a second so the clocks can drift.
        // A jump of a second or more is a band restart: its clock starts over, and so does
        // the stream, with new filters and history and the same learned network.
        let shift = arrived - bandTime
        if let current = clockShift, abs(shift - current) < 1 {
            clockShift = min(shift, current + (arrived - lastShiftUpdate) * 0.001)
        } else {
            if clockShift != nil, let current = decoder {
                decoder = TrackpadDecoder(model: current.model)
                decoder?.network = current.network
                pending = []
                previous = nil
            }
            clockShift = shift
        }
        lastShiftUpdate = arrived
        // In place, so the decoder's arrays are not copied for every batch.
        guard let outputs = decoder?.receive(batch.values, bandTime: bandTime), let decoder else { return }
        for output in outputs {
            for listener in listeners.values { listener(output) }
            if let since = deskHeldSince, arrived - since > 0.1 {
                desk.append(.init(features: output.features.map(Float.init), contact: true, velocity: nil))
                learned += Double(decoder.model.hop) / decoder.model.rate
            }
            // A desk frame is a sure touch: the trackpad, untouched, would label it "not touching".
            if teaching, deskHeldSince == nil, let clockShift {
                pending.append((bandTime + Double(output.sample) / decoder.model.rate + clockShift, output.features))
            }
        }
        if teaching { label(now: arrived) } else if deskHeldSince != nil { tuneIfDue() }
        if arrived - lastCheck > 60 {
            lastCheck = arrived
            save(frames: false)
            reloadIfRetrained()
        }
    }

    /// Labels the frames the trackpad has had time to report on, the way
    /// scripts/trackpad-train.py labels a passive recording, and keeps them for fine-tuning.
    private func label(now: Double) {
        guard let decoder else { return }
        let frame = Double(decoder.model.hop) / decoder.model.rate
        while let next = pending.first, next.time < now - Self.labelDelay {
            pending.removeFirst()
            let features = next.features.map(Float.init)
            let last = touches.last { $0.time <= next.time }
            guard let last, next.time - last.time <= 0.5 else {
                // No trackpad frame lately: nothing touches it.
                other.append(.init(features: features, contact: false, velocity: nil))
                learned += frame
                previous = nil
                continue
            }
            // A palm is down: leave the moment out.
            guard last.palms == 0 else { previous = nil; continue }
            let finger = last.fingers.count == 1 ? SIMD2<Double>(last.fingers[0]) : nil
            var velocity: SIMD2<Float>?
            if let finger, let previous, next.time - previous.time < 1.5 * frame {
                velocity = SIMD2<Float>((finger - previous.finger) / (next.time - previous.time) / decoder.model.velocityScale)
            }
            previous = finger.map { (next.time, $0) }
            let example = TrackpadFineTune.Example(features: features, contact: !last.fingers.isEmpty, velocity: velocity)
            if velocity != nil { sliding.append(example) } else { other.append(example) }
            learned += frame
        }
        if pending.count > 200 { pending.removeFirst(pending.count - 200) }
        touches.removeAll { $0.time < now - 2 }
        tuneIfDue()
    }

    private func tuneIfDue() {
        // Desk touches alone would teach "always touching": wait for the trackpad's other frames.
        guard !tuning, learned - learnedAtTune >= Self.tuneEvery, other.count >= 1_000, let decoder, let modelDate else { return }
        tuning = true
        learnedAtTune = learned
        let examples = sliding.items + other.items + desk.items
        let trained = decoder.trained
        let wearing = self.wearing
        let seed = UInt64(tunes + 1)
        Task.detached(priority: .utility) {
            let tuned = TrackpadFineTune(seed: seed).run(from: trained, anchoredTo: trained, on: examples)
            await MainActor.run { LiveTrackpad.shared.adopt(tuned, modelDate: modelDate, wearing: wearing) }
        }
    }

    private func adopt(_ network: TrackpadDecoder.Network, modelDate: Date, wearing: Int) {
        tuning = false
        guard modelDate == self.modelDate, wearing == self.wearing,
              network.layers.map(\.weights.count) == decoder?.trained.layers.map(\.weights.count),
              network.layers.allSatisfy({ $0.weights.allSatisfy(\.isFinite) && $0.bias.allSatisfy(\.isFinite) })
        else { return }
        decoder?.network = network
        tunes += 1
        save(frames: false)
    }

    /// After scripts/trackpad-train.py writes a new model, use it. Kept frames were
    /// computed for the old one, so learning starts over.
    private func reloadIfRetrained() {
        let values = try? FileManager.default.attributesOfItem(atPath: TrackpadDecoderModel.file.path)
        guard let date = values?[.modificationDate] as? Date, date != modelDate,
              let loaded = try? TrackpadDecoderModel.load() else { return }
        decoder = TrackpadDecoder(model: loaded)
        modelDate = date
        restore()
    }
}

/// Takes out what a decoder's velocity keeps doing for seconds on end while touching: a
/// small steady error that, added up, walks a pointer off to one edge. Real slides are
/// shorter. On 2026-09-30, 4 s cut the up-down error over touches of 3 s or more from
/// 23 mm to 18 mm and cost 2 points of stroke direction.
struct DriftCorrection {
    static let seconds = 4.0
    private(set) var drift = SIMD2<Double>.zero

    /// The velocity less its drift, for one frame of `frame` seconds while touching.
    mutating func correct(_ velocity: SIMD2<Double>, frame: Double) -> SIMD2<Double> {
        drift += (velocity - drift) * (frame / Self.seconds)
        return velocity - drift
    }
}

/// Keeps the newest `capacity` items.
struct Ring<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var next = 0

    init(capacity: Int) { self.capacity = capacity }

    var items: [Element] { Array(storage[next...] + storage[..<next]) }
    var count: Int { storage.count }

    mutating func append(_ item: Element) {
        if storage.count < capacity {
            storage.append(item)
        } else {
            storage[next] = item
            next = (next + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage = []
        next = 0
    }
}
#endif
