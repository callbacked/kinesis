import CryptoKit
import Foundation

/// The identity a band in pairing mode reports during the ownership ceremony.
/// The three values travel verbatim to the ownership HTTP endpoints.
public struct BandIdentityInfo: Sendable {
    public let deviceCertificate: Data
    public let serial: String
    public let secondaryCertificate: Data

    public init(deviceCertificate: Data, serial: String, secondaryCertificate: Data) {
        self.deviceCertificate = deviceCertificate
        self.serial = serial
        self.secondaryCertificate = secondaryCertificate
    }
}

/// What the app must send to `pair_request` after the band hands out a nonce.
public struct CeremonyPairRequestData: Sendable {
    public let identity: BandIdentityInfo
    public let nonce: Data
    public let appPublicKey: Data

    public init(identity: BandIdentityInfo, nonce: Data, appPublicKey: Data) {
        self.identity = identity
        self.nonce = nonce
        self.appPublicKey = appPublicKey
    }
}

/// What the app must send to `pair` after the band accepts the pending receipt.
public struct CeremonyPairData: Sendable {
    public let receipt: String
    public let signature: Data

    public init(receipt: String, signature: Data) {
        self.receipt = receipt
        self.signature = signature
    }
}

/// A request the band ceremony cannot answer by itself: the app performs the
/// ownership HTTP exchange and resumes the session with `CeremonyCompletion`.
public enum CeremonyHTTPRequest: Sendable {
    case pairRequest(CeremonyPairRequestData)
    case pair(CeremonyPairData)
}

/// The parsed result of one ownership HTTP exchange, fed back into the session.
public enum CeremonyCompletion: Sendable {
    case pairRequest(signature: Data, receipt: String)
    case pair(signature: Data, receipt: String, devicePublicKey: Data?)
}

/// The BLE side of the enrollment ceremony, one step per band response. The
/// frames follow the captured live sequence: the identity read opens service
/// 0x24 on channel 0x8002, later requests reuse the open service.
public final class OwnershipCeremony {
    public enum Stage: Equatable, Sendable {
        case identityRead, skipChallenge, startChangeOwner, pair, finishChangeOwner, done
    }

    public private(set) var stage: Stage = .identityRead
    public let bandID: String
    /// A fresh app identity for this attempt. It is stored only after the band
    /// confirms the ownership change.
    public let appPrivateKey: P256.Signing.PrivateKey
    public private(set) var identity: BandIdentityInfo?
    public private(set) var nonce: Data?
    private var devicePublicKey: Data?

    public init(bandID: String, appPrivateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.bandID = bandID
        self.appPrivateKey = appPrivateKey
    }

    /// The raw 64-byte point of the fresh app identity public key.
    public var appPublicKey: Data { Data(appPrivateKey.publicKey.x963Representation.dropFirst()) }

    /// The identity read that opens the identity service on channel 0x8002.
    public func start() throws -> Data {
        guard stage == .identityRead else { throw BandProtocolError("The enrollment is past its identity read") }
        return try BandWire.frame(channel: 0x8002, words: [0x81000024, 0x02003000])
    }

    /// Parse the IdentityResponse (fields 1, 2, 5) and return SkipChallenge.
    public func identityRead(payload: Data) throws -> Data {
        guard stage == .identityRead else { throw BandProtocolError("The band sent an unexpected identity response") }
        let fields = try ProtoFields(payload)
        let certificate = try fields.bytes(1)
        let serialBytes = try fields.bytes(2)
        let secondary = try fields.bytes(5)
        guard certificate.count > 256, secondary.count > 256,
              let serial = String(data: serialBytes, encoding: .ascii), !serial.isEmpty else {
            throw BandProtocolError("The band didn't report a usable identity")
        }
        identity = BandIdentityInfo(deviceCertificate: certificate, serial: serial, secondaryCertificate: secondary)
        stage = .skipChallenge
        return try BandWire.frame(channel: 0x8002, words: [0x02002000])
    }

    /// Parse the SkipChallengeResponse: field 1 holds the 16-byte ownership nonce.
    public func skipChallenge(payload: Data) throws -> CeremonyPairRequestData {
        guard stage == .skipChallenge, let identity else {
            throw BandProtocolError("The band sent an unexpected challenge response")
        }
        let nonce = try ProtoFields(payload).bytes(1, count: 16)
        self.nonce = nonce
        stage = .startChangeOwner
        return CeremonyPairRequestData(identity: identity, nonce: nonce, appPublicKey: appPublicKey)
    }

    /// Build StartChangeOwner: field 1 is the receipt signature (DER), field 2
    /// the pending receipt string verbatim, exactly as the captured frame.
    public func pairRequestCompleted(signature: Data, receipt: String) throws -> Data {
        guard stage == .startChangeOwner else { throw BandProtocolError("The enrollment isn't waiting for its claim") }
        guard !signature.isEmpty, !receipt.isEmpty else {
            throw BandProtocolError("The server didn't return a pending ownership receipt")
        }
        stage = .pair
        return try BandWire.frame(channel: 0x8002, words: [0x02002002],
            payload: BandWire.field(1, signature) + BandWire.field(2, Data(receipt.utf8)))
    }

    /// Parse the band's StartChangeOwnerResponse: field 1 signature, field 2
    /// the device pending receipt string verbatim.
    public func startChangeOwner(payload: Data) throws -> CeremonyPairData {
        guard stage == .pair else { throw BandProtocolError("The band sent an unexpected ownership response") }
        let fields = try ProtoFields(payload)
        let signature = try fields.bytes(1)
        guard let receipt = String(data: try fields.bytes(2), encoding: .utf8), !receipt.isEmpty else {
            throw BandProtocolError("The band didn't return its pending ownership receipt")
        }
        stage = .finishChangeOwner
        return CeremonyPairData(receipt: receipt, signature: signature)
    }

    /// Build FinishChangeOwner: same field map as StartChangeOwner.
    public func pairCompleted(signature: Data, receipt: String, devicePublicKey: Data?) throws -> Data {
        guard stage == .finishChangeOwner else { throw BandProtocolError("The enrollment isn't waiting for its final receipt") }
        guard !signature.isEmpty, !receipt.isEmpty else {
            throw BandProtocolError("The server didn't return a final ownership receipt")
        }
        // the reference app tolerates a missing device key here; verification
        // of the band's trust proof then stays advisory for this band
        self.devicePublicKey = devicePublicKey
        stage = .done
        return try BandWire.frame(channel: 0x8002, words: [0x02002004],
            payload: BandWire.field(1, signature) + BandWire.field(2, Data(receipt.utf8)))
    }

    /// Confirm the empty FinishChangeOwnerResponse, store the fresh app key
    /// with the band's identity key under the band identifier, and hand the
    /// identity to the enrolled startup.
    public func complete(words: [UInt32], payload: Data) throws -> BandEnrollmentIdentity {
        guard stage == .done else {
            throw BandProtocolError("The enrollment isn't ready to finish")
        }
        guard words == [0x02002005], payload.isEmpty else {
            throw BandProtocolError("The band didn't confirm the ownership change")
        }
        var bandKey: P256.Signing.PublicKey?
        if let devicePublicKey, devicePublicKey.count == 64 {
            bandKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + devicePublicKey)
        }
        try BandIdentity.save(appPrivateKey, bandKey: bandKey, for: bandID)
        return BandEnrollmentIdentity(privateKey: appPrivateKey, bandPublicKey: bandKey)
    }

    /// The reference error map for identity service result codes.
    /// How to wipe a band completely. Forgetting it in the app clears only the Mac's side.
    public static let factoryResetHint = "hold its button for about 16 seconds"

    public static func failureMessage(_ code: UInt32) -> String {
        switch code {
        case 0x1040: return "the band rejected the ownership receipt."
        case 0x1041: return "the band rejected the ownership challenge."
        case 0x1042: return "this band belongs to a different meta account. sign in with that account, or factory reset the band (\(factoryResetHint)) to claim it with this one."
        case 0x1043: return "the band rejected this app's identity."
        case 0x1044: return "the band rejected a signature."
        case 0x1045: return "the band rejected the receipt timing."
        case 0xd001, 0xd004, 0xd021: return "the band couldn't read the ownership request."
        case 0xc001: return "the band has no identity service."
        case 0xc004: return "the band couldn't parse the ownership request."
        default: return "the band reported an ownership error (\(String(code, radix: 16)))."
        }
    }
}
