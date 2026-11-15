import CommonCrypto
import CryptoKit
import Foundation

public struct BandProtocolError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

struct AirShieldKeys {
    let encryption: SymmetricKey
    let mac: SymmetricKey
    /// Bytes the MAC covers before the counter (`02 02 00 00` under scheme 26).
    let macPrefix: Data
    /// Pad a block-aligned frame with a whole block, as newer firmware does
    /// (scheme 3 sends aligned frames unpadded).
    let padAligned: Bool

    /// Scheme 3 is older firmware. Newer firmware offers 27 and names 26, whose rules were
    /// worked out on hardware by band-core (896kb, MIT): the HKDF runs over the raw ECDH
    /// secret with salt SHA256(challenge || seed), the encryption key doubles as the MAC
    /// key, and the MAC covers `02 02 00 00` before the counter.
    init(secret: Data, challenge: Data, seed: Data, scheme: UInt64 = 3) throws {
        guard secret.count == 32, challenge.count == 16, seed.count == 32 else {
            throw BandProtocolError("Invalid AirShield key material")
        }
        if scheme == 3 {
            let hashed = Data(SHA256.hash(data: secret))
            encryption = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: hashed),
                salt: Data(SHA256.hash(data: hashed + challenge + seed)), info: Data("AirShield".utf8), outputByteCount: 32)
            macPrefix = Data()
            padAligned = false
        } else {
            encryption = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                salt: Data(SHA256.hash(data: challenge + seed)), info: Data("AirShield".utf8), outputByteCount: 32)
            macPrefix = Data([2, 2, 0, 0])
            padAligned = true
        }
        mac = encryption
    }

    init(encryption: Data, mac: Data) {
        self.encryption = SymmetricKey(data: encryption)
        self.mac = SymmetricKey(data: mac)
        macPrefix = Data()
        padAligned = false
    }
}

private func crypt(_ data: Data, key: SymmetricKey, iv: Data, operation: CCOperation) throws -> Data {
    guard key.bitCount == 256, iv.count == 16, !data.isEmpty, data.count % 16 == 0 else {
        throw BandProtocolError("Invalid AES block shape")
    }
    var output = Data(count: data.count + 16)
    var count = 0
    let capacity = output.count
    let status = key.withUnsafeBytes { keyBytes in
        iv.withUnsafeBytes { ivBytes in
            data.withUnsafeBytes { bytes in
                output.withUnsafeMutableBytes { destination in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0, keyBytes.baseAddress, 32,
                            ivBytes.baseAddress, bytes.baseAddress, data.count,
                            destination.baseAddress, capacity, &count)
                }
            }
        }
    }
    guard status == kCCSuccess else { throw BandProtocolError("AES operation failed: \(status)") }
    return output.prefix(count)
}

struct AirShieldCipher {
    let keys: AirShieldKeys
    private(set) var iv: Data
    private(set) var counter: UInt32

    mutating func encrypt(_ frame: Data) throws -> Data {
        let remainder = 16 - frame.count % 16
        let count = remainder == 16 && !keys.padAligned ? 0 : remainder
        let padded = frame + Data(repeating: UInt8(0xc0 + count), count: count)
        guard !padded.isEmpty, padded.count <= 4096 else { throw BandProtocolError("AirShield frame too large") }
        let ciphertext = try crypt(padded, key: keys.encryption, iv: iv, operation: CCOperation(kCCEncrypt))
        let body = Data([UInt8(ciphertext.count / 16 - 1)]) + ciphertext
        let tag = HMAC<SHA256>.authenticationCode(for: keys.macPrefix + counter.littleEndianData + body, using: keys.mac)
        iv = Data(ciphertext.suffix(16))
        counter &+= 1
        return Data([0x40]) + Data(tag.prefix(8)) + body
    }

    mutating func decrypt(_ packet: Data) throws -> Data {
        let expected = HMAC<SHA256>.authenticationCode(for: keys.macPrefix + counter.littleEndianData + packet.dropFirst(9), using: keys.mac)
        // Compare every byte before decrypting. No unauthenticated plaintext leaves this type.
        let difference = zip(expected.prefix(8), packet.dropFirst().prefix(8)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { throw BandProtocolError("Band packet authentication failed") }
        let ciphertext = Data(packet.dropFirst(10))
        let plaintext = try crypt(ciphertext, key: keys.encryption, iv: iv, operation: CCOperation(kCCDecrypt))
        iv = Data(ciphertext.suffix(16))
        counter &+= 1
        return plaintext
    }
}

struct AirShieldReceiver {
    var cipher: AirShieldCipher
    private var pending = Data()

    init(cipher: AirShieldCipher) { self.cipher = cipher }

    mutating func feed(_ bytes: Data) throws -> [Data] {
        pending.append(bytes)
        var plaintext: [Data] = []
        while let marker = pending.first {
            if [0x81, 0x82].contains(marker), pending.count >= 2, pending[1] <= 1 {
                pending = Data(pending.dropFirst(2))
                continue
            }
            if [0x01, 0x02].contains(marker) {
                guard pending.count >= 2 else { break }
                let size = 3 + Int(pending[1])
                guard pending.count >= size else { break }
                pending = Data(pending.dropFirst(size))
                continue
            }
            if [0x81, 0x82].contains(marker), pending.count < 2 { break }
            guard [0x40, 0x41, 0x42].contains(marker) else {
                throw BandProtocolError("Unsupported band transport marker")
            }
            guard pending.count >= 10 else { break }
            let size = 10 + (Int(pending[9]) + 1) * 16
            guard pending.count >= size else { break }
            if marker == 0x40 { plaintext.append(try cipher.decrypt(Data(pending.prefix(size)))) }
            // Relay channels are not part of the authenticated input service.
            pending = Data(pending.dropFirst(size))
        }
        return plaintext
    }

    func finish() throws {
        guard pending.isEmpty else { throw BandProtocolError("Truncated AirShield packet") }
    }
}

extension FixedWidthInteger {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
