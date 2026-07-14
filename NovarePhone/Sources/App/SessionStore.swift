import Foundation
import Security

/// Everything the app knows about "its" server — learned at QR sign-in,
/// stored in the Keychain, erasable at sign-out. Nothing here is compiled in.
struct Provisioning: Codable, Equatable {
    let accountName: String     // display name, e.g. "Front Desk"
    let username: String        // SIP extension
    let domain: String          // per-client SIP domain, any Nováre server
    let port: Int               // whatever the QR says — never assumed
    let transport: String       // "UDP" | "TCP" | "TLS"
    let password: String        // SIP secret
    let apiBase: URL            // client-portal API root for THIS tenant
    let tenantId: Int
}

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var provisioning: Provisioning?
    @Published private(set) var portalToken: String?
    @Published var lastError: String?

    var isSignedIn: Bool { provisioning != nil }

    private let keychainKey = "com.novaredigital.novarephone.provisioning"

    private init() {
        provisioning = Self.loadFromKeychain(key: keychainKey)
        if provisioning != nil { SipEngine.shared.configure(with: provisioning!) }
    }

    // MARK: - Sign-in via QR payload

    /// The QR encodes the same JSON the portal's provisioning endpoint returns:
    /// {account_name, username, domain, password, transport, port, api_base, tenant_id}
    func signIn(qrPayload: Data) async {
        do {
            let p = try Provisioning(qrJSON: qrPayload)
            try Self.saveToKeychain(p, key: keychainKey)
            provisioning = p
            SipEngine.shared.configure(with: p)
            await portalLogin()
        } catch {
            lastError = "That code isn't a valid Nováre sign-in code."
        }
    }

    func signOut() async {
        await removePushToken()
        SipEngine.shared.shutdown()
        Self.deleteFromKeychain(key: keychainKey)
        provisioning = nil
        portalToken = nil
    }

    // MARK: - Client-portal session (push-token registry rides this realm)

    private func portalLogin() async {
        guard let p = provisioning else { return }
        struct LoginBody: Codable { let c: Int; let extension_: String; let password: String
            enum CodingKeys: String, CodingKey { case c, extension_ = "extension", password } }
        struct LoginReply: Codable { let token: String }
        do {
            var req = URLRequest(url: p.apiBase.appendingPathComponent("client-portal/login"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(LoginBody(c: p.tenantId, extension_: p.username, password: p.password))
            let (data, _) = try await URLSession.shared.data(for: req)
            portalToken = try JSONDecoder().decode(LoginReply.self, from: data).token
        } catch {
            lastError = "Signed in for calls; portal features unavailable right now."
        }
    }

    func registerPushToken(_ token: String) async {
        guard let p = provisioning, let bearer = portalToken else { return }
        struct Body: Codable { let platform: String; let token: String; let device_id: String }
        var req = URLRequest(url: p.apiBase.appendingPathComponent("client-portal/push-token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(Body(platform: "apns", token: token,
                                                      device_id: UIDeviceIdentifier.stable()))
        _ = try? await URLSession.shared.data(for: req)
    }

    func removePushToken() async {
        guard let p = provisioning, let bearer = portalToken else { return }
        var req = URLRequest(url: p.apiBase.appendingPathComponent("client-portal/push-token"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Keychain plumbing

    private static func saveToKeychain(_ p: Provisioning, key: String) throws {
        let data = try JSONEncoder().encode(p)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw NSError(domain: "keychain", code: 1)
        }
    }

    private static func loadFromKeychain(key: String) -> Provisioning? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Provisioning.self, from: data)
    }

    private static func deleteFromKeychain(key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

extension Provisioning {
    init(qrJSON: Data) throws {
        struct Wire: Codable {
            let account_name: String?
            let username: String
            let domain: String
            let password: String
            let transport: String?
            let port: Int?
            let api_base: String
            let tenant_id: Int
        }
        let w = try JSONDecoder().decode(Wire.self, from: qrJSON)
        guard let api = URL(string: w.api_base) else { throw NSError(domain: "qr", code: 1) }
        self.init(accountName: w.account_name ?? w.username,
                  username: w.username, domain: w.domain,
                  port: w.port ?? 5060, transport: w.transport ?? "UDP",
                  password: w.password, apiBase: api, tenantId: w.tenant_id)
    }
}

enum UIDeviceIdentifier {
    /// Stable per-install identifier (not the hardware ID — Apple forbids that).
    static func stable() -> String {
        let key = "com.novaredigital.novarephone.deviceid"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
