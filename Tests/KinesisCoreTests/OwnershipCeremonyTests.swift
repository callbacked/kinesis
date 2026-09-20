import CryptoKit
import Foundation
import Testing
@testable import KinesisCore

private let deviceCertificate = Data(repeating: 1, count: 967)
private let secondaryCertificate = Data(repeating: 2, count: 889)
private let serial = "TESTSERIAL0001"
private let nonce = Data(0..<16)

private func identityResponsePayload() -> Data {
    BandWire.field(1, deviceCertificate) + BandWire.field(2, Data(serial.utf8))
        + BandWire.field(5, secondaryCertificate)
}

private func identityResponse() throws -> Data {
    try BandWire.frame(channel: 2, words: [0x02003001], payload: identityResponsePayload())
}

private func skipChallengeResponsePayload(_ nonce: Data) -> Data {
    // The captured response payload is exactly 0a10 followed by the 16-byte nonce.
    Data([0x0a, 0x10]) + nonce
}

private func skipChallengeResponse(_ nonce: Data) throws -> Data {
    try BandWire.frame(channel: 2, words: [0x02002001], payload: skipChallengeResponsePayload(nonce))
}

private let pendingSignature = Data([0x30, 0x45, 0x02, 0x20]) + Data(repeating: 3, count: 67)
private let pendingReceipt = #"{"serial":"TESTSERIAL0001","receipt_type":"ServerPendingOwnershipReceipt"}"#
private let deviceSignature = Data([0x30, 0x46, 0x02, 0x21]) + Data(repeating: 4, count: 66)
private let deviceReceipt = #"{"receipt_type":"DevicePendingOwnershipReceipt","additional_data":"{}"}"#
private let finalSignature = Data([0x30, 0x45, 0x02, 0x21]) + Data(repeating: 5, count: 67)
private let finalReceipt = #"{"receipt_type":"ServerFinalOwnershipReceipt"}"#

@Test func ceremonyStartOpensTheIdentityServiceLikeTheCapturedSequence() throws {
    let ceremony = OwnershipCeremony(bandID: "TEST")
    let identityRead = try BandWire.frame(channel: 0x8002, words: [0x81000024, 0x02003000])
    #expect(try ceremony.start() == identityRead)
    let skip = try ceremony.identityRead(payload: identityResponsePayload())
    // The captured SkipChallengeRequest reuses the open service with one word.
    let expectedSkip = try BandWire.frame(channel: 0x8002, words: [0x02002000])
    #expect(skip == expectedSkip)
    let identity = try #require(ceremony.identity)
    #expect(identity.deviceCertificate == deviceCertificate)
    #expect(identity.serial == serial)
    #expect(identity.secondaryCertificate == secondaryCertificate)
}

@Test func theNonceParserAcceptsExactlySixteenBytes() throws {
    let ceremony = OwnershipCeremony(bandID: "TEST")
    _ = try ceremony.identityRead(payload: identityResponsePayload())
    let request = try ceremony.skipChallenge(payload: skipChallengeResponsePayload(nonce))
    #expect(request.nonce == nonce)
    #expect(request.identity.serial == serial)
    #expect(request.appPublicKey == ceremony.appPublicKey)
    #expect(request.appPublicKey.count == 64)
    let short = try BandWire.frame(channel: 2, words: [0x02002001], payload: Data([0x0a, 0x0f]) + Data(0..<15))
    #expect(throws: BandProtocolError.self) { try ceremony.skipChallenge(payload: short) }
}

@Test func ceremonyBuildersMatchTheCapturedStartChangeOwnerFrameLayout() throws {
    let ceremony = OwnershipCeremony(bandID: "TEST")
    _ = try ceremony.identityRead(payload: identityResponsePayload())
    _ = try ceremony.skipChallenge(payload: skipChallengeResponsePayload(nonce))
    let start = try ceremony.pairRequestCompleted(signature: pendingSignature, receipt: pendingReceipt)
    let expectedStart = try BandWire.frame(channel: 0x8002, words: [0x02002002],
        payload: BandWire.field(1, pendingSignature) + BandWire.field(2, Data(pendingReceipt.utf8)))
    #expect(start == expectedStart)
    // The captured payload (fuzz-seeds/startchangeowner.bin) is field 1 = a
    // 71-byte DER signature introduced by 0a 47, then field 2 = a 1777-byte
    // receipt string whose length varint is the three bytes f1 0d.
    let payload = Data(start.dropFirst(8))
    #expect(Array(payload.prefix(4)) == [0x0a, 0x47, 0x30, 0x45])
    #expect(payload[73] == 0x12)
    let longReceipt = String(repeating: "x", count: 1777)
    let long = OwnershipCeremony(bandID: "TEST")
    _ = try long.identityRead(payload: identityResponsePayload())
    _ = try long.skipChallenge(payload: skipChallengeResponsePayload(nonce))
    let longFrame = try long.pairRequestCompleted(signature: pendingSignature, receipt: longReceipt)
    let longPayload = Data(longFrame.dropFirst(8))
    #expect(Array(longPayload[74...75]) == [0xf1, 0x0d])
    #expect(Data(longPayload[76...]) == Data(longReceipt.utf8))
}

@Test func startChangeOwnerResponsesCarrySignatureThenReceiptVerbatim() throws {
    let ceremony = OwnershipCeremony(bandID: "TEST")
    _ = try ceremony.identityRead(payload: identityResponsePayload())
    _ = try ceremony.skipChallenge(payload: skipChallengeResponsePayload(nonce))
    _ = try ceremony.pairRequestCompleted(signature: pendingSignature, receipt: pendingReceipt)
    // The captured StartChangeOwnerResponse holds the signature in field 1 and
    // the device pending receipt string in field 2.
    let pair = try ceremony.startChangeOwner(payload:
        BandWire.field(1, deviceSignature) + BandWire.field(2, Data(deviceReceipt.utf8)))
    #expect(pair.signature == deviceSignature)
    #expect(pair.receipt == deviceReceipt)
}

@Test func finishChangeOwnerUsesTheCapturedFieldMapAndCompleteStoresTheIdentity() throws {
    let band = "TEST-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    let ceremony = OwnershipCeremony(bandID: band)
    _ = try ceremony.identityRead(payload: identityResponsePayload())
    _ = try ceremony.skipChallenge(payload: skipChallengeResponsePayload(nonce))
    _ = try ceremony.pairRequestCompleted(signature: pendingSignature, receipt: pendingReceipt)
    _ = try ceremony.startChangeOwner(payload: BandWire.field(1, deviceSignature) + BandWire.field(2, Data(deviceReceipt.utf8)))
    let bandPoint64 = Data(P256.Signing.PrivateKey().publicKey.x963Representation.dropFirst())
    let finish = try ceremony.pairCompleted(signature: finalSignature, receipt: finalReceipt,
                                            devicePublicKey: bandPoint64)
    let expectedFinish = try BandWire.frame(channel: 0x8002, words: [0x02002004],
        payload: BandWire.field(1, finalSignature) + BandWire.field(2, Data(finalReceipt.utf8)))
    #expect(finish == expectedFinish)
    let enrollment = try ceremony.complete(words: [0x02002005], payload: Data())
    #expect(enrollment.privateKey.rawRepresentation == ceremony.appPrivateKey.rawRepresentation)
    let bandKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + bandPoint64)
    #expect(enrollment.bandPublicKey?.rawRepresentation == bandKey.rawRepresentation)
    let stored = try #require(BandIdentity.enrollment(for: band))
    #expect(stored.privateKey.rawRepresentation == ceremony.appPrivateKey.rawRepresentation)
    #expect(stored.bandPublicKey?.rawRepresentation == bandKey.rawRepresentation)
    // The band must confirm with an empty response; anything else is an error.
    let retried = OwnershipCeremony(bandID: band)
    _ = try retried.identityRead(payload: identityResponsePayload())
    _ = try retried.skipChallenge(payload: skipChallengeResponsePayload(nonce))
    _ = try retried.pairRequestCompleted(signature: pendingSignature, receipt: pendingReceipt)
    _ = try retried.startChangeOwner(payload: BandWire.field(1, deviceSignature) + BandWire.field(2, Data(deviceReceipt.utf8)))
    _ = try retried.pairCompleted(signature: finalSignature, receipt: finalReceipt, devicePublicKey: bandPoint64)
    #expect(throws: BandProtocolError.self) {
        try retried.complete(words: [0x02002005], payload: Data([1]))
    }
}

@Test func ceremonyStepsRejectOutOfOrderResponses() throws {
    let ceremony = OwnershipCeremony(bandID: "TEST")
    // Nothing precedes the identity read, and the nonce waits for it.
    #expect(throws: BandProtocolError.self) {
        try ceremony.skipChallenge(payload: skipChallengeResponsePayload(nonce))
    }
    #expect(throws: BandProtocolError.self) {
        try ceremony.pairRequestCompleted(signature: pendingSignature, receipt: pendingReceipt)
    }
    _ = try ceremony.identityRead(payload: identityResponsePayload())
    // A nonce that isn't sixteen bytes never reaches the HTTP step.
    #expect(throws: BandProtocolError.self) {
        try ceremony.skipChallenge(payload: Data([0x0a, 0x0f]) + Data(0..<15))
    }
    #expect(throws: BandProtocolError.self) {
        try ceremony.pairRequestCompleted(signature: pendingSignature, receipt: pendingReceipt)
    }
    _ = try ceremony.skipChallenge(payload: skipChallengeResponsePayload(nonce))
    _ = try ceremony.pairRequestCompleted(signature: pendingSignature, receipt: pendingReceipt)
    // Identity result codes map onto the reference error strings.
    #expect(OwnershipCeremony.failureMessage(0x1042) == "this band belongs to a different meta account. sign in with that account, or factory reset the band (hold its button for about 16 seconds) to claim it with this one.")
    #expect(OwnershipCeremony.failureMessage(0x1044).contains("signature"))
}

/// A synthetic pairing-mode band with the public scalar-1 transport key.
private struct CeremonyPeer {
    let session: BandSession
    let ceremony: OwnershipCeremony
    var sender: AirShieldCipher
    var receiver: AirShieldReceiver
    var datax = DataXReceiver()
    var cipherBytes = Data()
    let bandKey: P256.Signing.PrivateKey
    let hostPoint: Data
    let hostChallenge: Data
    let bandPoint: Data
    let bandChallenge = Data(0..<16)
    let bandSeed = Data(0..<32)
    let hostSeed: Data

    init(bandID: String) throws {
        ceremony = OwnershipCeremony(bandID: bandID)
        bandKey = P256.Signing.PrivateKey()
        session = try BandSession(ceremony: ceremony)
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
        hostSeed = try enable.bytes(2)
        cipherBytes = Data(output.dropFirst(size))
        let localKey = try P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + hostPoint)
        let secret = try transport.sharedSecretFromKeyAgreement(with: localKey).withUnsafeBytes { Data($0) }
        sender = AirShieldCipher(keys: try AirShieldKeys(secret: secret, challenge: hostChallenge, seed: bandSeed),
            iv: iv, counter: 42)
        receiver = AirShieldReceiver(cipher: AirShieldCipher(keys: try AirShieldKeys(secret: secret,
            challenge: bandChallenge, seed: try enable.bytes(2)), iv: try enable.bytes(3),
            counter: UInt32(try enable.integer(4))))
    }

    mutating func send(_ frame: Data) throws -> (events: [BandEvent], requests: [DataXFrame]) {
        let result = try session.feed(sender.encrypt(frame), at: 100)
        return (result.events, try drain(result.outgoing))
    }

    mutating func drain(_ bytes: Data = Data()) throws -> [DataXFrame] {
        let combined = cipherBytes + bytes
        cipherBytes = Data()
        var frames: [DataXFrame] = []
        for plain in try receiver.feed(combined) { frames += try datax.feed(plain) }
        return frames
    }

    /// The band's own EnableTrustEC proof over the host transcript.
    func proof() throws -> Data {
        let digest = SHA256.hash(data:
            Data(SHA256.hash(data: hostChallenge + hostPoint)) + Data(SHA256.hash(data: bandSeed + bandPoint)))
        let signature = try bandKey.signature(for: digest).rawRepresentation
        return try BandWire.frame(channel: 0x8003, words: [0x81000024, 0x02001001], payload:
            BandWire.field(1, Data(repeating: 7, count: 12)) + BandWire.field(2, signature) + BandWire.field(3, 1))
    }
}

@Test func theSessionRunsTheWholeCeremonyAndRejoinsTheEnrolledStartup() throws {
    let band = "TEST-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    var peer = try CeremonyPeer(bandID: band)
    // After the transport handshake the session opens the identity service.
    let identityRead = try #require(try peer.drain().first)
    #expect(identityRead.channel == 0x8002)
    #expect(identityRead.words == [0x81000024, 0x02003000])
    // IdentityResponse -> SkipChallenge.
    let skip = try peer.send(try identityResponse()).requests
    #expect(skip.count == 1 && skip.first?.channel == 0x8002 && skip.first?.words == [0x02002000])
    // SkipChallengeResponse -> pair_request event with the nonce.
    let challenge = try peer.send(skipChallengeResponse(nonce))
    let request = try #require(challenge.events.compactMap { event -> CeremonyPairRequestData? in
        if case .ceremonyHTTP(.pairRequest(let request)) = event.payload { return request }
        return nil
    }.first)
    #expect(request.nonce == nonce && request.appPublicKey == peer.ceremony.appPublicKey)
    #expect(request.identity.serial == serial)
    // The app's HTTP reply becomes StartChangeOwner on channel 0x8002.
    let startBytes = try peer.session.ceremonyPairRequestCompleted(signature: pendingSignature, receipt: pendingReceipt)
    let start = try #require(try peer.drain(startBytes).first)
    #expect(start.channel == 0x8002 && start.words == [0x02002002])
    #expect(try ProtoFields(start.payload).bytes(2) == Data(pendingReceipt.utf8))
    // StartChangeOwnerResponse -> pair event with the verbatim receipt.
    let response = try peer.send(try BandWire.frame(channel: 2, words: [0x02002003], payload:
        BandWire.field(1, deviceSignature) + BandWire.field(2, Data(deviceReceipt.utf8))))
    let pair = try #require(response.events.compactMap { event -> CeremonyPairData? in
        if case .ceremonyHTTP(.pair(let pair)) = event.payload { return pair }
        return nil
    }.first)
    #expect(pair.receipt == deviceReceipt && pair.signature == deviceSignature)
    // The final receipt becomes FinishChangeOwner; the empty confirmation then
    // hands the fresh identity to the enrolled trust flow.
    let bandPoint64 = Data(peer.bandKey.publicKey.x963Representation.dropFirst())
    let finishBytes = try peer.session.ceremonyPairCompleted(signature: finalSignature, receipt: finalReceipt,
                                                             devicePublicKey: bandPoint64)
    let finish = try #require(try peer.drain(finishBytes).first)
    #expect(finish.channel == 0x8002 && finish.words == [0x02002004])
    let done = try peer.send(try BandWire.frame(channel: 2, words: [0x02002005]))
    let trust = try #require(done.requests.first)
    // The service is already open on 0x8002, so the trust proof uses one word.
    #expect(trust.channel == 0x8002 && trust.words == [0x02001000])
    let trustFields = try ProtoFields(trust.payload)
    let appPoint = Data(peer.ceremony.appPrivateKey.publicKey.x963Representation.dropFirst())
    #expect(try trustFields.bytes(1) == Data(SHA256.hash(data: appPoint)))
    let digest = SHA256.hash(data:
        Data(SHA256.hash(data: peer.bandChallenge + peer.bandPoint))
        + Data(SHA256.hash(data: peer.hostSeed + peer.hostPoint)))
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: try trustFields.bytes(2, count: 64))
    #expect(peer.ceremony.appPrivateKey.publicKey.isValidSignature(signature, for: digest))
    // The stored identity matches the ceremony key and the band key from the receipt.
    let stored = try #require(BandIdentity.enrollment(for: band))
    #expect(stored.privateKey.rawRepresentation == peer.ceremony.appPrivateKey.rawRepresentation)
    #expect(stored.bandPublicKey?.x963Representation == peer.bandKey.publicKey.x963Representation)
    // From here the standard enrolled startup continues: band proof accepted,
    // then EndLinkSetup.
    #expect(try peer.send(try BandWire.frame(channel: 2, words: [0x03001000])).requests.isEmpty)
    let acknowledged = try peer.send(try peer.proof())
    #expect(acknowledged.requests.first?.channel == 3)
    let end = try #require(acknowledged.requests.last)
    #expect(end.channel == 0x8001 && end.words == [0x02001000])
}

@Test func identityResultCodesFailTheCeremonySession() throws {
    var peer = try CeremonyPeer(bandID: "TEST-\(UUID().uuidString)")
    _ = try peer.drain()
    _ = try peer.send(try identityResponse())
    do {
        _ = try peer.send(try BandWire.frame(channel: 2, words: [0x03001043]))
        Issue.record("An ownership result code must fail the ceremony")
    } catch let error as BandProtocolError {
        #expect(error.message.contains("identity"))
    }
}
