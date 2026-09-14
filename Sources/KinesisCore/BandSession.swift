import CryptoKit
import Foundation
import Security

/// The observed band handshake and input subscription. It never exports session keys.
public final class BandSession {
    private let privateKey: P256.KeyAgreement.PrivateKey
    private let challenge: Data
    private let seed: Data
    private let iv: Data
    private let base: UInt32
    private var peerKey: Data?
    private var peerChallenge: Data?
    private var pending = Data()
    private var transmitter: AirShieldCipher?
    private var receiver: AirShieldReceiver?
    private var datax = DataXReceiver()
    private var channelTypes: [UInt16: UInt32] = [:]
    private var dial = PinchDial()
    private var emittedEngagement = false
    private var dialPending = 0.0
    private var lastDial = -Double.infinity
    private var lastHeartbeat = -Double.infinity
    private var streaming = false
    private var stopping = false
    public private(set) var stopAcknowledged = false
    public private(set) var authenticatedPackets = 0
    public private(set) var motionMessages = 0
    public private(set) var streamsEnabled = false
    // Keep these together: enable, disable, and acknowledgement must agree.
    private let streamFields = [3, 6, 8]
    private let streamChannel: UInt16 = 0x8005

    public init() throws {
        privateKey = P256.KeyAgreement.PrivateKey()
        challenge = try Self.random(16)
        seed = try Self.random(32)
        iv = try Self.random(16)
        base = try Self.random(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    private static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BandProtocolError("Could not generate band session keys") }
        return bytes
    }

    private var publicKey: Data { Data(privateKey.publicKey.x963Representation.dropFirst()) }

    public func request() throws -> Data {
        try BandWire.frame(channel: 0x8001, words: [0x81000005, 0x02000001], payload:
            BandWire.field(1, publicKey) + BandWire.field(2, challenge) + BandWire.field(3, 0)
            + BandWire.field(4, 31) + BandWire.field(7, 16))
    }

    public func feed(_ bytes: Data, at time: Double) throws -> (outgoing: Data, events: [BandEvent]) {
        pending.append(bytes)
        var outgoing = Data()
        var events: [BandEvent] = []
        while receiver == nil, pending.count >= 4 {
            guard pending[0] & 0x80 != 0 else { throw BandProtocolError("Unexpected bytes before band encryption") }
            let size = Int(pending.be16(0) & 0x7fff) + 4
            guard size >= 8 else { throw BandProtocolError("Invalid band setup length") }
            guard pending.count >= size else { break }
            let frame = Data(pending.prefix(size))
            pending = Data(pending.dropFirst(size))
            let offset = frame[2] & 0x80 != 0 ? 8 : 4
            guard size >= offset + 4 else { throw BandProtocolError("Truncated band setup header") }
            let kind = frame.be32(offset)
            let fields = try ProtoFields(Data(frame.dropFirst(offset + 4)))
            let point = try fields.bytes(1, count: 64)
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + point)
            switch kind {
            case 0x02000001:
                guard peerKey == nil, try fields.integer(3) == 0, try fields.integer(4) == 3 else {
                    throw BandProtocolError("Unsupported band encryption parameters")
                }
                peerKey = point
                peerChallenge = try fields.bytes(2, count: 16)
                outgoing.append(try BandWire.frame(channel: 1, words: [0x02000002], payload:
                    BandWire.field(1, publicKey) + BandWire.field(2, seed) + BandWire.field(3, iv)
                    + BandWire.field(4, UInt64(base)) + BandWire.field(5, 3)))
            case 0x02000002:
                guard point == peerKey, let peerChallenge, try fields.integer(5) == 3 else {
                    throw BandProtocolError("Unexpected band encryption response")
                }
                let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
                let peerSeed = try fields.bytes(2, count: 32)
                let peerIV = try fields.bytes(3, count: 16)
                let peerBase = try fields.integer(4)
                guard let peerCounter = UInt32(exactly: peerBase) else { throw BandProtocolError("Invalid band packet counter") }
                transmitter = AirShieldCipher(keys: try AirShieldKeys(secret: secret, challenge: peerChallenge, seed: seed), iv: iv, counter: base)
                receiver = AirShieldReceiver(cipher: AirShieldCipher(keys: try AirShieldKeys(secret: secret, challenge: challenge, seed: peerSeed), iv: peerIV, counter: peerCounter))
                // Empty identity query and EndLinkSetup are required by the observed firmware.
                outgoing.append(try encrypt(BandWire.frame(channel: 0x8002, words: [0x81000024, 0x02003000])))
                outgoing.append(try encrypt(BandWire.frame(channel: 0x8001, words: [0x02001000], payload:
                    BandWire.field(1, 1) + BandWire.field(2, Self.random(16)))))
                outgoing.append(try encrypt(BandWire.frame(channel: 0x8003, words: [0x8100ce56, 0x02000314], payload:
                    BandWire.field(1, 1) + BandWire.field(3, Data()))))
                outgoing.append(try streamRequest(id: 2, enabled: nil))
                outgoing.append(try streamRequest(id: 3, enabled: true))
            default: throw BandProtocolError("Unrecognized band setup message")
            }
        }
        if receiver != nil {
            let records = try receiver!.feed(pending)
            pending.removeAll(keepingCapacity: true)
            for plaintext in records {
                authenticatedPackets += 1
                for frame in try datax.feed(plaintext) {
                    events += try input(frame, at: time)
                }
                if streaming, !stopping, time - lastHeartbeat >= 0.2 {
                    lastHeartbeat = time
                    events.append(BandEvent(.heartbeat, at: time))
                }
            }
        }
        return (outgoing, events)
    }

    public func tick(at time: Double) -> [BandEvent] {
        dial.tick(now: time)
        return engagementEvents(at: time)
    }

    /// Read the existing subscription's status when sensor traffic goes quiet.
    public func queryStreamState() throws -> Data {
        guard streamsEnabled, !stopping else { return Data() }
        return try streamRequest(id: 5, enabled: nil)
    }

    public func stop() throws -> Data {
        guard !stopping else { return Data() }
        stopping = true
        guard transmitter != nil else { return Data() }
        return try streamRequest(id: 4, enabled: false)
    }

    private func encrypt(_ data: Data) throws -> Data {
        guard transmitter != nil else { throw BandProtocolError("Band encryption is not ready") }
        return try transmitter!.encrypt(data)
    }

    private func streamRequest(id: UInt64, enabled: Bool?) throws -> Data {
        let control = enabled.map { enabled in streamFields.reduce(into: Data()) { $0 += BandWire.field($1, enabled ? 1 : 0) } } ?? Data()
        return try encrypt(BandWire.frame(channel: streamChannel, words: id == 2 ? [0x8100ce56, 0x02000314] : [],
            payload: BandWire.field(1, id) + BandWire.field(4, control)))
    }

    private func engagementEvents(at time: Double) -> [BandEvent] {
        guard dial.engaged != emittedEngagement else { return [] }
        emittedEngagement = dial.engaged
        dialPending = 0
        lastDial = -.infinity
        return [BandEvent(.dialState(dial.engaged), at: time)]
    }

    private func input(_ frame: DataXFrame, at time: Double) throws -> [BandEvent] {
        if let kind = frame.words.last {
            guard channelTypes.count < 1024 || channelTypes[frame.channel] != nil else {
                throw BandProtocolError("Too many band input channels")
            }
            channelTypes[frame.channel] = kind
        }
        guard let kind = channelTypes[frame.channel] else { return [] }
        // Ignore unrelated services without trying to interpret their protobuf schema.
        guard [0x02000315, 0x0200020d, 0x0200020f, 0x02000212].contains(kind) else { return [] }
        if kind == 0x02000315, frame.channel & 0x7fff != streamChannel & 0x7fff { return [] }
        let fields = try ProtoFields(frame.payload)
        if kind == 0x02000315 {
            let request = try fields.integer(1)
            if request == 3 || request == 5 {
                guard try fields.integer(2) == 1 else {
                    throw BandProtocolError("The band rejected the input subscription")
                }
                let flags = try ProtoFields(fields.bytes(5))
                streamsEnabled = try streamFields.allSatisfy { try flags.contains($0) && flags.integer($0) == 1 }
                guard streamsEnabled else { throw BandProtocolError("The band input subscription stopped") }
                if !streaming, !stopping {
                    streaming = true
                    return [BandEvent(.connected, at: time)]
                }
            } else if request == 4, try fields.integer(2) == 1, fields.contains(5) {
                let flags = try ProtoFields(fields.bytes(5))
                stopAcknowledged = try streamFields.allSatisfy { try flags.contains($0) && flags.integer($0) == 0 }
            }
            return []
        }
        guard !stopping else { return [] }
        let sequence = try fields.requiredInteger(1)
        let timestamp = try fields.requiredInteger(2)
        var events: [BandEvent] = []
        if kind == 0x0200020d {
            func name(_ field: Int, _ names: [String]) throws -> String {
                let value = try fields.integer(field)
                return value < names.count ? names[Int(value)] : "unrecognized:\(value)"
            }
            let gesture = try BandGesture(sequence: sequence, timestampUs: timestamp,
                finger: name(3, ["unknown", "thumb", "index", "middle", "notApplicable"]),
                action: name(4, ["unknown", "press", "release", "tap", "doubletap", "click", "up", "down", "left", "right", "wake", "swipeIn", "swipeOut", "ia", "partialPress", "partialRelease", "partialClick", "partialUp", "partialDown", "partialLeft", "partialRight"]),
                derivedAction: name(5, ["unknown", "singleTap", "doubleTap", "buttonHold", "buttonRelease", "buttonUp", "buttonDown", "buttonLeft", "buttonRight", "buttonPress", "buttonHoldRelease"]),
                synthetic: fields.integer(12) != 0, receivedAt: time)
            events.append(BandEvent(.gesture(gesture), at: time))
            dial.gesture(gesture, now: time)
            events += engagementEvents(at: time)
        } else {
            let bytes = try fields.bytes(3, count: kind == 0x0200020f ? 6 : 16)
            motionMessages += 1
            if !streaming {
                streaming = true
                events.append(BandEvent(.connected, at: time))
                events.append(BandEvent(.heartbeat, at: time))
                lastHeartbeat = time
            }
            if kind == 0x0200020f {
                let values = bytes.withUnsafeBytes { raw in SIMD3<Double>((0..<3).map {
                    Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)))
                }) }
                let delta = dial.gyro(timestamp: timestamp, values: values, now: time)
                events += engagementEvents(at: time)
                if let delta {
                    dialPending += delta
                    if time - lastDial >= 0.02 {
                        events.append(BandEvent(.dialTurn(dialPending), at: time))
                        lastDial = time
                        dialPending = 0
                    }
                }
            } else {
                let values = bytes.withUnsafeBytes { raw in (0..<4).map {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
                } }
                guard values.allSatisfy(\.isFinite), (0.9...1.1).contains(values.reduce(0) { $0 + $1 * $1 }) else {
                    throw BandProtocolError("Invalid band orientation sample")
                }
            }
        }
        return events
    }
}
