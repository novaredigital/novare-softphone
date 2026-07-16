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

    var key: String { "\(username)@\(domain)" }
}

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    /// All signed-in lines (Groundwire parity: every account registers,
    /// incoming rings from any; `activeIndex` is the outbound line).
    @Published private(set) var accounts: [Provisioning] = []
    @Published var activeIndex: Int = 0 {
        didSet {
            UserDefaults.standard.set(activeIndex, forKey: activeKey)
            SipEngine.shared.setOutboundAccount(activeIndex)
        }
    }
    @Published var lastError: String?

    private var portalTokens: [String: String] = [:]   // Provisioning.key → session token
    private var lastPushToken: String?

    var isSignedIn: Bool { !accounts.isEmpty }
    /// The outbound line (kept for views that show "the" account).
    var provisioning: Provisioning? {
        accounts.indices.contains(activeIndex) ? accounts[activeIndex] : accounts.first
    }

    private let keychainKey = "com.novaredigital.novarephone.provisioning"
    private let activeKey = "com.novaredigital.novarephone.activeline"

    private init() {
        accounts = Self.loadFromKeychain(key: keychainKey)
        activeIndex = min(UserDefaults.standard.integer(forKey: activeKey), max(accounts.count - 1, 0))
        if !accounts.isEmpty {
            SipEngine.shared.configure(accounts: accounts, activeIndex: activeIndex)
            Task { for p in accounts { await portalLogin(for: p) } }
        }
    }

    // MARK: - Sign-in via QR payload (first account or an added line)

    /// The QR encodes the same JSON the portal's provisioning endpoint returns:
    /// {account_name, username, domain, password, transport, port, api_base, tenant_id}
    func signIn(qrPayload: Data) async {
        do {
            let p = try Provisioning(qrJSON: qrPayload)
            if let i = accounts.firstIndex(where: { $0.key == p.key }) {
                accounts[i] = p            // re-scan of an existing line: refresh it
                activeIndex = i
            } else {
                accounts.append(p)
                activeIndex = accounts.count - 1
            }
            try Self.saveToKeychain(accounts, key: keychainKey)
            SipEngine.shared.configure(accounts: accounts, activeIndex: activeIndex)
            await portalLogin(for: p)
            if let token = lastPushToken { await registerPushToken(token) }
        } catch {
            lastError = "That code isn't a valid Nóvare sign-in code."
        }
    }

    /// Remove one line. The last removal is a full sign-out.
    func signOut(at index: Int) async {
        guard accounts.indices.contains(index) else { return }
        let p = accounts[index]
        await removePushToken(for: p)
        portalTokens[p.key] = nil
        accounts.remove(at: index)
        try? Self.saveToKeychain(accounts, key: keychainKey)
        if accounts.isEmpty {
            SipEngine.shared.shutdown()
            Self.deleteFromKeychain(key: keychainKey)
            activeIndex = 0
        } else {
            activeIndex = min(activeIndex, accounts.count - 1)
            SipEngine.shared.configure(accounts: accounts, activeIndex: activeIndex)
        }
    }

    func signOut() async {   // sign out everything
        while !accounts.isEmpty { await signOut(at: accounts.count - 1) }
    }

    // MARK: - Client-portal sessions (push-token registry rides this realm)

    private func portalLogin(for p: Provisioning) async {
        struct LoginBody: Codable { let c: Int; let extension_: String; let password: String
            enum CodingKeys: String, CodingKey { case c, extension_ = "extension", password } }
        struct LoginReply: Codable { let token: String }
        do {
            var req = URLRequest(url: p.apiBase.appendingPathComponent("client-portal/login"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(LoginBody(c: p.tenantId, extension_: p.username, password: p.password))
            let (data, _) = try await URLSession.shared.data(for: req)
            portalTokens[p.key] = try JSONDecoder().decode(LoginReply.self, from: data).token
        } catch {
            // Calls still work without the portal session (e.g. servers that
            // don't run the client-portal realm yet) — push-wake just waits.
        }
    }

    /// Fan the device's push token out to every line's own server.
    func registerPushToken(_ token: String) async {
        lastPushToken = token
        struct Body: Codable { let platform: String; let token: String; let device_id: String }
        for p in accounts {
            guard let bearer = portalTokens[p.key] else { continue }
            var req = URLRequest(url: p.apiBase.appendingPathComponent("client-portal/push-token"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONEncoder().encode(Body(platform: "apns", token: token,
                                                          device_id: UIDeviceIdentifier.stable()))
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func removePushToken() async {
        for p in accounts { await removePushToken(for: p) }
    }

    private func removePushToken(for p: Provisioning) async {
        guard let bearer = portalTokens[p.key], let token = lastPushToken else { return }
        struct Body: Codable { let token: String }
        var req = URLRequest(url: p.apiBase.appendingPathComponent("client-portal/push-token"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(Body(token: token))
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Keychain plumbing

    private static func saveToKeychain(_ accounts: [Provisioning], key: String) throws {
        let data = try JSONEncoder().encode(accounts)
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

    private static func loadFromKeychain(key: String) -> [Provisioning] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return [] }
        if let list = try? JSONDecoder().decode([Provisioning].self, from: data) { return list }
        // Migration: pre-multi-account installs stored a single Provisioning.
        if let single = try? JSONDecoder().decode(Provisioning.self, from: data) { return [single] }
        return []
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
