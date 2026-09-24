import CryptoKit
import Foundation
import OSLog
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
    private var peerSeed: Data?
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
    /// Gestures (3) are always on. Gyro (6) and orientation (8) stream at 128 Hz each,
    /// which is most of the link's load, so each can be switched while connected.
    private var motion: MotionStreams
    private var streamFields: [Int] { [3] + (motion.gyro ? [6] : []) + (motion.orientation ? [8] : []) }
    private static let allStreamFields = [3, 6, 8]
    private var wantedMotion: MotionStreams?
    private var motionRequest: (id: UInt64, wanted: MotionStreams, sentAt: Double)?
    /// After a restart request: the streams to turn back on once "off" is confirmed.
    private var motionAfterRestart: MotionStreams?
    public var motionStreams: MotionStreams { motion }
    private let streamChannel: UInt16 = 0x8005
    private let configurationChannel: UInt16 = 0x8006
    private let configServiceChannel: UInt16 = 0x8007
    private let batteryChannel: UInt16 = 0x8008
    private var batteryChannelOpened = false
    private var batteryRequestID: UInt64 = 0
    private var batteryRequest: (id: UInt64, deadline: Double)?
    private var batteryUnavailable = false
    private var rawEMG: Bool
    private var rawRequested = false
    private var configServiceOpened = false
    private var rawRequestID: UInt64 = 6
    private enum RawStage { case config, query, update }
    private struct RawRequest {
        let enabled: Bool
        var stage: RawStage
        var id: UInt64
        let deadline: Double
    }
    private var rawRequest: RawRequest?
    public private(set) var rawEMGFrames = 0
    public private(set) var rawEMGBytes = 0
    private enum SetupStage { case link, ceremony, identity, deviceInfo, input }
    private var setupStage = SetupStage.link
    private var enrollment: BandEnrollmentIdentity?
    private let ceremony: OwnershipCeremony?
    private var appTrusted = false
    private var bandTrusted = false
    private var endLinkSent = false
    private var configurationID: UInt64 = 0
    private struct HandRequest {
        let id: UInt64
        let hand: BandHand?
        let reading: Bool
        let deadline: Double
    }
    private var handRequest: HandRequest?
    public private(set) var hand: BandHand?
    private let log = Logger(subsystem: "local.callbacked.kinesis", category: "protocol")
    private var startupFrames = 0

    public init(enrollment: BandEnrollmentIdentity? = nil, ceremony: OwnershipCeremony? = nil, rawEMG: Bool = false,
                motion: MotionStreams = .all) throws {
        self.motion = motion
        self.enrollment = enrollment
        self.ceremony = ceremony
        self.rawEMG = rawEMG
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
                self.peerSeed = peerSeed
                let peerIV = try fields.bytes(3, count: 16)
                let peerBase = try fields.integer(4)
                guard let peerCounter = UInt32(exactly: peerBase) else { throw BandProtocolError("Invalid band packet counter") }
                transmitter = AirShieldCipher(keys: try AirShieldKeys(secret: secret, challenge: peerChallenge, seed: seed), iv: iv, counter: base)
                receiver = AirShieldReceiver(cipher: AirShieldCipher(keys: try AirShieldKeys(secret: secret, challenge: challenge, seed: peerSeed), iv: peerIV, counter: peerCounter))
                if let ceremony {
                    // Enrollment startup runs the ownership ceremony instead of
                    // the identity queries; it rejoins the enrolled flow at trust.
                    setupStage = .ceremony
                    outgoing.append(try encrypt(try ceremony.start()))
                } else if let enrollment {
                    // Enrolled startup replaces the empty identity query with an
                    // EnableTrust proof. Link setup waits for mutual trust.
                    setupStage = .identity
                    outgoing.append(try encrypt(try enableTrust(enrollment)))
                } else {
                    // Complete link setup before opening the input service.
                    outgoing.append(try encrypt(BandWire.frame(channel: 0x8002, words: [0x81000024, 0x02003000])))
                    outgoing.append(try encrypt(BandWire.frame(channel: 0x8001, words: [0x02001000], payload:
                        BandWire.field(1, 1) + BandWire.field(2, Self.random(16)))))
                }
            default: throw BandProtocolError("Unrecognized band setup message")
            }
        }
        if receiver != nil {
            let records = try receiver!.feed(pending)
            pending.removeAll(keepingCapacity: true)
            for plaintext in records {
                authenticatedPackets += 1
                for frame in try datax.feed(plaintext) {
                    events += try input(frame, at: time, outgoing: &outgoing)
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
        var events = engagementEvents(at: time)
        // An unanswered stream change is given up after 8 s, so a later one can go out.
        if let pending = motionRequest, time - pending.sentAt >= 8, !stopping {
            motionRequest = nil
            // A restart gives up only when its own off request fails. An earlier change
            // failing leaves the restart waiting to go out.
            if motionAfterRestart != nil, pending.wanted == .none { motionAfterRestart = nil; wantedMotion = nil }
            events.append(BandEvent(.motionStreams(motion, confirmedAfter: time - pending.sentAt, accepted: false), at: time))
        }
        if let handRequest, time >= handRequest.deadline, !stopping {
            self.handRequest = nil
            hand = nil
            events.append(BandEvent(.handednessFailure("Couldn't confirm the band hand. Reconnect and try again."), at: time))
        }
        if let batteryRequest, time >= batteryRequest.deadline, !stopping {
            self.batteryRequest = nil
            events.append(BandEvent(.batteryStatus(nil), at: time))
        }
        if let rawRequest, time >= rawRequest.deadline, !stopping {
            self.rawRequest = nil
            events.append(BandEvent(.rawEMGFailure("The band didn't confirm the EMG change. Turn readings off, then try again."), at: time))
        }
        return events
    }

    /// Update the existing input subscription. Gestures stay on, and motion stays as it is.
    public func setRawEMGEnabled(_ enabled: Bool, at time: Double) throws -> Data {
        guard !stopping else { throw BandProtocolError("Wait for the band to reconnect before changing readings.") }
        guard rawRequest == nil else { throw BandProtocolError("Wait for the current EMG change to finish.") }
        rawEMG = enabled
        guard streamsEnabled else { return Data() }
        rawRequestID += 1
        rawRequest = RawRequest(enabled: enabled, stage: enabled ? .config : .update,
                                id: rawRequestID, deadline: time + 8)
        if enabled {
            let words: [UInt32] = configServiceOpened ? [] : [0x8100ce56, 0x02000314]
            configServiceOpened = true
            return try encrypt(BandWire.frame(channel: configServiceChannel, words: words,
                payload: BandWire.field(1, rawRequestID) + BandWire.field(5, Data())))
        }
        return try rawStreamUpdate(id: rawRequestID, enabled: false)
    }

    private func rawStreamUpdate(id: UInt64, enabled: Bool) throws -> Data {
        rawRequested = true
        return try encrypt(BandWire.frame(channel: streamChannel, words: [],
            // A motion change in flight is where motion is going: this frame must not undo it.
            payload: BandWire.field(1, id) + BandWire.field(4, streamControl(motionRequest?.wanted ?? motion, raw: enabled))))
    }

    /// Every stream field, on or off explicitly, so no field is left to the band's default.
    private func streamControl(_ motion: MotionStreams, raw: Bool?) -> Data {
        (raw.map { BandWire.field(2, $0 ? 1 : 0) } ?? Data())
            + BandWire.field(3, 1) + BandWire.field(6, motion.gyro ? 1 : 0) + BandWire.field(8, motion.orientation ? 1 : 0)
    }

    /// Asks for these motion streams. Before the subscription it only changes what
    /// the subscription asks for. While another stream change is in flight it waits;
    /// `flushMotion(at:)` sends it when the way is clear.
    public func setMotionStreams(_ wanted: MotionStreams, at time: Double) throws -> Data {
        guard !stopping else { return Data() }
        motionAfterRestart = nil
        wantedMotion = wanted
        return try flushMotion(at: time)
    }

    /// Turns the motion streams off and, once the band confirms, on again.
    public func restartMotionStreams(at time: Double) throws -> Data {
        guard !stopping, streamsEnabled, motionAfterRestart == nil, motion != .none else { return Data() }
        let restore = wantedMotion ?? motion
        wantedMotion = MotionStreams.none
        motionAfterRestart = restore
        return try flushMotion(at: time)
    }

    /// Sends a waiting motion change if nothing else is in flight. Safe to call often.
    public func flushMotion(at time: Double) throws -> Data {
        // While a change is in flight, compare against nothing yet: it may still move `motion`.
        guard !stopping, let wanted = wantedMotion, motionRequest == nil else { return Data() }
        guard wanted != motion else { wantedMotion = nil; return Data() }
        // The subscription has not gone out yet: it will simply ask for these.
        guard setupStage == .input else { motion = wanted; wantedMotion = nil; return Data() }
        guard streamsEnabled, rawRequest == nil, motionRequest == nil else { return Data() }
        rawRequestID += 1
        motionRequest = (rawRequestID, wanted, time)
        return try encrypt(BandWire.frame(channel: streamChannel, words: [],
            payload: BandWire.field(1, rawRequestID) + BandWire.field(4, streamControl(wanted, raw: rawRequested ? rawEMG : nil))))
    }

    public func setHandedness(_ hand: BandHand, at time: Double) throws -> Data {
        guard streamsEnabled, !stopping, self.hand != nil, handRequest == nil else {
            throw BandProtocolError("Wait for the band to report its hand before changing it.")
        }
        dial = PinchDial()
        return try requestHand(hand, reading: false, at: time)
    }

    private func requestHand(_ hand: BandHand?, reading: Bool, at time: Double) throws -> Data {
        let id = configurationID + 1
        // ConfigReq.is_left_handed is field 10. An empty ConfigReq reads current settings.
        let config = reading ? Data() : BandWire.field(10, hand == .left ? 1 : 0)
        let bytes = try encrypt(BandWire.frame(channel: configurationChannel,
            words: configurationID == 0 ? [0x8100ce56, 0x02000314] : [],
            payload: BandWire.field(1, id) + BandWire.field(5, config)))
        configurationID = id
        handRequest = HandRequest(id: id, hand: hand, reading: reading, deadline: time + 5)
        return bytes
    }

    private func receiveHand(_ fields: ProtoFields, at time: Double, outgoing: inout Data) throws -> [BandEvent] {
        guard let request = handRequest, try fields.integer(1) == request.id else { return [] }
        handRequest = nil
        guard time < request.deadline else {
            hand = nil
            return [BandEvent(.handednessFailure("Couldn't confirm the band hand. Reconnect and try again."), at: time)]
        }
        guard try fields.integer(2) == 1 else {
            hand = nil
            return [BandEvent(.handednessFailure("The band couldn't apply its hand setting. Reconnect and try again."), at: time)]
        }
        if !request.reading {
            // Read it again independently; a successful write status alone isn't confirmation.
            outgoing.append(try requestHand(request.hand, reading: true, at: time))
            return []
        }
        guard fields.contains(6) else {
            hand = nil
            return [BandEvent(.handednessFailure("This band didn't report its hand setting."), at: time)]
        }
        let config = try ProtoFields(fields.bytes(6))
        guard config.contains(10), try config.integer(10) <= 1 else {
            hand = nil
            return [BandEvent(.handednessFailure("This band didn't report its hand setting."), at: time)]
        }
        let reported: BandHand = try config.integer(10) == 1 ? .left : .right
        hand = reported
        var events = [BandEvent(.handedness(reported), at: time)]
        if let expected = request.hand, reported != expected {
            events.append(BandEvent(.handednessFailure("The band didn't keep the selected hand. Reconnect and try again."), at: time))
        }
        return events
    }

    /// BatteryInfoReq is an empty read request, separate from sensor subscriptions.
    public func queryBatteryStatus(at time: Double) throws -> Data {
        guard streamsEnabled, !stopping, !batteryUnavailable, batteryRequest == nil else { return Data() }
        batteryRequestID += 1
        batteryRequest = (batteryRequestID, time + 3)
        let words: [UInt32] = batteryChannelOpened ? [] : [0x8100ce56, 0x02000314]
        batteryChannelOpened = true
        return try encrypt(BandWire.frame(channel: batteryChannel, words: words,
            payload: BandWire.field(1, batteryRequestID) + BandWire.field(2, Data())))
    }

    /// Read the existing subscription's status when sensor traffic goes quiet.
    public func queryStreamState() throws -> Data {
        guard streamsEnabled, !stopping, rawRequest == nil else { return Data() }
        return try streamRequest(id: 5, enabled: nil)
    }

    public func stop() throws -> Data {
        guard !stopping else { return Data() }
        stopping = true
        handRequest = nil
        rawRequest = nil
        batteryRequest = nil
        motionRequest = nil
        wantedMotion = nil
        motionAfterRestart = nil
        guard transmitter != nil, setupStage == .input else { return Data() }
        return try streamRequest(id: 4, enabled: false)
    }

    private func encrypt(_ data: Data) throws -> Data {
        guard transmitter != nil else { throw BandProtocolError("Band encryption is not ready") }
        return try transmitter!.encrypt(data)
    }

    /// The confirmed transcript digest:
    /// SHA256(SHA256(receiver challenge || receiver key) || SHA256(sender seed || sender key)).
    private static func trustDigest(challenge: Data, receiver: Data, seed: Data, sender: Data) -> SHA256Digest {
        SHA256.hash(data: Data(SHA256.hash(data: challenge + receiver)) + Data(SHA256.hash(data: seed + sender)))
    }

    /// Host EnableTrust on the identity service channel, replacing the empty
    /// identity query for enrolled bands. The service-open word is only needed
    /// before the first identity exchange on the channel.
    private func enableTrust(_ identity: BandEnrollmentIdentity, serviceOpen: Bool = false) throws -> Data {
        guard let peerKey, let peerChallenge else { throw BandProtocolError("Band encryption is not ready") }
        let digest = Self.trustDigest(challenge: peerChallenge, receiver: peerKey, seed: seed, sender: publicKey)
        let signature = try identity.privateKey.signature(for: digest).rawRepresentation
        let identityPoint = Data(identity.privateKey.publicKey.x963Representation.dropFirst())
        return try BandWire.frame(channel: 0x8002, words: serviceOpen ? [0x02001000] : [0x81000024, 0x02001000],
            payload: BandWire.field(1, Data(SHA256.hash(data: identityPoint))) + BandWire.field(2, signature))
    }

    /// Drive one ownership ceremony response. HTTP steps pause the wire flow
    /// and surface a ceremony event; the app resumes the session with the
    /// server's reply.
    private func receiveCeremony(_ frame: DataXFrame, at time: Double, outgoing: inout Data) throws -> [BandEvent] {
        guard let ceremony, let kind = frame.words.last else { return [] }
        if kind & 0xff000000 == 0x03000000 {
            throw BandProtocolError(OwnershipCeremony.failureMessage(kind & 0xffffff))
        }
        switch kind {
        case 0x02003001:
            outgoing.append(try encrypt(try ceremony.identityRead(payload: frame.payload)))
            return [BandEvent(.ceremonyStage("reading the band identity"), at: time)]
        case 0x02002001:
            let request = try ceremony.skipChallenge(payload: frame.payload)
            return [BandEvent(.ceremonyStage("claiming the band"), at: time),
                    BandEvent(.ceremonyHTTP(.pairRequest(request)), at: time)]
        case 0x02002003:
            let pair = try ceremony.startChangeOwner(payload: frame.payload)
            return [BandEvent(.ceremonyStage("confirming ownership"), at: time),
                    BandEvent(.ceremonyHTTP(.pair(pair)), at: time)]
        case 0x02002005:
            return [try adoptEnrolledIdentity(ceremony.complete(words: frame.words, payload: frame.payload),
                                              outgoing: &outgoing, at: time)]
        default: return []
        }
    }

    /// Swap the just-enrolled identity in and open the enrolled trust flow on
    /// the same channel; the identity service is already open there.
    private func adoptEnrolledIdentity(_ identity: BandEnrollmentIdentity, outgoing: inout Data,
                                       at time: Double) throws -> BandEvent {
        guard ceremony != nil else { throw BandProtocolError("No enrollment is running") }
        self.enrollment = identity
        appTrusted = false
        bandTrusted = false
        endLinkSent = false
        setupStage = .identity
        outgoing.append(try encrypt(try enableTrust(identity, serviceOpen: true)))
        return BandEvent(.ceremonyStage("establishing trust"), at: time)
    }

    /// Resume the ceremony after the `pair_request` HTTP exchange.
    public func ceremonyPairRequestCompleted(signature: Data, receipt: String) throws -> Data {
        guard let ceremony else { throw BandProtocolError("No enrollment is running") }
        return try encrypt(try ceremony.pairRequestCompleted(signature: signature, receipt: receipt))
    }

    /// Resume the ceremony after the `pair` HTTP exchange.
    public func ceremonyPairCompleted(signature: Data, receipt: String, devicePublicKey: Data?) throws -> Data {
        guard let ceremony else { throw BandProtocolError("No enrollment is running") }
        return try encrypt(try ceremony.pairCompleted(signature: signature, receipt: receipt, devicePublicKey: devicePublicKey))
    }

    /// Handle the enrolled identity exchange until both directions trust each
    /// other, then rejoin the shared EndLinkSetup flow.
    private func receiveIdentity(_ frame: DataXFrame, outgoing: inout Data) throws -> [BandEvent] {
        guard let kind = frame.words.last else { return [] }
        if kind & 0xff000000 == 0x03000000, frame.channel == 2 {
            guard kind == 0x03001000 else {
                if kind == 0x03001043 {
                    throw BandIdentityMismatchError(
                        "band enrolled to a different key. forget the stored band identity to reconnect without it.")
                }
                throw BandIdentityMismatchError(
                    "the band rejected the stored identity (\(String(kind, radix: 16))). try reconnecting.")
            }
            appTrusted = true
        } else if kind == 0x02001001, frame.channel & 0x8000 != 0 {
            guard !bandTrusted else { throw BandProtocolError("The band sent a duplicate identity proof") }
            let fields = try ProtoFields(frame.payload)
            guard let peerKey, let peerSeed else { throw BandProtocolError("Band encryption is not ready") }
            let signature = try fields.bytes(2, count: 64)
            if let bandKey = enrollment?.bandPublicKey {
                guard let proof = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
                      bandKey.isValidSignature(proof, for:
                        Self.trustDigest(challenge: challenge, receiver: publicKey, seed: peerSeed, sender: peerKey)) else {
                    throw BandProtocolError("The band's identity proof didn't verify. Try reconnecting.")
                }
            }
            bandTrusted = true
            outgoing.append(try encrypt(BandWire.frame(channel: frame.channel & 0x7fff, words: [0x03001000])))
        } else if kind == 0x02001000, frame.channel == 0x8001, endLinkSent {
            let fields = try ProtoFields(frame.payload)
            guard try fields.requiredInteger(1) == 1, try fields.bytes(2).count == 16 else {
                throw BandProtocolError("Unexpected band link setup response")
            }
            setupStage = .deviceInfo
            outgoing.append(try encrypt(BandWire.frame(channel: 0x8003, words: [0x8100ce56, 0x02000314], payload:
                BandWire.field(1, 1) + BandWire.field(3, Data()))))
            return []
        } else {
            return []
        }
        if appTrusted, bandTrusted, !endLinkSent {
            endLinkSent = true
            outgoing.append(try encrypt(BandWire.frame(channel: 0x8001, words: [0x02001000], payload:
                BandWire.field(1, 1) + BandWire.field(2, Self.random(16)))))
        }
        return []
    }

    private func streamRequest(id: UInt64, enabled: Bool?) throws -> Data {
        let control: Data
        switch enabled {
        case true?: control = streamControl(motion, raw: nil)
        case false?:
            // Stopping turns every stream off, whichever were on.
            control = ((rawRequested ? [2] : []) + Self.allStreamFields).reduce(into: Data()) { $0 += BandWire.field($1, 0) }
        case nil: control = Data()
        }
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

    private func input(_ frame: DataXFrame, at time: Double, outgoing: inout Data) throws -> [BandEvent] {
        if let kind = frame.words.last {
            guard channelTypes.count < 1024 || channelTypes[frame.channel] != nil else {
                throw BandProtocolError("Too many band input channels")
            }
            channelTypes[frame.channel] = kind
        }
        guard let kind = channelTypes[frame.channel] else { return [] }
        if !streaming, startupFrames < 16 {
            startupFrames += 1
            log.info("Band startup response: channel \(frame.channel, privacy: .public), type \(String(kind, radix: 16), privacy: .public), payload bytes \(frame.payload.count, privacy: .public)")
        }
        if ceremony != nil, setupStage == .ceremony, !stopping {
            return try receiveCeremony(frame, at: time, outgoing: &outgoing)
        }
        if enrollment != nil, setupStage == .identity, !stopping {
            return try receiveIdentity(frame, outgoing: &outgoing)
        }
        if kind == 0x02001000, frame.channel == 0x8001, setupStage == .link, !stopping {
            let fields = try ProtoFields(frame.payload)
            guard try fields.requiredInteger(1) == 1 else {
                throw BandProtocolError("The band couldn't finish setting up the connection. Try reconnecting.")
            }
            setupStage = .deviceInfo
            outgoing.append(try encrypt(BandWire.frame(channel: 0x8003, words: [0x8100ce56, 0x02000314], payload:
                BandWire.field(1, 1) + BandWire.field(3, Data()))))
            return []
        }
        if frame.channel & 0x7fff == batteryChannel & 0x7fff, !stopping {
            if kind == 0x0300c001 {
                batteryRequest = nil
                batteryUnavailable = true
                return [BandEvent(.batteryStatus(nil), at: time)]
            }
            if kind == 0x02000315, let request = batteryRequest {
                // Optional status errors must not interrupt gestures or EMG.
                guard let fields = try? ProtoFields(frame.payload),
                      (try? fields.requiredInteger(1)) == request.id else { return [] }
                batteryRequest = nil
                return [BandEvent(.batteryStatus(try? BandBatteryStatus(response: frame.payload)), at: time)]
            }
            return []
        }
        if kind == 0x0300c001, !stopping {
            if frame.channel == 3, setupStage == .deviceInfo {
                throw BandProtocolError("The band rejected gesture setup. Try reconnecting.")
            }
            if let rawRequest, frame.channel == 7 || (frame.channel == 5 && rawRequest.stage != .config) {
                self.rawRequest = nil
                return [BandEvent(.rawEMGFailure("The band rejected the EMG request."), at: time)]
            }
            if frame.channel == 5, setupStage == .input {
                throw BandProtocolError("The band rejected the input subscription. Try reconnecting.")
            }
            if frame.channel == 6, handRequest != nil {
                handRequest = nil
                hand = nil
                return [BandEvent(.handednessFailure("The band couldn't report its hand setting. Reconnect and try again."), at: time)]
            }
            return []
        }
        // Ignore unrelated services without trying to interpret their protobuf schema.
        guard [0x02000315, 0x0200020a, 0x0200020d, 0x0200020f, 0x02000212].contains(kind) else { return [] }
        if kind == 0x02000315, frame.channel == 3, setupStage == .deviceInfo, !stopping {
            let fields = try ProtoFields(frame.payload)
            guard try fields.requiredInteger(1) == 1 else { return [] }
            guard try fields.requiredInteger(2) == 1 else {
                throw BandProtocolError("The band rejected gesture setup. Try reconnecting.")
            }
            setupStage = .input
            outgoing.append(try streamRequest(id: 2, enabled: nil))
            outgoing.append(try streamRequest(id: 3, enabled: true))
            outgoing.append(try requestHand(nil, reading: true, at: time))
            return []
        }
        guard setupStage == .input else { return [] }
        if kind == 0x02000315, frame.channel & 0x7fff == configurationChannel & 0x7fff {
            guard !stopping else { return [] }
            return try receiveHand(ProtoFields(frame.payload), at: time, outgoing: &outgoing)
        }
        if kind == 0x02000315, let pending = rawRequest, !stopping {
            let fields = try ProtoFields(frame.payload)
            let expectedChannel = pending.stage == .config ? configServiceChannel : streamChannel
            if frame.channel & 0x7fff == expectedChannel & 0x7fff, try fields.integer(1) == pending.id {
                guard try fields.integer(2) == 1 else {
                    rawRequest = nil
                    return [BandEvent(.rawEMGFailure("The band rejected the EMG change. Gestures remain requested."), at: time)]
                }
                switch pending.stage {
                case .config:
                    let config: EMGConfiguration
                    do { config = try EMGConfiguration(response: frame.payload) }
                    catch {
                        rawRequest = nil
                        return [BandEvent(.rawEMGFailure("The band didn't provide a readable EMG configuration."), at: time)]
                    }
                    rawRequestID += 1
                    rawRequest?.stage = .query
                    rawRequest?.id = rawRequestID
                    outgoing.append(try streamRequest(id: rawRequestID, enabled: nil))
                    return [BandEvent(.rawEMGConfiguration(config), at: time)]
                case .query:
                    rawRequestID += 1
                    rawRequest?.stage = .update
                    rawRequest?.id = rawRequestID
                    outgoing.append(try rawStreamUpdate(id: rawRequestID, enabled: pending.enabled))
                case .update:
                    rawRequest = nil
                    let flags = try ProtoFields(fields.bytes(5))
                    guard try streamFields.allSatisfy({ try flags.integer($0) == 1 }) else {
                        throw BandProtocolError("The band stopped gesture streams during the EMG change. Reconnect with readings off.")
                    }
                    guard try flags.integer(2) == (pending.enabled ? 1 : 0) else {
                        return [BandEvent(.rawEMGFailure("The band didn't accept EMG alongside gestures."), at: time)]
                    }
                    return [BandEvent(.rawEMGState(pending.enabled), at: time)]
                }
                return []
            }
        }
        if kind == 0x02000315, frame.channel != (streamChannel & 0x7fff) { return [] }
        if kind == 0x02000315 {
            let fields = try ProtoFields(frame.payload)
            let request = try fields.integer(1)
            if let pending = motionRequest, request == pending.id {
                motionRequest = nil
                guard !stopping else { return [] }
                guard try fields.integer(2) == 1, fields.contains(5) else {
                    if motionAfterRestart != nil, pending.wanted != .none {
                        // An earlier change was refused. The restart still goes out, then restores what is on now.
                        motionAfterRestart = motion
                    } else {
                        wantedMotion = nil
                        motionAfterRestart = nil
                    }
                    return [BandEvent(.motionStreams(motion, confirmedAfter: time - pending.sentAt, accepted: false), at: time)]
                }
                let flags = try ProtoFields(fields.bytes(5))
                guard try flags.integer(3) == 1 else { throw BandProtocolError("The band input subscription stopped") }
                motion = MotionStreams(gyro: try flags.integer(6) == 1, orientation: try flags.integer(8) == 1)
                if motion == .none, let restore = motionAfterRestart {
                    motionAfterRestart = nil
                    wantedMotion = restore
                    outgoing.append(try flushMotion(at: time))
                }
                return [BandEvent(.motionStreams(motion, confirmedAfter: time - pending.sentAt, accepted: motion == pending.wanted), at: time)]
            }
            if request == 3 || request == 5 {
                guard !stopping else { return [] }
                guard try fields.integer(2) == 1 else {
                    throw BandProtocolError("The band rejected the input subscription")
                }
                let flags = try ProtoFields(fields.bytes(5))
                streamsEnabled = try streamFields.allSatisfy { try flags.contains($0) && flags.integer($0) == 1 }
                guard streamsEnabled else { throw BandProtocolError("The band input subscription stopped") }
                if request == 3, rawEMG, rawRequest == nil {
                    outgoing.append(try setRawEMGEnabled(true, at: time))
                }
                if !streaming {
                    streaming = true
                    return [BandEvent(.connected, at: time)]
                }
            } else if request == 4, try fields.integer(2) == 1, fields.contains(5) {
                let flags = try ProtoFields(fields.bytes(5))
                stopAcknowledged = try ((rawRequested ? [2] : []) + Self.allStreamFields).allSatisfy { try flags.contains($0) && flags.integer($0) == 0 }
            }
            return []
        }
        guard !stopping else { return [] }
        if kind == 0x0200020a {
            // Keep the original payload for recordings, including unknown encodings.
            rawEMGFrames += 1
            rawEMGBytes += frame.payload.count
            var events: [BandEvent] = []
            if !streaming {
                streaming = true
                events.append(BandEvent(.connected, at: time))
                events.append(BandEvent(.heartbeat, at: time))
                lastHeartbeat = time
            }
            events.append(BandEvent(.rawEMGFrame(frame.payload), at: time))
            events.append(BandEvent(.dataSeen, at: time))
            return events
        }
        let fields = try ProtoFields(frame.payload)
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
                events.append(BandEvent(.gyro(timestamp: timestamp, values: values), at: time))
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
                events.append(BandEvent(.orientation(timestamp: timestamp, values: SIMD4(values.map(Double.init))), at: time))
            }
        }
        events.append(BandEvent(.dataSeen, at: time))
        return events
    }
}
