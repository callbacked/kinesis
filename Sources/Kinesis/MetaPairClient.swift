import Foundation
import KinesisCore

/// The ownership exchange failed because the account session is expired,
/// invalid, or revoked. The model drops the saved session and asks for one
/// fresh sign-in instead of surfacing a dead end.
struct MetaSessionInvalidError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// The ownership HTTP exchanges against the hardware graph. Everything is a
/// form-encoded POST; receipts travel verbatim and are never reformatted.
protocol BandPairClient: Sendable {
    func pairRequest(_ data: CeremonyPairRequestData) async throws -> MetaPairClient.Pending
    func pair(_ data: CeremonyPairData) async throws -> MetaPairClient.Final
}

struct MetaPairClient: BandPairClient {
    struct Pending: Sendable {
        let signature: Data
        let receipt: String
    }

    struct Final: Sendable {
        let signature: Data
        let receipt: String
        let devicePublicKey: Data?
    }

    static let host = "https://graph.facebook-hardware.com"
    static let pairRequestURL = URL(string: host + "/pair_request")!
    static let pairURL = URL(string: host + "/pair")!
    let session: MetaSession

    // MARK: - request encoding (pure, covered by tests)

    static func additionalData(nonce: Data, appPublicKey: Data, secondaryCert: String) -> String {
        "{\"device_nonce\":\"\(nonce.base64EncodedString())\","
            + "\"app_pubkey\":\"\(appPublicKey.base64EncodedString())\","
            + "\"secondary_cert\":\"\(secondaryCert)\"}"
    }

    static func pairRequestFields(identity: BandIdentityInfo, nonce: Data, appPublicKey: Data,
                                  session: MetaSession) -> [(String, String)] {
        [("access_token", MetaAuth.hwClient),
         ("user_access_token", session.accessToken),
         ("user_token_universe", MetaSession.universe),
         ("pair_protocol_version", "3"),
         ("device_cert", identity.deviceCertificate.base64EncodedString()),
         ("serial_number", identity.serial),
         ("additional_data", additionalData(nonce: nonce, appPublicKey: appPublicKey,
                                            secondaryCert: identity.secondaryCertificate.base64EncodedString()))]
    }

    static func pairFields(receipt: String, signature: Data, session: MetaSession) -> [(String, String)] {
        [("access_token", MetaAuth.hwClient),
         ("user_access_token", session.accessToken),
         ("user_token_universe", MetaSession.universe),
         ("pair_protocol_version", "3"),
         ("device_pending_ownership_receipt", receipt),
         ("device_pending_ownership_receipt_signature", signature.base64EncodedString())]
    }

    // MARK: - response parsing (pure, covered by tests)

    static func parsePending(_ json: [String: Any]) throws -> Pending {
        guard let receipt = json["pending_ownership_receipt"] as? String, !receipt.isEmpty,
              let signature = Data(base64Encoded: json["receipt_signature"] as? String ?? "") else {
            throw MetaAuthError(message: "the band claim service didn't return a receipt. try again.")
        }
        return Pending(signature: signature, receipt: receipt)
    }

    static func parseFinal(_ json: [String: Any]) throws -> Final {
        guard let receipt = json["final_ownership_receipt"] as? String, !receipt.isEmpty,
              let signature = Data(base64Encoded: json["receipt_signature"] as? String ?? "") else {
            throw MetaAuthError(message: "the band claim service didn't return a final receipt. try again.")
        }
        // the live server omits device_ec_public_key here; the reference app
        // logs and continues, so do we
        let devicePublicKey = deviceKey(in: json) ?? deviceKey(inReceipt: receipt)
        return Final(signature: signature, receipt: receipt, devicePublicKey: devicePublicKey)
    }

    private static func deviceKey(in json: [String: Any]) -> Data? {
        guard let additional = json["additional_data"] as? [String: Any] else { return nil }
        return Data(base64Encoded: additional["device_ec_public_key"] as? String ?? "")
    }

    private static func deviceKey(inReceipt receipt: String) -> Data? {
        guard let data = receipt.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return deviceKey(in: fields)
    }

    // MARK: - exchanges

    func pairRequest(_ data: CeremonyPairRequestData) async throws -> Pending {
        let fields = Self.pairRequestFields(identity: data.identity, nonce: data.nonce,
                                            appPublicKey: data.appPublicKey, session: session)
        return try await Self.parsePending(execute(Self.pairRequestURL, fields: fields))
    }

    func pair(_ data: CeremonyPairData) async throws -> Final {
        let fields = Self.pairFields(receipt: data.receipt, signature: data.signature, session: session)
        return try await Self.parseFinal(execute(Self.pairURL, fields: fields))
    }

    /// True when the exchange failed because the account session can't work
    /// any more: an auth HTTP status, or the graph's expired-token error code.
    static func isSessionFailure(status: Int, error: [String: Any]?) -> Bool {
        if status == 401 || status == 403 { return true }
        return (error?["code"] as? Int) == 190
    }

    private func execute(_ url: URL, fields: [(String, String)]) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = MetaAuth.urlForm(fields: fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if Self.isSessionFailure(status: status, error: json?["error"] as? [String: Any]) {
            throw MetaSessionInvalidError(message: "your meta session expired. sign in to claim the band again.")
        }
        guard status == 200, let json else {
            throw MetaAuthError(message: "the band claim service failed (http \(status)). try again.")
        }
        if json["error"] != nil {
            let error = json["error"] as? [String: Any]
            let code = error?["code"] as? Int
            throw MetaAuthError(message: "the band claim service rejected the request (code \(code.map(String.init) ?? "-")). try again.")
        }
        return json
    }
}
