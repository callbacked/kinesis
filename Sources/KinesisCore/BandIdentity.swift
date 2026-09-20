import CryptoKit
import Foundation
import Security

/// The identity kinesis uses to prove band ownership on an enrolled band.
/// The private key signs the host `EnableTrust` proof. The optional band key
/// is the band's own identity public key from a recovered record; when it is
/// present, the band's `EnableTrustEC` proof is verified before it is
/// acknowledged.
public struct BandEnrollmentIdentity: Sendable {
    public let privateKey: P256.Signing.PrivateKey
    public let bandPublicKey: P256.Signing.PublicKey?

    public init(privateKey: P256.Signing.PrivateKey, bandPublicKey: P256.Signing.PublicKey? = nil) {
        self.privateKey = privateKey
        self.bandPublicKey = bandPublicKey
    }
}

/// The band answered an identity result that rejects our stored key. The
/// connection surfaces the message and falls back to the legacy startup
/// without an identity on its next attempt.
public struct BandIdentityMismatchError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One keychain item per band: a P-256 signing key stored as its raw 32-byte
/// representation, plus the optional band identity public key. Key bytes never
/// appear in logs.
public enum BandIdentity {
    private static let service = "local.callbacked.kinesis.identity"
    private static let bandKeySuffix = ".band"

    public struct Record: Sendable {
        public let privateKey: P256.Signing.PrivateKey
        public let bandPublicKey: P256.Signing.PublicKey
    }

    public static func enrollment(for band: String) -> BandEnrollmentIdentity? {
        guard let privateKey = loadPrivateKey(for: band) else { return nil }
        return BandEnrollmentIdentity(privateKey: privateKey, bandPublicKey: loadBandKey(for: band))
    }

    public static func exists(for band: String) -> Bool {
        loadPrivateKey(for: band) != nil
    }

    public static func loadPrivateKey(for band: String) -> P256.Signing.PrivateKey? {
        guard let data = read(account: band), data.count == 32 else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }

    public static func loadBandKey(for band: String) -> P256.Signing.PublicKey? {
        guard let data = read(account: band + bandKeySuffix), data.count == 65 else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: data)
    }

    public static func save(_ privateKey: P256.Signing.PrivateKey,
                            bandKey: P256.Signing.PublicKey? = nil, for band: String) throws {
        try write(privateKey.rawRepresentation, account: band)
        if let bandKey { try write(bandKey.x963Representation, account: band + bandKeySuffix) }
    }

    @discardableResult
    public static func generate(for band: String) throws -> P256.Signing.PrivateKey {
        let key = P256.Signing.PrivateKey()
        try save(key, for: band)
        return key
    }

    public static func delete(for band: String) {
        remove(account: band)
        remove(account: band + bandKeySuffix)
    }

    /// Parse a recovered `band-identity-record.json`. Mirrors the reference
    /// extraction workflow: the record's private and public fields must both
    /// match the imported key, and the record must carry the band's public key.
    public static func record(_ json: Data) throws -> Record {
        struct Fields: Decodable {
            let AppPrivateKey: String
            let AppPublicKey: String
            let AppECPubicKey: String?
            let AppECPublicKey: String?
        }
        let fields: Fields
        do { fields = try JSONDecoder().decode(Fields.self, from: json) }
        catch { throw BandProtocolError("the identity record is not valid json") }
        guard let raw = Data(base64Encoded: fields.AppPrivateKey), raw.count == 32,
              let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: raw) else {
            throw BandProtocolError("the identity record holds no usable private key")
        }
        guard let publicKey = Data(base64Encoded: fields.AppPublicKey), publicKey.count == 64,
              privateKey.publicKey.x963Representation.dropFirst() == publicKey[...] else {
            throw BandProtocolError("the identity record public key does not match its private key")
        }
        guard let point = (fields.AppECPubicKey ?? fields.AppECPublicKey).flatMap({ Data(base64Encoded: $0) }),
              point.count == 64,
              let bandKey = try? P256.Signing.PublicKey(x963Representation: Data([4]) + point) else {
            throw BandProtocolError("the identity record has no band public key")
        }
        return Record(privateKey: privateKey, bandPublicKey: bandKey)
    }

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data, account: String) throws {
        remove(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw BandProtocolError("could not store the band identity in the keychain")
        }
    }

    private static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
