import CryptoKit
import Foundation
import Testing
@testable import KinesisCore

/// A synthetic enrolled band. Its transport key uses public P-256 scalar 1 and
/// every identity key is generated in the test.
private struct EnrolledPeer {
    let session: BandSession
    var sender: AirShieldCipher
    var receiver: AirShieldReceiver
    var datax = DataXReceiver()
    let appKey: P256.Signing.PrivateKey
    let bandKey: P256.Signing.PrivateKey
    let hostPoint: Data
    let hostChallenge: Data
    let bandPoint: Data
    let bandChallenge = Data(0..<16)
    let bandSeed = Data(0..<32)

    init(bandKeyInRecord: Bool = true) throws {
        appKey = P256.Signing.PrivateKey()
        bandKey = P256.Signing.PrivateKey()
        session = try BandSession(enrollment: BandEnrollmentIdentity(
            privateKey: appKey, bandPublicKey: bandKeyInRecord ? bandKey.publicKey : nil))
        let request = try session.request()
        let local = try ProtoFields(Data(request.dropFirst(12)))
        hostPoint = try local.bytes(1)
        hostChallenge = try local.bytes(2)
        let transport = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
        bandPoint = Data(transport.publicKey.x963Representation.dropFirst())
        let iv = Data(16..<32)
        let peerRequest = try BandWire.frame(channel: 0x8001, words: [0x81000005, 0x02000001], payload:
            BandWire.field(1, bandPoint) + BandWire.field(2, bandChallenge) + BandWire.field(3, 0) + BandWire.field(4, 3))
        let peerEnable = try BandWire.frame(channel: 1, words: [0x02000002], payload:
            BandWire.field(1, bandPoint) + BandWire.field(2, bandSeed) + BandWire.field(3, iv)
            + BandWire.field(4, 42) + BandWire.field(5, 3))
        var output = Data()
        for byte in peerRequest + peerEnable {
            output += try session.feed(Data([byte]), at: 100).outgoing
        }
        let size = Int(output.be16(0) & 0x7fff) + 4
        let enable = try ProtoFields(Data(output[8..<size]))
        let localKey = try P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + hostPoint)
        let secret = try transport.sharedSecretFromKeyAgreement(with: localKey).withUnsafeBytes { Data($0) }
        sender = AirShieldCipher(keys: try AirShieldKeys(secret: secret, challenge: hostChallenge, seed: bandSeed),
            iv: iv, counter: 42)
        receiver = AirShieldReceiver(cipher: AirShieldCipher(keys: try AirShieldKeys(secret: secret,
            challenge: bandChallenge, seed: try enable.bytes(2)), iv: try enable.bytes(3),
            counter: UInt32(try enable.integer(4))))
        var frames: [DataXFrame] = []
        for plain in try receiver.feed(Data(output.dropFirst(size))) { frames += try datax.feed(plain) }
        // Enrolled startup replaces the empty identity query with one EnableTrust proof.
        #expect(frames.count == 1)
        let proof = try #require(frames.first)
        #expect(proof.channel == 0x8002)
        #expect(proof.words == [0x81000024, 0x02001000])
        let fields = try ProtoFields(proof.payload)
        let appPoint = Data(appKey.publicKey.x963Representation.dropFirst())
        #expect(try fields.bytes(1) == Data(SHA256.hash(data: appPoint)))
        // Independently rebuild the confirmed transcript digest and verify the proof.
        let digest = Self.digest(challenge: bandChallenge, receiver: bandPoint, seed: try enable.bytes(2), sender: hostPoint)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: fields.bytes(2, count: 64))
        #expect(appKey.publicKey.isValidSignature(signature, for: digest))
    }

    /// SHA256(SHA256(receiver challenge || receiver key) || SHA256(sender seed || sender key)).
    static func digest(challenge: Data, receiver: Data, seed: Data, sender: Data) -> SHA256Digest {
        SHA256.hash(data: Data(SHA256.hash(data: challenge + receiver)) + Data(SHA256.hash(data: seed + sender)))
    }

    mutating func send(_ frame: Data) throws -> [DataXFrame] {
        try requests(session.feed(sender.encrypt(frame), at: 100).outgoing)
    }

    mutating func requests(_ bytes: Data) throws -> [DataXFrame] {
        try receiver.feed(bytes).flatMap { try datax.feed($0) }
    }

    /// The band's EnableTrustEC proof over the host transcript.
    func proof(signingKey: P256.Signing.PrivateKey? = nil) throws -> Data {
        let digest = Self.digest(challenge: hostChallenge, receiver: hostPoint, seed: bandSeed, sender: bandPoint)
        let signature = try (signingKey ?? bandKey).signature(for: digest).rawRepresentation
        return try BandWire.frame(channel: 0x8003, words: [0x81000024, 0x02001001], payload:
            BandWire.field(1, Data(repeating: 7, count: 12)) + BandWire.field(2, signature) + BandWire.field(3, 1))
    }

    func result(_ code: UInt32) throws -> Data {
        try BandWire.frame(channel: 2, words: [code])
    }
}

@Test(arguments: [false, true])
func enrolledStartupVerifiesBothTrustDirectionsBeforeLinkSetup(proofFirst: Bool) throws {
    var peer = try EnrolledPeer()
    let first: [DataXFrame], second: [DataXFrame]
    if proofFirst {
        first = try peer.send(try peer.proof())
        second = try peer.send(try peer.result(0x03001000))
        // The band proof is acknowledged at once, but link setup waits for the result.
        #expect(first.map(\.words) == [[0x03001000]])
        #expect(first.map(\.channel) == [3])
        let end = try #require(second.first)
        #expect(second.count == 1 && end.channel == 0x8001 && end.words == [0x02001000])
    } else {
        first = try peer.send(try peer.result(0x03001000))
        second = try peer.send(try peer.proof())
        #expect(first.isEmpty)
        #expect(second.count == 2)
        #expect(second.first?.channel == 3)
        #expect(second.first?.words == [0x03001000])
        let end = try #require(second.last)
        #expect(end.channel == 0x8001 && end.words == [0x02001000])
    }
    let endFields = try ProtoFields(try #require((proofFirst ? second.first : second.last)).payload)
    #expect(try endFields.integer(1) == 1)
    #expect(try endFields.bytes(2).count == 16)
    // The band's link-setup acknowledgement reopens the shared startup flow.
    let endAck = try peer.send(try BandWire.frame(channel: 0x8001, words: [0x02001000],
        payload: BandWire.field(1, 1) + BandWire.field(2, Data(repeating: 1, count: 16))))
    #expect(endAck.count == 1)
    #expect(endAck.first?.channel == 0x8003)
    let info = try peer.send(try BandWire.frame(channel: 3, words: [0x02000315],
        payload: BandWire.field(1, 1) + BandWire.field(2, 1) + BandWire.field(4, Data())))
    #expect(info.map(\.channel) == [0x8005, 0x8005, 0x8006])
    let flags = BandWire.field(3, 1) + BandWire.field(6, 1) + BandWire.field(8, 1)
    let enabled = try peer.send(try BandWire.frame(channel: 5, words: [0x02000315],
        payload: BandWire.field(1, 3) + BandWire.field(2, 1) + BandWire.field(5, flags)))
    #expect(enabled.isEmpty)
    #expect(peer.session.streamsEnabled)
}

@Test func aDifferentKeyRejectionSurfacesTheIdentityError() throws {
    var peer = try EnrolledPeer()
    do {
        _ = try peer.send(try peer.result(0x03001043))
        Issue.record("A different-key rejection must fail the session")
    } catch let error as BandIdentityMismatchError {
        #expect(error.message.contains("band enrolled to a different key"))
    }
    #expect(!peer.session.streamsEnabled)
}

@Test func aBandProofFromTheWrongKeyIsNeverAcknowledged() throws {
    var peer = try EnrolledPeer()
    #expect(try peer.send(try peer.result(0x03001000)).isEmpty)
    #expect(throws: BandProtocolError.self) {
        try peer.send(peer.proof(signingKey: P256.Signing.PrivateKey()))
    }
    // The rejected proof left no acknowledgement or link setup behind.
    let retried = try peer.send(try peer.proof())
    #expect(retried.map(\.words) == [[0x03001000], [0x02001000]])
}

@Test func anUnverifiableBandProofIsAcceptedWhenNoRecordIsStored() throws {
    var peer = try EnrolledPeer(bandKeyInRecord: false)
    #expect(try peer.send(try peer.result(0x03001000)).isEmpty)
    // Signed by a key that matches no stored record; band acceptance is what matters.
    let frames = try peer.send(try peer.proof(signingKey: P256.Signing.PrivateKey()))
    #expect(frames.map(\.words) == [[0x03001000], [0x02001000]])
}

@Test func legacyStartupNeverChangesWithoutAnIdentity() throws {
    let session = try BandSession()
    _ = try session.request()
    let transport = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
    let point = Data(transport.publicKey.x963Representation.dropFirst())
    let peerRequest = try BandWire.frame(channel: 0x8001, words: [0x81000005, 0x02000001], payload:
        BandWire.field(1, point) + BandWire.field(2, Data(0..<16)) + BandWire.field(3, 0) + BandWire.field(4, 3))
    let peerEnable = try BandWire.frame(channel: 1, words: [0x02000002], payload:
        BandWire.field(1, point) + BandWire.field(2, Data(0..<32)) + BandWire.field(3, Data(16..<32))
        + BandWire.field(4, 42) + BandWire.field(5, 3))
    var output = Data()
    for byte in peerRequest + peerEnable { output += try session.feed(Data([byte]), at: 100).outgoing }
    // Without an identity the legacy wire shape stays: an empty identity query
    // and EndLinkSetup, two encrypted frames instead of one EnableTrust proof.
    var records = 0
    var outgoing = output.dropFirst(Int(output.be16(0) & 0x7fff) + 4)
    while outgoing.count >= 10, outgoing[outgoing.startIndex] == 0x40 {
        let size = 10 + (Int(outgoing[outgoing.startIndex + 9]) + 1) * 16
        guard outgoing.count >= size else { break }
        records += 1
        outgoing = outgoing.dropFirst(size)
    }
    #expect(records == 2 && outgoing.isEmpty)
}

private func recordJSON(key: P256.Signing.PrivateKey, bandPoint: Data) -> Data {
    Data("""
    {"AppPrivateKey":"\(key.rawRepresentation.base64EncodedString())",\
    "AppPublicKey":"\(Data(key.publicKey.x963Representation.dropFirst()).base64EncodedString())",\
    "AppECPubicKey":"\(bandPoint.base64EncodedString())"}
    """.utf8)
}

@Test func keychainIdentityRoundTripsPerBand() throws {
    let band = "TEST-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    #expect(!BandIdentity.exists(for: band))
    #expect(BandIdentity.enrollment(for: band) == nil)
    let key = try BandIdentity.generate(for: band)
    #expect(BandIdentity.exists(for: band))
    let loaded = try #require(BandIdentity.loadPrivateKey(for: band))
    #expect(loaded.rawRepresentation == key.rawRepresentation)
    let bandKey = P256.Signing.PrivateKey()
    let record = try BandIdentity.record(recordJSON(key: key,
        bandPoint: Data(bandKey.publicKey.x963Representation.dropFirst())))
    try BandIdentity.save(key, bandKey: record.bandPublicKey, for: band)
    let enrollment = try #require(BandIdentity.enrollment(for: band))
    #expect(enrollment.privateKey.rawRepresentation == key.rawRepresentation)
    #expect(enrollment.bandPublicKey?.rawRepresentation == record.bandPublicKey.rawRepresentation)
    BandIdentity.delete(for: band)
    #expect(!BandIdentity.exists(for: band))
    #expect(BandIdentity.loadBandKey(for: band) == nil)
    #expect(BandIdentity.enrollment(for: band) == nil)
}

@Test func identityRecordMustMatchItsKeyFile() throws {
    let bandKey = P256.Signing.PrivateKey()
    let mismatched = try BandIdentity.record(recordJSON(key: P256.Signing.PrivateKey(),
        bandPoint: Data(bandKey.publicKey.x963Representation.dropFirst())))
    #expect(!mismatched.bandPublicKey.rawRepresentation.isEmpty)
    let broken = Data("""
    {"AppPrivateKey":"AAAA","AppPublicKey":"AAAA","AppECPubicKey":"AAAA"}
    """.utf8)
    #expect(throws: BandProtocolError.self) { try BandIdentity.record(broken) }
    #expect(throws: BandProtocolError.self) { try BandIdentity.record(Data("not json".utf8)) }
}
