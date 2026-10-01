import Foundation

/// Original inference payload plus its schema fields. Output indices are not character labels.
public struct BandInferenceSample: Sendable {
    public let sequence: UInt64
    public let timestampUs: UInt64
    public let pipeline: UInt64
    public let latencyUs: UInt64?
    public let values: [Float]
    public let payload: Data

    public init(payload: Data) throws {
        let fields = try ProtoFields(payload)
        sequence = try fields.requiredInteger(1)
        timestampUs = try fields.requiredInteger(2)
        pipeline = try fields.requiredInteger(10)
        guard sequence <= UInt32.max, pipeline <= UInt32.max else { throw BandProtocolError("Invalid inference sample identifier") }
        latencyUs = fields.contains(7) ? try fields.integer(7) : nil
        let bytes = try fields.bytes(3)
        guard !bytes.isEmpty, bytes.count % 4 == 0, bytes.count <= 4096 else {
            throw BandProtocolError("Invalid inference sample dimensions")
        }
        values = bytes.withUnsafeBytes { raw in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        guard values.allSatisfy(\.isFinite) else { throw BandProtocolError("Nonfinite inference sample") }
        self.payload = payload
    }

    public var isTextDistribution: Bool {
        pipeline == 3 && values.count == 100 && values.allSatisfy { $0 <= 0.000001 }
            && abs(values.reduce(0.0) { $0 + exp(Double($1)) } - 1) < 0.0001
    }
}

public struct BandModelCaptureStatus: Equatable, Sendable {
    public enum Phase: Sendable { case idle, preparing, ready, restoring, finished }
    public let phase: Phase
    public let message: String
    public let problem: String?
    public let restorationVerified: Bool
    public init(phase: Phase, message: String, problem: String? = nil, restorationVerified: Bool = false) {
        self.phase = phase; self.message = message; self.problem = problem; self.restorationVerified = restorationVerified
    }
    public var active: Bool { phase == .preparing || phase == .ready || phase == .restoring }
    public static let idle = Self(phase: .idle, message: "", problem: nil, restorationVerified: false)
}

/// Matched RPCs and independent readbacks for one temporary built-in-model recording.
/// It owns no transport: BandSession sends these requests on its existing connection.
final class BandModelCapture {
    enum Operation: Equatable {
        /// `snapshot` reads a setting's value before the recording changes it.
        case streams(Bool), claim, info(Int), snapshot(Int), write(Int, UInt64), read(Int, UInt64), config
    }
    struct Request {
        let id: UInt64
        let operation: Operation
        let deadline: Double
        var channel: UInt16 {
            switch operation { case .streams: 0x8005; case .config: 0x8007; default: 0x8001 }
        }
        func payload(streams: Data) -> Data {
            let arm: Int
            let body: Data
            switch operation {
            case .streams: arm = 4; body = streams
            case .config: arm = 5; body = Data()
            case .claim: arm = 14; body = BandWire.field(1, BandWire.field(1, 2))
            case .info(let id): arm = 14; body = BandWire.field(2, BandWire.field(1, 2) + BandWire.field(2, UInt64(id)))
            case .write(let id, let value):
                arm = 14
                body = BandWire.field(3, BandWire.field(1, UInt64(id)) + BandWire.field(2, 1) + BandWire.field(id == 27 ? 7 : 10, BandWire.field(1, value)))
            case .read(let id, _), .snapshot(let id): arm = 14; body = BandWire.field(3, BandWire.field(1, UInt64(id)) + BandWire.field(2, 0))
            }
            return BandWire.field(1, id) + BandWire.field(arm, body)
        }
    }
    private(set) var status = BandModelCaptureStatus.idle
    private(set) var streamWanted = false
    private(set) var streamTouched = false
    private(set) var pending: Request?
    private var operations: [Operation] = []
    private var nextID: UInt64 = 0x10000000
    private var mutated = false
    private var restoreErrors: [String] = []
    private var problem: String?
    private var samples = 0
    private var lastSample = 0.0
    private var deadline = Double.infinity
    private var events: [BandEvent] = []
    private var checkingRecoverySchema = false
    /// The band's own values before this recording: data collection (27) and its model (28).
    private var original: [Int: UInt64] = [:]
    /// One retry for a restore step whose answer went missing.
    private var retriedRestore = false

    /// What a restore writes back: the band's own values, unless they look like an unfinished
    /// recording (collection on, or the handwriting model), then the known normal ones.
    private var normalCollection: UInt64 { original[27].flatMap { $0 == 0 ? $0 : nil } ?? 0 }
    private var normalModel: UInt64 { original[28].flatMap { $0 == 5 ? nil : $0 } ?? 2 }

    func start(at time: Double) throws {
        guard !status.active else { throw BandProtocolError("A band model recording is already running") }
        problem = nil; restoreErrors = []; mutated = false; samples = 0; lastSample = time
        pending = nil; original = [:]; retriedRestore = false
        operations = [.streams(true), .claim, .info(27), .info(28), .snapshot(27), .snapshot(28), .write(27, 1), .write(28, 5),
                      .read(27, 1), .read(28, 5), .config]
        deadline = time + 40
        publish(.preparing, "checking the band model…", at: time)
    }

    func recoverNormalMode(at time: Double) throws {
        guard !status.active else { throw BandProtocolError("A band model operation is already running") }
        problem = nil; restoreErrors = []; pending = nil; original = [:]; retriedRestore = false
        mutated = true
        checkingRecoverySchema = true
        operations = [.claim, .info(27), .info(28), .write(28, 2), .write(27, 0),
                      .read(28, 2), .read(27, 0), .config, .streams(false)]
        deadline = time + 50
        publish(.restoring, "recovering the band’s normal mode…", at: time)
    }

    func restore(at time: Double) {
        guard status.active, status.phase != .restoring else { return }
        pending = nil
        operations = (mutated ? [.write(28, normalModel), .write(27, normalCollection), .read(28, normalModel),
                                 .read(27, normalCollection), .config] : []) + [.streams(false)]
        deadline = time + 35
        publish(.restoring, "restoring the band’s normal mode…", at: time)
    }

    func next(at time: Double) -> Request? {
        guard status.active else { return nil }
        if time >= deadline {
            // The whole operation ran out of time: never a retry, and never verified.
            fail("the band model operation timed out", at: time, retry: false)
            if status.phase == .restoring, time >= deadline {
                operations = []; pending = nil; complete(at: time)
            }
        }
        if let pending, time >= pending.deadline { fail("the band did not answer a model request", at: time) }
        guard pending == nil, status.active else { return nil }
        if !operations.isEmpty {
            let operation = operations.removeFirst()
            if case .streams(let wanted) = operation { streamTouched = true; streamWanted = wanted }
            if case .write = operation { mutated = true }
            nextID += 1
            let request = Request(id: nextID, operation: operation, deadline: time + 5)
            pending = request
            return request
        }
        if status.phase == .restoring { complete(at: time) }
        else if status.phase == .preparing, samples >= 5, time - lastSample < 2 {
            deadline = time + 360
            publish(.ready, "band model ready", at: time)
        } else if status.phase == .ready, time - lastSample > 3 {
            fail("the band model stopped sending samples", at: time)
        }
        return nil
    }

    @discardableResult
    func receive(channel: UInt16, payload: Data, at time: Double) -> Bool {
        guard let pending, channel & 0x7fff == pending.channel & 0x7fff else { return false }
        do {
            let fields = try ProtoFields(payload)
            guard try fields.integer(1) == pending.id else { return false }
            guard time < pending.deadline, try fields.integer(2) == 1 else {
                throw BandProtocolError("the band rejected or timed out a model request")
            }
            switch pending.operation {
            case .streams(let enabled):
                let flags = try ProtoFields(fields.bytes(5))
                guard try [4, 22, 23].allSatisfy({ try flags.integer($0) == (enabled ? 1 : 0) }) else {
                    throw BandProtocolError("the band did not confirm model streams")
                }
            case .claim:
                let count = try ProtoFields(ProtoFields(fields.bytes(14)).bytes(1))
                guard try count.integer(1) >= 28 else { throw BandProtocolError("model controls are unavailable on this band") }
            case .info(let id):
                let info = try ProtoFields(ProtoFields(fields.bytes(14)).bytes(2))
                let name = id == 27 ? "data-collection" : "data-collection-model"
                guard try info.integer(4) == UInt64(id), try info.bytes(3) == Data(name.utf8) else {
                    throw BandProtocolError("the band’s model controls differ from the supported schema")
                }
                if id == 28 { checkingRecoverySchema = false }
            case .write(let id, _), .read(let id, _), .snapshot(let id):
                let response = try ProtoFields(ProtoFields(fields.bytes(14)).bytes(3))
                let writing: Bool
                if case .write = pending.operation { writing = true } else { writing = false }
                guard try response.integer(1) == UInt64(id), try response.integer(2) == (writing ? 1 : 0), try response.integer(3) == 0 else {
                    throw BandProtocolError("the band refused a model setting")
                }
                if case .read(_, let expected) = pending.operation {
                    let value = try ProtoFields(response.bytes(id == 27 ? 8 : 11))
                    guard try value.integer(1) == expected else { throw BandProtocolError("model setting readback did not match") }
                }
                if case .snapshot = pending.operation {
                    original[id] = try ProtoFields(response.bytes(id == 27 ? 8 : 11)).integer(1)
                }
            case .config:
                _ = try ProtoFields(fields.bytes(6))
                events.append(BandEvent(.inferenceConfiguration(payload), at: time))
            }
            self.pending = nil
        } catch { fail(error.localizedDescription, at: time) }
        return true
    }

    func receive(_ sample: BandInferenceSample, at time: Double) {
        guard status.active, sample.pipeline == 3, status.phase != .restoring else { return }
        guard sample.isTextDistribution else { fail("the band model output has an unsupported shape", at: time); return }
        samples += 1; lastSample = time
        // A session runs as long as samples keep coming. Silence ends it within seconds.
        if status.phase == .ready { deadline = time + 360 }
    }

    func drainEvents() -> [BandEvent] { defer { events = [] }; return events }

    private func fail(_ message: String, at time: Double, retry: Bool = true) {
        let failed = pending?.operation
        pending = nil
        if retry, status.phase == .restoring, !checkingRecoverySchema, !retriedRestore, let failed, failed != .claim {
            // One dropped packet must not leave the band in the recording's mode.
            retriedRestore = true
            operations.insert(failed, at: 0)
            return
        }
        if status.phase == .restoring {
            restoreErrors.append(message)
            // A restarted app must validate the control schema again before
            // writing values remembered from an earlier connection.
            if checkingRecoverySchema { operations = []; checkingRecoverySchema = false }
        }
        else { problem = message; restore(at: time) }
    }

    private func complete(at time: Double) {
        let verified = restoreErrors.isEmpty
        if !verified { problem = ([problem].compactMap { $0 } + restoreErrors).joined(separator: "; ") }
        let message = verified ? (mutated ? "normal band mode restored" : "model unchanged; recording stopped") : "restoration could not be verified"
        publish(.finished, message, verified: verified, at: time)
    }

    private func publish(_ phase: BandModelCaptureStatus.Phase, _ message: String, verified: Bool = false, at time: Double) {
        status = .init(phase: phase, message: message, problem: problem, restorationVerified: verified)
        events.append(BandEvent(.modelCaptureState(status), at: time))
    }
}
