import Foundation
import KinesisCore
import Testing
@testable import Kinesis

private let testSession = MetaSession(accessToken: "test-access-token", userID: "1234567890")

private let testIdentity = BandIdentityInfo(
    deviceCertificate: Data([1, 2, 3, 4]),
    serial: "TESTSERIAL0001",
    secondaryCertificate: Data([5, 6, 7, 8]))

@Test func pairRequestEncodesTheExactReferenceFieldSet() {
    let fields = MetaPairClient.pairRequestFields(identity: testIdentity, nonce: Data(0..<16),
                                                  appPublicKey: Data(repeating: 9, count: 64),
                                                  session: testSession)
    #expect(fields.map(\.0) == ["access_token", "user_access_token", "user_token_universe",
                                "pair_protocol_version", "device_cert", "serial_number", "additional_data"])
    #expect(fields[0].1 == "HW|1312539125771114|98588f106d5d542adbf590619ca071fe")
    #expect(fields[1].1 == "test-access-token")
    #expect(fields[2].1 == "ar")
    #expect(fields[3].1 == "3")
    #expect(fields[4].1 == Data([1, 2, 3, 4]).base64EncodedString())
    #expect(fields[5].1 == "TESTSERIAL0001")
    // The additional data is compact JSON with the reference key order.
    #expect(fields[6].1 == "{\"device_nonce\":\"\(Data(0..<16).base64EncodedString())\","
        + "\"app_pubkey\":\"\(Data(repeating: 9, count: 64).base64EncodedString())\","
        + "\"secondary_cert\":\"\(Data([5, 6, 7, 8]).base64EncodedString())\"}")
}

@Test func pairEncodesTheExactReferenceFieldSet() throws {
    let receipt = #"{"receipt_type":"DevicePendingOwnershipReceipt"}"#
    let signature = Data([10, 11, 12])
    let fields = MetaPairClient.pairFields(receipt: receipt, signature: signature, session: testSession)
    #expect(fields.map(\.0) == ["access_token", "user_access_token", "user_token_universe",
                                "pair_protocol_version", "device_pending_ownership_receipt",
                                "device_pending_ownership_receipt_signature"])
    #expect(fields[0].1 == "HW|1312539125771114|98588f106d5d542adbf590619ca071fe")
    #expect(fields[1].1 == "test-access-token")
    #expect(fields[2].1 == "ar")
    #expect(fields[3].1 == "3")
    #expect(fields[4].1 == receipt)
    #expect(fields[5].1 == signature.base64EncodedString())
}

@Test func urlFormEscapesReceiptCharactersForATransportSafeBody() {
    let body = String(decoding: MetaAuth.urlForm(fields: [("a", "x+y=z 1"), ("b", #"{"q":"\/"}"#)]), as: UTF8.self)
    #expect(body == "a=x%2By%3Dz%201&b=%7B%22q%22%3A%22%5C%2F%22%7D")
    let decoded = body.split(separator: "&").map { pair -> (String, String) in
        let parts = pair.split(separator: "=", maxSplits: 1)
        return (String(parts[0]).removingPercentEncoding ?? String(parts[0]),
                String(parts.count > 1 ? parts[1] : "").removingPercentEncoding ?? "")
    }
    #expect(decoded[0].0 == "a" && decoded[0].1 == "x+y=z 1")
    #expect(decoded[1].0 == "b" && decoded[1].1 == #"{"q":"\/"}"#)
}

@Test func lsdFollowsTheReferenceSprinkleShape() {
    let lsd = MetaAuth.makeLSD()
    #expect(lsd.count == 9)
    #expect(lsd.hasPrefix("S0."))
    #expect(lsd.dropFirst(3).allSatisfy { "0123456789".contains($0) })
    #expect(MetaAuth.jazoest(lsd) == "2" + String(lsd.unicodeScalars.reduce(0) { $0 + $1.value }))
}

@Test func multipartBodiesWrapEveryFieldOnce() {
    let body = String(decoding: MetaAuth.multipartBody(fields: [("blob", "b"), ("lsd", "S0.1")], boundary: "boundary"),
                      as: UTF8.self)
    let expected = "--boundary\r\nContent-Disposition: form-data; name=\"blob\"\r\n\r\nb\r\n"
        + "--boundary\r\nContent-Disposition: form-data; name=\"lsd\"\r\n\r\nS0.1\r\n--boundary--\r\n"
    #expect(body == expected)
    #expect(body.components(separatedBy: "--boundary").count == 4)
}

@Test func pendingAndFinalReceiptsParseWithTheBandKey() throws {
    let pending = try MetaPairClient.parsePending([
        "pending_ownership_receipt": #"{"receipt_type":"ServerPendingOwnershipReceipt"}"#,
        "receipt_signature": Data([1, 2, 3]).base64EncodedString(),
    ])
    #expect(pending.signature == Data([1, 2, 3]))
    #expect(pending.receipt.contains("ServerPendingOwnershipReceipt"))
    let point = Data(0..<64)
    let final = try MetaPairClient.parseFinal([
        "final_ownership_receipt": #"{"receipt_type":"ServerFinalOwnershipReceipt"}"#,
        "receipt_signature": Data([4, 5]).base64EncodedString(),
        "additional_data": ["device_ec_public_key": point.base64EncodedString()],
    ])
    #expect(final.devicePublicKey == point)
    #expect(final.signature == Data([4, 5]))
    // A server that embeds the key in the receipt string instead still parses.
    let receipt = "{\"additional_data\":{\"device_ec_public_key\":\"\(point.base64EncodedString())\"}}"
    let embedded = try MetaPairClient.parseFinal([
        "final_ownership_receipt": receipt,
        "receipt_signature": Data([4, 5]).base64EncodedString(),
    ])
    #expect(embedded.devicePublicKey == point)
    // the live server omits the band key; the reference app logs and continues
    let keyless = try MetaPairClient.parseFinal([
        "final_ownership_receipt": "{}", "receipt_signature": "AAAA",
    ])
    #expect(keyless.devicePublicKey == nil)
    #expect(throws: MetaAuthError.self) {
        try MetaPairClient.parsePending(["receipt_signature": "AAAA"])
    }
}

@Test func callbackValidationComparesTheTruncatedTokenDigest() {
    let native = "epfEORXEWkN2obB5"
    let expected = MetaAuth.expectedCallbackToken(nativeSSOToken: native)
    #expect(expected.count == 16)
    #expect(MetaAuth.callbackMatches(expected, nativeSSOToken: native))
    #expect(MetaAuth.callbackMatches(String(expected.dropLast() + "0"), nativeSSOToken: native) == false)
    #expect(MetaAuth.callbackMatches(nil, nativeSSOToken: native) == false)
    #expect(MetaAuth.callbackMatches("short", nativeSSOToken: native) == false)
}

@Test func sessionFailuresCoverAuthStatusesAndExpiredTokenErrors() {
    #expect(MetaPairClient.isSessionFailure(status: 401, error: nil))
    #expect(MetaPairClient.isSessionFailure(status: 403, error: nil))
    // The graph reports expired or invalid tokens as error code 190; the
    // payload decides, whatever the status.
    #expect(MetaPairClient.isSessionFailure(status: 400, error: ["code": 190]))
    #expect(MetaPairClient.isSessionFailure(status: 400, error: ["code": 1]) == false)
    #expect(MetaPairClient.isSessionFailure(status: 500, error: nil) == false)
    #expect(MetaPairClient.isSessionFailure(status: 200, error: nil) == false)
}

@Test @MainActor func theSessionStoreRoundTripsThroughTheKeychain() throws {
    let store = MetaSessionStore(service: "local.callbacked.kinesis.tests",
                                 account: "session-\(UUID().uuidString)")
    #expect(!store.hasSavedSession() && store.restoreSession() == nil)
    let session = MetaSession(accessToken: "token", userID: "42", deviceID: "device",
                              obtainedAt: Date(timeIntervalSince1970: 100))
    store.saveSession(session)
    #expect(store.hasSavedSession())
    let restored = try #require(store.restoreSession())
    #expect(restored.accessToken == "token")
    #expect(restored.userID == "42")
    #expect(restored.deviceID == "device")
    #expect(restored.obtainedAt == Date(timeIntervalSince1970: 100))
    store.deleteSession()
    #expect(!store.hasSavedSession() && store.restoreSession() == nil)
}
