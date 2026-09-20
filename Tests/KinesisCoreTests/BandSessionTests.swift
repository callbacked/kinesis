import CryptoKit
import Foundation
import Testing
@testable import KinesisCore

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
    }
}

@Test func nativeCryptoMatchesIndependentPythonVectors() throws {
    let keys = try AirShieldKeys(secret: Data(0..<32), challenge: Data(0..<16), seed: Data(32..<64))
    #expect(keys.encryption.withUnsafeBytes { Data($0) } == Data(hex: "5080496832e72e0a4de90f22e7797a3c6277197b4bd29f296bd7142850db1998"))
    let fixedKeys = AirShieldKeys(encryption: Data(0..<32), mac: Data(0..<32))
    let first = Data(hex: "40c9f748fb0f0ae8e0018675352ee743a1e58ccd288d25d27f6e72551887e4aad6fc68175e7287a1eee1")
    let second = Data(hex: "4038cb0decaa0692b900d5962230f8734c8a3de4d262936261f1")
    var receiver = AirShieldReceiver(cipher: AirShieldCipher(keys: fixedKeys, iv: Data(0..<16), counter: .max))
    let wire = first + Data([0x81, 0, 1, 2, 42, 43, 44]) + second
    var decoded: [Data] = []
    for byte in wire { decoded += try receiver.feed(Data([byte])) }
    try receiver.finish()
    #expect(decoded == [Data("first block.....second block....".utf8), Data("last block......".utf8)])
    #expect(receiver.cipher.counter == 1)
    var sender = AirShieldCipher(keys: fixedKeys, iv: Data(0..<16), counter: .max)
    #expect(try sender.encrypt(decoded[0]) == first)
    #expect(try sender.encrypt(decoded[1]) == second)
    for index in [1, 12] {
        var corrupted = first
        corrupted[index] ^= 1
        var bad = AirShieldReceiver(cipher: AirShieldCipher(keys: fixedKeys, iv: Data(0..<16), counter: .max))
        #expect(throws: BandProtocolError.self) { try bad.feed(corrupted) }
        #expect(bad.cipher.counter == .max)
        #expect(bad.cipher.iv == Data(0..<16))
    }
    var truncated = AirShieldReceiver(cipher: AirShieldCipher(keys: fixedKeys, iv: Data(0..<16), counter: .max))
    #expect(try truncated.feed(first.dropLast()).isEmpty)
    #expect(throws: BandProtocolError.self) { try truncated.finish() }
}

/// A synthetic peer using public P-256 scalar 1. All material is generated in tests.
private struct Peer {
    let session: BandSession
    var sender: AirShieldCipher
    var receiver: AirShieldReceiver
    var datax = DataXReceiver()
    var startup: [DataXFrame] = []

    init(completeSetup: Bool = true) throws {
        session = try BandSession()
        let request = try session.request()
        #expect(request.prefix(12) == Data(hex: "806280018100000502000001"))
        let local = try ProtoFields(Data(request.dropFirst(12)))
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
        let point = Data(privateKey.publicKey.x963Representation.dropFirst())
        let challenge = Data(0..<16), seed = Data(0..<32), iv = Data(16..<32)
        let peerRequest = try BandWire.frame(channel: 0x8001, words: [0x81000005, 0x02000001], payload:
            BandWire.field(1, point) + BandWire.field(2, challenge) + BandWire.field(3, 0) + BandWire.field(4, 3))
        let peerEnable = try BandWire.frame(channel: 1, words: [0x02000002], payload:
            BandWire.field(1, point) + BandWire.field(2, seed) + BandWire.field(3, iv) + BandWire.field(4, 42) + BandWire.field(5, 3))
        var output = Data()
        for byte in peerRequest + peerEnable {
            let result = try session.feed(Data([byte]), at: 100)
            output += result.outgoing
            #expect(result.events.isEmpty)
        }
        let size = Int(output.be16(0) & 0x7fff) + 4
        let enable = try ProtoFields(Data(output[8..<size]))
        #expect(try enable.bytes(1) == local.bytes(1))
        #expect(try enable.integer(5) == 3)
        let localKey = try P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + local.bytes(1))
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: localKey).withUnsafeBytes { Data($0) }
        sender = AirShieldCipher(keys: try AirShieldKeys(secret: secret, challenge: local.bytes(2), seed: seed), iv: iv, counter: 42)
        receiver = AirShieldReceiver(cipher: AirShieldCipher(keys: try AirShieldKeys(secret: secret, challenge: challenge, seed: enable.bytes(2)),
            iv: try enable.bytes(3), counter: UInt32(try enable.integer(4))))
        var frames: [DataXFrame] = []
        for plain in try receiver.feed(Data(output.dropFirst(size))) { frames += try datax.feed(plain) }
        startup = frames
        if completeSetup {
            startup += try exchange(channel: 0x8001, kind: 0x02001000,
                payload: BandWire.field(1, 1) + BandWire.field(2, Data(repeating: 1, count: 16))).requests
            startup += try exchange(channel: 3, kind: 0x02000315,
                payload: BandWire.field(1, 1) + BandWire.field(2, 1) + BandWire.field(4, Data())).requests
        }
    }

    mutating func exchange(channel: UInt16, kind: UInt32, payload: Data = Data(), now: Double = 0) throws
        -> (events: [BandEvent], requests: [DataXFrame]) {
        let frame = try BandWire.frame(channel: channel, words: [kind], payload: payload)
        let result = try session.feed(sender.encrypt(frame), at: 100 + now)
        return (result.events, try requests(result.outgoing))
    }

    mutating func send(kind: UInt32, payload: Data, now: Double) throws -> [BandEvent] {
        let frame = try BandWire.frame(channel: kind == 0x02000315 ? 0x5 : 0x8010, words: [kind], payload: payload)
        return try session.feed(sender.encrypt(frame), at: 100 + now).events
    }

    /// The band's own clock for `spin`, in microseconds.
    var stamp: UInt64 = 1_000_000

    /// Keeps motion flowing: one gyro sample every 10 ms, on the band's clock and the Mac's.
    mutating func spin(from start: Double, through end: Double) throws -> [BandEvent] {
        var events: [BandEvent] = []
        var now = start
        while now <= end + 1e-9 {
            stamp += 10_000
            events += try gyro(stamp, now: now)
            now += 0.01
        }
        return events
    }

    mutating func gyro(_ stamp: UInt64, x: Int16 = 1000, now: Double) throws -> [BandEvent] {
        try send(kind: 0x0200020f, payload: BandWire.field(1, stamp) + BandWire.field(2, stamp)
                 + BandWire.field(3, x.littleEndianData + Int16(0).littleEndianData + Int16(0).littleEndianData), now: now)
    }

    mutating func gesture(_ action: UInt64, finger: UInt64 = 2, derived: UInt64 = 0, synthetic: UInt64 = 0, now: Double) throws -> [BandEvent] {
        try send(kind: 0x0200020d, payload: BandWire.field(1, 10) + BandWire.field(2, 20)
                 + BandWire.field(3, finger) + BandWire.field(4, action) + BandWire.field(5, derived)
                 + BandWire.field(12, synthetic), now: now)
    }

    mutating func requests(_ bytes: Data) throws -> [DataXFrame] {
        try receiver.feed(bytes).flatMap { try datax.feed($0) }
    }

    mutating func handReply(id: UInt64, value: UInt64?, status: UInt64 = 1, channel: UInt16 = 6,
                            now: Double = 1) throws -> (events: [BandEvent], requests: [DataXFrame]) {
        let config = (value.map { BandWire.field(10, $0) } ?? Data()) + BandWire.field(2, 2048)
        let payload = BandWire.field(1, id) + BandWire.field(2, status) + BandWire.field(6, config)
        let frame = try BandWire.frame(channel: channel, words: [0x02000315], payload: payload)
        let result = try session.feed(sender.encrypt(frame), at: 100 + now)
        return (result.events, try requests(result.outgoing))
    }
}

@Test func startupWaitsForItsLinkAndDeviceInfoBeforeOpeningInput() throws {
    var peer = try Peer(completeSetup: false)
    #expect(peer.startup.map(\.channel) == [0x8002, 0x8001])
    #expect(peer.session.tick(at: 106).isEmpty)
    let ready = BandWire.field(1, 1) + BandWire.field(2, Data(repeating: 1, count: 16))
    let unrelated = try peer.exchange(channel: 0x8003, kind: 0x02001000, payload: ready)
    #expect(unrelated.requests.isEmpty && unrelated.events.isEmpty)
    let device = try peer.exchange(channel: 0x8001, kind: 0x02001000, payload: ready, now: 7)
    #expect(device.requests.map(\.channel) == [0x8003])
    #expect(device.events.isEmpty)
    let duplicate = try peer.exchange(channel: 0x8001, kind: 0x02001000, payload: ready, now: 7)
    #expect(duplicate.requests.isEmpty)
    for channel: UInt16 in [0x8001, 0x8003] {
        let closed = try peer.exchange(channel: channel, kind: 0x01000000, now: 7)
        #expect(closed.events.isEmpty && closed.requests.isEmpty)
    }
    let wrongID = try peer.exchange(channel: 3, kind: 0x02000315,
        payload: BandWire.field(1, 2) + BandWire.field(2, 1), now: 7)
    #expect(wrongID.requests.isEmpty)
    let accepted = try peer.exchange(channel: 3, kind: 0x02000315,
        payload: BandWire.field(1, 1) + BandWire.field(2, 1) + BandWire.field(4, Data()), now: 7)
    #expect(accepted.requests.map(\.channel) == [0x8005, 0x8005, 0x8006])
    #expect(accepted.events.isEmpty && !peer.session.streamsEnabled)
    let repeatedLink = try peer.exchange(channel: 0x8001, kind: 0x02001000, payload: ready, now: 7)
    let repeatedDevice = try peer.exchange(channel: 3, kind: 0x02000315,
        payload: BandWire.field(1, 1) + BandWire.field(2, 1) + BandWire.field(4, Data()), now: 7)
    #expect(repeatedLink.requests.isEmpty && repeatedLink.events.isEmpty)
    #expect(repeatedDevice.requests.isEmpty && repeatedDevice.events.isEmpty)
    #expect(peer.session.tick(at: 108).isEmpty)
    #expect(reportedHands(try peer.handReply(id: 1, value: 0, now: 9).events) == [.right])
}

@Test(arguments: [false, true])
func startupIgnoresInputUntilDeviceInfoSucceeds(linkReady: Bool) throws {
    var peer = try Peer(completeSetup: false)
    if linkReady {
        _ = try peer.exchange(channel: 0x8001, kind: 0x02001000, payload: BandWire.field(1, 1))
    }
    #expect(try peer.gyro(1_000_000, now: 0).isEmpty)
    #expect(try peer.gesture(1, now: 0.01).isEmpty)
    let orientation = BandWire.field(1, 1) + BandWire.field(2, 1_000_000)
        + BandWire.field(3, Data(hex: "0000000000000000000000000000803f"))
    #expect(try peer.send(kind: 0x02000212, payload: orientation, now: 0.02).isEmpty)
    let flags = BandWire.field(3, 1) + BandWire.field(6, 1) + BandWire.field(8, 1)
    for id: UInt64 in [3, 5] {
        let premature = try peer.exchange(channel: 5, kind: 0x02000315,
            payload: BandWire.field(1, id) + BandWire.field(2, 1) + BandWire.field(5, flags))
        #expect(premature.events.isEmpty && premature.requests.isEmpty)
    }
    #expect(!peer.session.streamsEnabled && peer.session.motionMessages == 0)
    #expect(try peer.session.queryStreamState().isEmpty)
    if !linkReady {
        _ = try peer.exchange(channel: 0x8001, kind: 0x02001000, payload: BandWire.field(1, 1))
    }
    let device = try peer.exchange(channel: 3, kind: 0x02000315,
        payload: BandWire.field(1, 1) + BandWire.field(2, 1) + BandWire.field(4, Data()))
    #expect(device.requests.map(\.channel) == [0x8005, 0x8005, 0x8006])
    let enabled = try peer.exchange(channel: 5, kind: 0x02000315,
        payload: BandWire.field(1, 3) + BandWire.field(2, 1) + BandWire.field(5, flags))
    #expect(enabled.events.contains { if case .connected = $0.payload { true } else { false } })
    #expect(peer.session.streamsEnabled)
    _ = try peer.gyro(1_010_000, now: 0.03)
    #expect(peer.session.motionMessages == 1)
}

@Test func rejectedStartupChannelsFailImmediatelyWithoutReportingReady() throws {
    var peer = try Peer(completeSetup: false)
    _ = try peer.exchange(channel: 0x8001, kind: 0x02001000, payload: BandWire.field(1, 1))
    #expect(throws: BandProtocolError.self) {
        try peer.exchange(channel: 3, kind: 0x0300c001)
    }
    #expect(!peer.session.streamsEnabled)
    var subscribing = try Peer()
    let unrelated = try subscribing.exchange(channel: 7, kind: 0x0300c001)
    #expect(unrelated.events.isEmpty && unrelated.requests.isEmpty)
    #expect(throws: BandProtocolError.self) {
        try subscribing.exchange(channel: 5, kind: 0x0300c001)
    }
    #expect(!subscribing.session.streamsEnabled)
}

@Test(arguments: [false, true])
func stoppingDuringSetupNeverOpensAnInputSubscription(linkReady: Bool) throws {
    var peer = try Peer(completeSetup: false)
    if linkReady {
        _ = try peer.exchange(channel: 0x8001, kind: 0x02001000, payload: BandWire.field(1, 1))
    }
    #expect(try peer.session.stop().isEmpty)
    let late = try peer.exchange(channel: 0x8001, kind: 0x02001000, payload: BandWire.field(1, 1))
    #expect(late.events.isEmpty && late.requests.isEmpty)
    let device = try peer.exchange(channel: 3, kind: 0x02000315,
        payload: BandWire.field(1, 1) + BandWire.field(2, 1) + BandWire.field(4, Data()))
    #expect(device.events.isEmpty && device.requests.isEmpty)
    for channel: UInt16 in [3, 5] {
        let closed = try peer.exchange(channel: channel, kind: 0x0300c001)
        #expect(closed.events.isEmpty && closed.requests.isEmpty)
    }
    #expect(!peer.session.streamsEnabled)
}

private func reportedHands(_ events: [BandEvent]) -> [BandHand] {
    events.compactMap { if case .handedness(let hand) = $0.payload { hand } else { nil } }
}

@Test(arguments: [BandHand.left, .right])
func nativeHandSelectionWritesOnlyHandednessAndChecksAnIndependentReadback(selected: BandHand) throws {
    var peer = try Peer()
    let initial: UInt64 = selected == .left ? 0 : 1
    let desired: UInt64 = selected == .left ? 1 : 0
    let query = try #require(peer.startup.last)
    #expect(query.channel == 0x8006)
    #expect(query.words == [0x8100ce56, 0x02000314])
    #expect(query.payload == Data(hex: "08012a00"))
    #expect(throws: BandProtocolError.self) { try peer.session.setHandedness(selected, at: 100) }
    let read = try peer.handReply(id: 1, value: initial)
    #expect(reportedHands(read.events) == [selected == .left ? .right : .left])
    #expect(read.requests.isEmpty)
    _ = try peer.send(kind: 0x02000315, payload: BandWire.field(1, 3) + BandWire.field(2, 1)
        + BandWire.field(5, BandWire.field(3, 1) + BandWire.field(6, 1) + BandWire.field(8, 1)), now: 1)
    let request = try peer.requests(peer.session.setHandedness(selected, at: 101))
    #expect(request.count == 1)
    #expect(request[0].channel == 0x8006 && request[0].words.isEmpty)
    #expect(request[0].payload == Data([0x08, 0x02, 0x2a, 0x02, 0x50, UInt8(desired)]))
    #expect(throws: BandProtocolError.self) { try peer.session.setHandedness(selected, at: 101) }
    let stale = try peer.handReply(id: 1, value: desired)
    #expect(reportedHands(stale.events).isEmpty && stale.requests.isEmpty)
    let wrongChannel = try peer.handReply(id: 2, value: desired, channel: 7)
    #expect(reportedHands(wrongChannel.events).isEmpty && wrongChannel.requests.isEmpty)
    let written = try peer.handReply(id: 2, value: desired, now: 2)
    #expect(reportedHands(written.events).isEmpty)
    #expect(written.requests.count == 1)
    #expect(written.requests[0].channel == 0x8006)
    #expect(written.requests[0].payload == Data(hex: "08032a00"))
    let confirmed = try peer.handReply(id: 3, value: desired, now: 3)
    #expect(reportedHands(confirmed.events) == [selected])
    #expect(peer.session.hand == selected)
    #expect(confirmed.requests.isEmpty)
}

@Test func nativeHandReadRejectsMissingInvalidAndLateValues() throws {
    for value in [nil, UInt64(2)] {
        var peer = try Peer()
        let result = try peer.handReply(id: 1, value: value)
        #expect(reportedHands(result.events).isEmpty)
        #expect(result.events.contains { if case .handednessFailure = $0.payload { true } else { false } })
        #expect(peer.session.hand == nil)
    }
    var peer = try Peer()
    let expired = peer.session.tick(at: 106)
    #expect(expired.contains { if case .handednessFailure = $0.payload { true } else { false } })
    let late = try peer.handReply(id: 1, value: 1, now: 7)
    #expect(reportedHands(late.events).isEmpty && late.requests.isEmpty)
    #expect(peer.session.hand == nil)
    var unticked = try Peer()
    let delayed = try unticked.handReply(id: 1, value: 1, now: 7)
    #expect(reportedHands(delayed.events).isEmpty && delayed.requests.isEmpty)
    #expect(delayed.events.contains { if case .handednessFailure = $0.payload { true } else { false } })
    #expect(unticked.session.hand == nil)
}

@Test func nativeHandWriteRejectionAndMismatchedReadbackNeverConfirmTheRequestedHand() throws {
    for rejected in [true, false] {
        var peer = try Peer()
        _ = try peer.handReply(id: 1, value: 0)
        _ = try peer.send(kind: 0x02000315, payload: BandWire.field(1, 3) + BandWire.field(2, 1)
            + BandWire.field(5, BandWire.field(3, 1) + BandWire.field(6, 1) + BandWire.field(8, 1)), now: 1)
        _ = try peer.requests(peer.session.setHandedness(.left, at: 101))
        let write = try peer.handReply(id: 2, value: 1, status: rejected ? 2 : 1, now: 2)
        let result = rejected ? write : try peer.handReply(id: 3, value: 0, now: 3)
        #expect(!reportedHands(result.events).contains(.left))
        #expect(result.events.contains { if case .handednessFailure = $0.payload { true } else { false } })
        #expect(result.requests.isEmpty)
        #expect(peer.session.hand != .left)
    }
}

@Test func nativeHandshakeSubscribesAndStopsTheSameStreamsOnTheSameChannel() throws {
    var peer = try Peer()
    #expect(peer.startup.map(\.channel) == [0x8002, 0x8001, 0x8003, 0x8005, 0x8005, 0x8006])
    #expect(peer.startup[0].words == [0x81000024, 0x02003000])
    #expect(peer.startup[1].words == [0x02001000])
    let end = try ProtoFields(peer.startup[1].payload)
    #expect(try end.integer(1) == 1)
    #expect(try end.bytes(2).count == 16)
    #expect(peer.startup[3].words == [0x8100ce56, 0x02000314])
    #expect(peer.startup[4].words.isEmpty)
    let enabled = try ProtoFields(ProtoFields(peer.startup[4].payload).bytes(4))
    for field in [3, 6, 8] { #expect(try enabled.integer(field) == 1) }
    #expect(!enabled.contains(2))
    let stop = try peer.session.stop()
    var frames: [DataXFrame] = []
    for plain in try peer.receiver.feed(stop) { frames += try peer.datax.feed(plain) }
    let frame = try #require(frames.first)
    #expect(frame.channel == 0x8005)
    #expect(frame.words.isEmpty)
    let request = try ProtoFields(frame.payload)
    #expect(try request.integer(1) == 4)
    let disabled = try ProtoFields(request.bytes(4))
    for field in [3, 6, 8] { #expect(try disabled.requiredInteger(field) == 0) }
    let partial = BandWire.field(1, 4) + BandWire.field(2, 1) + BandWire.field(5, BandWire.field(3, 0))
    _ = try peer.send(kind: 0x02000315, payload: partial, now: 1)
    #expect(!peer.session.stopAcknowledged)
    let complete = BandWire.field(1, 4) + BandWire.field(2, 1) + BandWire.field(5,
        BandWire.field(3, 0) + BandWire.field(6, 0) + BandWire.field(8, 0))
    _ = try peer.send(kind: 0x02000315, payload: complete, now: 2)
    #expect(peer.session.stopAcknowledged)
    #expect(try peer.gesture(1, now: 3).isEmpty)
    #expect(try peer.session.stop().isEmpty)
}

@Test(arguments: [UInt64(3), 5])
func lateSubscriptionRepliesDoNotInterruptShutdown(requestID: UInt64) throws {
    let enabled = BandWire.field(3, 1) + BandWire.field(6, 1) + BandWire.field(8, 1)
    let disabled = BandWire.field(3, 0) + BandWire.field(6, 0) + BandWire.field(8, 0)
    let replies = [
        BandWire.field(2, 1) + BandWire.field(5, enabled),
        BandWire.field(2, 2),
        BandWire.field(2, 1) + BandWire.field(5, disabled),
    ]
    for reply in replies {
        var peer = try Peer()
        if requestID == 5 {
            let ready = try peer.exchange(channel: 5, kind: 0x02000315,
                payload: BandWire.field(1, 3) + BandWire.field(2, 1) + BandWire.field(5, enabled))
            #expect(ready.events.contains { if case .connected = $0.payload { true } else { false } })
            let query = try peer.requests(peer.session.queryStreamState())
            #expect(!query.isEmpty)
        }
        #expect(peer.session.streamsEnabled == (requestID == 5))
        let stop = try peer.requests(peer.session.stop())
        #expect(!stop.isEmpty && !peer.session.stopAcknowledged)
        let late = try BandWire.frame(channel: 5, words: [0x02000315],
            payload: BandWire.field(1, requestID) + reply)
        let stopAck = try BandWire.frame(channel: 5,
            payload: BandWire.field(1, 4) + BandWire.field(2, 1) + BandWire.field(5, disabled))
        // A late reply must not prevent the following stop acknowledgement in the same record.
        let result = try peer.session.feed(peer.sender.encrypt(late + stopAck), at: 101)
        #expect(result.events.isEmpty && result.outgoing.isEmpty)
        #expect(peer.session.streamsEnabled == (requestID == 5))
        #expect(peer.session.stopAcknowledged)
        #expect(try peer.session.queryStreamState().isEmpty)
        #expect(try peer.session.stop().isEmpty)
    }
}

private func engagement(_ events: [BandEvent]) -> [Bool] {
    events.compactMap { if case .dialState(let value) = $0.payload { value } else { nil } }
}
private func movement(_ events: [BandEvent]) -> [Double] {
    events.compactMap { if case .dialTurn(let value) = $0.payload { value } else { nil } }
}

@Test func encryptedInputDrivesTheDialAndReleasesOnMotionLoss() throws {
    var peer = try Peer()
    let first = try peer.gyro(1_000_000, now: 0)
    #expect(first.contains { if case .connected = $0.payload { true } else { false } })
    #expect(first.contains { if case .heartbeat = $0.payload { true } else { false } })
    #expect(engagement(try peer.gesture(1, synthetic: 1, now: 0.01)).isEmpty)
    let press = try peer.gesture(1, now: 0.02)
    // A press alone never arms the dial. A tap is over before a hold begins.
    #expect(engagement(press).isEmpty)
    guard case .gesture(let gesture) = press[0].payload else { Issue.record("Missing gesture"); return }
    #expect(gesture.finger == "index" && gesture.action == "press" && !gesture.synthetic)
    #expect(gesture.sequence == 10 && gesture.timestampUs == 20 && gesture.receivedAt == 100.02)
    #expect(engagement(try peer.gesture(0, derived: 9, now: 0.021)).isEmpty)
    // Held with motion flowing, it arms once the pinch has outlasted a tap, and turns from there.
    let held = try peer.spin(from: 0.03, through: 0.22)
    #expect(engagement(held) == [true])
    // Turns are coalesced to one per 20 ms, so the count is not the point. The first one is.
    let turn = movement(held)
    #expect(!turn.isEmpty)
    #expect(abs(try #require(turn.first) - 0.7) < 1e-9)
    // Motion stops arriving: the dial lets go.
    #expect(engagement(peer.session.tick(at: 100.6)) == [false])
    #expect(movement(try peer.spin(from: 0.61, through: 0.61)).isEmpty)
    // A gap in the band's own clock lets go too.
    #expect(engagement(try peer.gesture(1, now: 0.62)).isEmpty)
    #expect(engagement(try peer.spin(from: 0.63, through: 0.82)) == [true])
    peer.stamp += 1_000_000
    #expect(engagement(try peer.spin(from: 0.83, through: 0.83)) == [false])
    #expect(movement(try peer.spin(from: 0.84, through: 0.84)).isEmpty)
    // So does the release.
    #expect(engagement(try peer.gesture(1, now: 0.85)).isEmpty)
    #expect(engagement(try peer.spin(from: 0.86, through: 1.05)) == [true])
    #expect(engagement(try peer.gesture(2, now: 1.06)) == [false])
    #expect(movement(try peer.spin(from: 1.07, through: 1.07)).isEmpty)
}

@Test func theTwoPressesOfADoubleTapNeverArmTheDial() throws {
    var peer = try Peer()
    _ = try peer.spin(from: 0, through: 0.02)
    var events: [BandEvent] = []
    // Two quick pinches with the wrist moving the whole time.
    for start in [0.03, 0.22] {
        events += try peer.gesture(1, now: start)
        events += try peer.spin(from: start + 0.01, through: start + 0.12)
        events += try peer.gesture(2, now: start + 0.13)
        events += try peer.spin(from: start + 0.14, through: start + 0.18)
    }
    #expect(engagement(events).isEmpty && movement(events).isEmpty)
    // The same pinch, held, does arm.
    events = try peer.gesture(1, now: 0.5) + peer.spin(from: 0.51, through: 0.75)
    #expect(engagement(events) == [true] && !movement(events).isEmpty)
}

@Test func nativeFramingPreservesSplitMessagesAndRejectsMalformedInput() throws {
    var receiver = DataXReceiver()
    let payload = Data(0..<40)
    let frame = try BandWire.frame(channel: 0x8005, words: [0x0200020d], payload: payload)
    let head = frame.prefix(13) + Data(repeating: 0xc3, count: 3)
    #expect(try receiver.feed(head).isEmpty)
    let tail = frame.dropFirst(13) + Data(repeating: 0xcd, count: 13)
    let frames = try receiver.feed(tail)
    #expect(frames.map(\.channel) == [0x8005])
    #expect(frames.first?.words == [0x0200020d])
    #expect(frames.first?.payload == payload)
    #expect(throws: BandProtocolError.self) { try ProtoFields(Data([0x08, 0x80])) }
    #expect(throws: BandProtocolError.self) { try ProtoFields(Data([0x08, 1, 0x08, 2])).requiredInteger(1) }
    #expect(throws: BandProtocolError.self) { try ProtoFields(Data([0x1a, 12, 1])) }
    let session = try BandSession()
    #expect(throws: BandProtocolError.self) { try session.feed(Data([0, 0, 0, 0]), at: 0) }
}

@Test func aQuietBandStaysConnectedThroughAcknowledgedStatusQueries() throws {
    var peer = try Peer()
    let flags = BandWire.field(3, 1) + BandWire.field(6, 1) + BandWire.field(8, 1)
    func status(_ id: UInt64) -> Data {
        BandWire.field(1, id) + BandWire.field(2, 1) + BandWire.field(5, flags)
    }
    let started = try peer.send(kind: 0x02000315, payload: status(3), now: 0)
    #expect(started.contains { if case .connected = $0.payload { true } else { false } })
    #expect(started.contains { if case .heartbeat = $0.payload { true } else { false } })
    #expect(peer.session.streamsEnabled)
    #expect(peer.session.motionMessages == 0)
    let query = try peer.session.queryStreamState()
    var frames: [DataXFrame] = []
    for plain in try peer.receiver.feed(query) { frames += try peer.datax.feed(plain) }
    let frame = try #require(frames.first)
    #expect(frame.channel == 0x8005 && frame.words.isEmpty)
    let fields = try ProtoFields(frame.payload)
    #expect(try fields.integer(1) == 5)
    #expect(try fields.bytes(4).isEmpty)
    let reply = try peer.send(kind: 0x02000315, payload: status(5), now: 2)
    #expect(reply.contains { if case .heartbeat = $0.payload { true } else { false } })
    #expect(!reply.contains { if case .connected = $0.payload { true } else { false } })
    #expect(movement(reply).isEmpty)
    _ = try peer.session.stop()
    #expect(try peer.session.queryStreamState().isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["KINESIS_CAPTURE"] != nil))
func nativeDecoderMatchesARecordedBandSession() throws {
    let path = try #require(ProcessInfo.processInfo.environment["KINESIS_CAPTURE"])
    let capture = try String(contentsOfFile: path, encoding: .utf8)
    var peer = try Peer()
    let dateParser = ISO8601DateFormatter()
    dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var expected: [String] = []
    var actual: [String] = []
    var motionCount = 0
    var turns = 0
    var firstTime: Double?
    var lastTime = 0.0
    var firstReplay: ContinuousClock.Instant?
    for line in capture.split(separator: "\n") {
        let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        guard let event = row["event"] as? String else { continue }
        if event == "gesture" {
            let fields = ["sequence", "timestamp_us", "finger", "action", "derived_action", "synthetic"]
            expected.append(fields.map { String(describing: row[$0]!) }.joined(separator: ":"))
        } else if event == "gyro_sample" || event == "orientation_sample" {
            motionCount += 1
        } else if event == "authenticated_packet" {
            let timestamp = try #require(row["timestamp"] as? String)
            let time = try #require(dateParser.date(from: timestamp)).timeIntervalSince1970
            if firstTime == nil { firstTime = time }
            lastTime = time
            let plaintext = Data(hex: try #require(row["plaintext"] as? String))
            if firstReplay == nil { firstReplay = .now }
            // Re-encrypt recorded plaintext with the synthetic peer's fresh keys.
            // No captured session keys or device identifiers are needed by this test.
            let result = try peer.session.feed(peer.sender.encrypt(plaintext), at: time)
            for message in result.events {
                switch message.payload {
                case .gesture(let gesture):
                    actual.append("\(gesture.sequence):\(gesture.timestampUs):\(gesture.finger):\(gesture.action):\(gesture.derivedAction):\(gesture.synthetic ? 1 : 0)")
                case .dialTurn(let delta): if delta != 0 { turns += 1 }
                default: break
                }
            }
        }
    }
    #expect(!expected.isEmpty)
    #expect(actual == expected)
    #expect(peer.session.motionMessages == motionCount)
    #expect(turns > 0)
    let elapsed = try #require(firstReplay).duration(to: .now)
    print("Recorded replay: \(actual.count) gestures, \(motionCount) motion samples, \(turns) dial updates across \(lastTime - (firstTime ?? lastTime))s; decoded in \(elapsed)")
}

@Test func startupMotionDoesNotTurnAnOldPressIntoANewPinch() throws {
    var peer = try Peer()
    #expect(engagement(try peer.gesture(1, now: 0)).isEmpty)
    _ = try peer.gyro(1_000_000, now: 0.01)
    #expect(engagement(try peer.gesture(0, derived: 9, now: 0.02)).isEmpty)
    #expect(movement(try peer.gyro(1_010_000, now: 0.03)).isEmpty)
    // Held long past the arming delay, the old press still never becomes a pinch.
    peer.stamp = 1_010_000
    let stale = try peer.spin(from: 0.04, through: 0.3)
    #expect(engagement(stale).isEmpty && movement(stale).isEmpty)
    _ = try peer.gesture(2, now: 0.31)
    // A press made while motion is flowing does.
    #expect(engagement(try peer.gesture(1, now: 0.32)).isEmpty)
    let fresh = try peer.spin(from: 0.33, through: 0.55)
    #expect(engagement(fresh) == [true] && !movement(fresh).isEmpty)
}

@Test func unknownRepeatedFieldsDoNotBreakKnownGestureMessages() throws {
    var peer = try Peer()
    let payload = BandWire.field(1, 42) + BandWire.field(2, 1000)
        + BandWire.field(3, 1) + BandWire.field(4, 8)
        + BandWire.field(99, 1) + BandWire.field(99, 2)
    let events = try peer.send(kind: 0x0200020d, payload: payload, now: 0)
    let event = try #require(events.first)
    guard case .gesture(let gesture) = event.payload else { Issue.record("Missing gesture"); return }
    #expect(gesture.finger == "thumb" && gesture.action == "left")
    #expect(gesture.sequence == 42 && gesture.timestampUs == 1000)
    #expect(throws: BandProtocolError.self) {
        try peer.send(kind: 0x0200020d, payload: payload + BandWire.field(1, 43), now: 1)
    }
}

@Test func rejectedSubscriptionsFailWithoutReportingAReadyConnection() throws {
    var peer = try Peer()
    #expect(throws: BandProtocolError.self) {
        try peer.send(kind: 0x02000315, payload: BandWire.field(1, 3) + BandWire.field(2, 2), now: 0)
    }
    #expect(!peer.session.streamsEnabled)
}

@Test(arguments: [UInt16(7), 0x8005])
func anotherRPCChannelCannotAcknowledgeTheInputSubscription(channel: UInt16) throws {
    var peer = try Peer()
    let flags = BandWire.field(3, 1) + BandWire.field(6, 1) + BandWire.field(8, 1)
    let payload = BandWire.field(1, 3) + BandWire.field(2, 1) + BandWire.field(5, flags)
    let unrelated = try peer.exchange(channel: channel, kind: 0x02000315, payload: payload)
    #expect(unrelated.events.isEmpty && unrelated.requests.isEmpty)
    #expect(!peer.session.streamsEnabled)
    let accepted = try peer.exchange(channel: 5, kind: 0x02000315, payload: payload)
    #expect(accepted.events.contains { if case .connected = $0.payload { true } else { false } })
    #expect(peer.session.streamsEnabled)
}
