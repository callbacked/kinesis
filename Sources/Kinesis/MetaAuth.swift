import CryptoKit
import Foundation

/// The Meta account session the graph routes require. `deviceID` is the
/// identifier the login exchange generated and `obtainedAt` is when the
/// session was issued; both round-trip through `MetaSessionStore`.
struct MetaSession: Sendable {
    static let universe = "ar"
    let accessToken: String
    let userID: String
    let deviceID: String
    let obtainedAt: Date

    init(accessToken: String, userID: String,
         deviceID: String = UUID().uuidString, obtainedAt: Date = Date()) {
        self.accessToken = accessToken
        self.userID = userID
        self.deviceID = deviceID
        self.obtainedAt = obtainedAt
    }
}

struct MetaAuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The desktop auth chain validated in the band recovery work: an anonymous
/// tokens query, a webview sign-in at auth.meta.com, a blob decrypt, and the
/// ar-genai exchange that yields the user session (universe "ar").
/// The chain itself never writes; the resulting session persists only through
/// `MetaSessionStore`.
enum MetaAuth {
    // Meta's own client identifiers, the same in every copy of Meta's apps. They name the
    // app that asks, not a person. They are not secrets, and no account or session is in them.
    static let frlClient = "FRL|388177446008673|083800dd7efbbd42eab18c9886d79c18"
    static let arClient = "AR|306760944872162|a919421a55a8ea18080ab2f10f57f1be"
    static let hwClient = "HW|1312539125771114|98588f106d5d542adbf590619ca071fe"
    static let tokensQueryURL = URL(string: "https://meta.graph.meta.com/webview_tokens_query")!
    static let blobsDecryptURL = URL(string: "https://meta.graph.meta.com/webview_blobs_decrypt")!
    static let loginURL = URL(string: "https://ar-genai.graph.meta.com/login")!
    /// The validated sign-in entry: the FRL app id with the tokens query's
    /// etoken. Live adjust if Meta moves the entry page.
    static let authEntryBase = "https://auth.meta.com/?native_app_id=388177446008673&source_app_id=388177446008673&native_sso_etoken="

    struct SSOTokens: Sendable {
        let nativeSSOToken: String
        let etoken: String
        var authEntryURL: URL? { URL(string: authEntryBase + etoken) }
    }

    // MARK: - steps

    /// Step 1: the anonymous webview tokens query (multipart, FRL client).
    static func tokensQuery() async throws -> SSOTokens {
        let lsd = makeLSD()
        let fields = [("access_token", frlClient), ("lsd", lsd), ("jazoest", jazoest(lsd))]
        let json = try await post(tokensQueryURL, multipart: fields)
        guard let native = json["native_sso_token"] as? String, !native.isEmpty,
              let etoken = json["native_sso_etoken"] as? String, !etoken.isEmpty else {
            throw MetaAuthError(message: "meta didn't return sign-in tokens. try again.")
        }
        return SSOTokens(nativeSSOToken: native, etoken: etoken)
    }

    /// The token the login callback must present: the first 16 hex digits of
    /// the request token's SHA-256.
    static func expectedCallbackToken(nativeSSOToken: String) -> String {
        String(SHA256.hash(data: Data(nativeSSOToken.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    static func callbackMatches(_ token: String?, nativeSSOToken: String) -> Bool {
        guard let token, token.count == 16 else { return false }
        let expected = expectedCallbackToken(nativeSSOToken: nativeSSOToken)
        var difference: UInt8 = 0
        for (a, b) in zip(token.utf8, expected.utf8) { difference |= a ^ b }
        return difference == 0 && token.count == expected.count
    }

    /// Step 3: decrypt the login blob into the FRL access token.
    static func decryptBlob(_ blob: String, requestToken: String) async throws -> String {
        let lsd = makeLSD()
        let fields = [("blob", blob), ("request_token", requestToken), ("access_token", frlClient),
                      ("lsd", lsd), ("jazoest", jazoest(lsd))]
        let json = try await post(blobsDecryptURL, multipart: fields)
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            throw MetaAuthError(message: "meta didn't confirm the sign-in. try again.")
        }
        return token
    }

    /// Step 4: exchange the FRL token for the ar user session.
    static func login(frlAccessToken: String) async throws -> MetaSession {
        let deviceID = UUID().uuidString
        let fields = [("frl_access_token", frlAccessToken),
                      ("logging_session_id", UUID().uuidString),
                      ("format", "json"),
                      ("device_id", deviceID),
                      ("generate_session_cookies", "1"),
                      ("generate_analytics_claim", "1"),
                      ("method", "POST")]
        let json = try await post(loginURL, form: fields,
                                  headers: ["Authorization": "OAuth " + arClient])
        let userID = (json["user_id"] as? String) ?? (json["user_id"] as? NSNumber)?.stringValue
        guard let token = json["access_token"] as? String, !token.isEmpty,
              let userID, !userID.isEmpty else {
            throw MetaAuthError(message: "meta didn't return an account session. try again.")
        }
        return MetaSession(accessToken: token, userID: userID, deviceID: deviceID)
    }

    // MARK: - form encoding

    static func makeLSD() -> String {
        "S0." + String((0..<6).map { _ in Character(String(Int.random(in: 0...9))) })
    }

    static func jazoest(_ lsd: String) -> String {
        "2" + String(lsd.unicodeScalars.reduce(0) { $0 + $1.value })
    }

    static func multipartBody(fields: [(String, String)], boundary: String) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    static func urlForm(fields: [(String, String)]) -> Data {
        fields.map { "\($0.0)=\(formEscape($0.1))" }.joined(separator: "&")
            .data(using: .ascii) ?? Data()
    }

    private static let formSafeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func formEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formSafeCharacters) ?? value
    }

    // MARK: - transport

    private static func post(_ url: URL, multipart fields: [(String, String)]) async throws -> [String: Any] {
        let boundary = "kinesis.form.\(UUID().uuidString)"
        let headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)",
                       "Accept": "application/json",
                       "Origin": "https://auth.meta.com"]
        return try await post(url, headers: headers,
                              body: multipartBody(fields: fields, boundary: boundary))
    }

    private static func post(_ url: URL, form fields: [(String, String)],
                             headers: [String: String]) async throws -> [String: Any] {
        var headers = headers
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Accept"] = "application/json"
        return try await post(url, headers: headers, body: urlForm(fields: fields))
    }

    private static func post(_ url: URL, headers: [String: String], body: Data) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            throw MetaAuthError(message: "meta sign-in failed (http \(status)). try again.")
        }
        if json["error"] != nil {
            let error = json["error"] as? [String: Any]
            let code = error?["code"] as? Int
            let subcode = error?["error_subcode"] as? Int
            throw MetaAuthError(message: "meta sign-in failed (code \(code.map(String.init) ?? "-"), subcode \(subcode.map(String.init) ?? "-")). try again.")
        }
        return json
    }
}

/// Where the Meta session lives between launches. BandModel talks to this
/// protocol; tests substitute an in-memory store.
@MainActor protocol MetaSessionStoring {
    func hasSavedSession() -> Bool
    func saveSession(_ session: MetaSession)
    func restoreSession() -> MetaSession?
    func deleteSession()
}

/// One keychain item holding the session json: token, user, device, universe,
/// and the time it was issued. The layout mirrors BandIdentity. Token material
/// never reaches the log.
struct MetaSessionStore: MetaSessionStoring {
    private let service: String
    private let account: String

    init(service: String = "local.callbacked.kinesis.meta", account: String = "session") {
        self.service = service
        self.account = account
    }

    private struct Stored: Codable {
        let accessToken: String
        let userID: String
        let deviceID: String
        let universe: String
        let obtainedAt: Date
    }

    func hasSavedSession() -> Bool { restoreSession() != nil }

    func saveSession(_ session: MetaSession) {
        let stored = Stored(accessToken: session.accessToken, userID: session.userID,
                            deviceID: session.deviceID, universe: MetaSession.universe,
                            obtainedAt: session.obtainedAt)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        remove()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        // A failed write keeps the in-memory session working; the next launch
        // just asks for a sign-in again.
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func restoreSession() -> MetaSession? {
        guard let data = read(), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.universe == MetaSession.universe, !stored.accessToken.isEmpty,
              !stored.userID.isEmpty else { return nil }
        return MetaSession(accessToken: stored.accessToken, userID: stored.userID,
                           deviceID: stored.deviceID, obtainedAt: stored.obtainedAt)
    }

    func deleteSession() { remove() }

    private func read() -> Data? {
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

    private func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
