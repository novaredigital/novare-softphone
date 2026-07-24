import Foundation
import Security

/// Everything the app knows about "its" server — learned at QR sign-in,
/// stored in the Keychain, erasable at sign-out. Nothing here is compiled in.
struct Provisioning: Codable, Equatable {
    var accountName: String     // display name — user-renamable in Settings
    let username: String        // SIP extension
    let domain: String          // per-client SIP domain, any Nováre server
    let port: Int               // whatever the QR says — never assumed
    let transport: String       // "UDP" | "TCP" | "TLS"
    let password: String        // SIP secret
    let apiBase: URL            // client-portal API root for THIS tenant
    let tenantId: Int
    var number: String?         // the line's public phone number, when the QR carries it

    // Transport ladder — how this line actually reaches its server. The QR's
    // transport/port stay authoritative until the ladder learns better (some
    // networks eat port-5060 SIP; the server offers TCP/alt-port/TLS too).
    var transportMode: String?     // nil = Auto; "UDP"/"TCP"/"TLS" pins it (Settings)
    var learnedTransport: String?  // last transport that actually registered
    var learnedPort: Int?

    var key: String { "\(username)@\(domain)" }

    /// What the engine should dial: a manual pin wins, then whatever the
    /// ladder learned, then the QR's original values.
    var effectiveTransport: String {
        if let m = transportMode, m != "Auto" { return m }
        return learnedTransport ?? transport
    }
    var effectivePort: Int {
        let t = effectiveTransport
        if t == learnedTransport, let lp = learnedPort { return lp }
        if t == transport { return port }
        return t == "TLS" ? 5061 : port   // conventional defaults until discovery resolves
    }
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

    private var portalTokens: [String: String] = [:]   // Provisioning.key → client-portal token (push realm)
    private var userTokens: [String: String] = [:]      // Provisioning.key → /user realm token (voicemail, works on shared-db prod)
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
        #if targetEnvironment(simulator)
        // Screenshot rig ONLY: simulators have no camera for the QR scanner,
        // so accept a provisioning payload from the environment. This block
        // does not exist in device builds (targetEnvironment(simulator)) —
        // the QR-only rule for shipping builds is untouched.
        if accounts.isEmpty,
           let env = ProcessInfo.processInfo.environment["NOVARE_SIM_PROVISION"],
           let data = env.data(using: .utf8) {
            Task { await self.signIn(qrPayload: data) }
        }
        #endif
        if !accounts.isEmpty {
            SipEngine.shared.configure(accounts: accounts, activeIndex: activeIndex)
            Task {
                for p in accounts { await portalLogin(for: p); await userLogin(for: p) }
                // The APNs token often arrives before these logins finish —
                // re-fire the registration now that bearer tokens exist.
                if let token = lastPushToken { await registerPushToken(token) }
            }
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
            await userLogin(for: p)
            if let token = lastPushToken { await registerPushToken(token) }
        } catch {
            lastError = "That code isn't a valid Nováre sign-in code."
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

    /// Settings: rename a line's label (local only — the server name is unchanged).
    func rename(at index: Int, to name: String) {
        guard accounts.indices.contains(index) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        accounts[index].accountName = clean
        try? Self.saveToKeychain(accounts, key: keychainKey)
    }

    /// Ladder result from the engine: persist what actually worked so the
    /// next launch starts on the known-good transport immediately.
    func transportLearned(key: String, transport: String, port: Int) {
        guard let i = accounts.firstIndex(where: { $0.key == key }) else { return }
        guard accounts[i].learnedTransport != transport || accounts[i].learnedPort != port else { return }
        accounts[i].learnedTransport = transport
        accounts[i].learnedPort = port
        try? Self.saveToKeychain(accounts, key: keychainKey)
    }

    /// Settings: pin a line's transport ("UDP"/"TCP"/"TLS"), or nil for Auto.
    /// A pin resolves its real port from the server's transport list first.
    func setTransportMode(_ mode: String?, at index: Int) async {
        guard accounts.indices.contains(index) else { return }
        if let m = mode, m != "Auto" {
            accounts[index].transportMode = m
            let list = await TransportDiscovery.fetch(apiBase: accounts[index].apiBase)
            accounts[index].learnedTransport = m
            accounts[index].learnedPort = list.first(where: { $0.t == m })?.p
        } else {
            accounts[index].transportMode = nil
            accounts[index].learnedTransport = nil
            accounts[index].learnedPort = nil
        }
        try? Self.saveToKeychain(accounts, key: keychainKey)
        SipEngine.shared.configure(accounts: accounts, activeIndex: activeIndex)
    }

    /// Settings: reorder lines. The active (outbound) line follows its account.
    func move(from source: IndexSet, to destination: Int) {
        let activeKey = provisioning?.key
        accounts.move(fromOffsets: source, toOffset: destination)
        if let k = activeKey, let i = accounts.firstIndex(where: { $0.key == k }) {
            activeIndex = i
        }
        try? Self.saveToKeychain(accounts, key: keychainKey)
        SipEngine.shared.configure(accounts: accounts, activeIndex: activeIndex)
    }

    // MARK: - Client-portal sessions (push-token registry rides this realm)

    /// Voicemail tab needs the portal session for the active line (nil where
    /// the line's server doesn't run the client-portal realm yet).
    func portalToken(for p: Provisioning) -> String? { portalTokens[p.key] }

    /// /user realm token for the active line — this is the voicemail source
    /// that works on shared-db production (134) AND box 5.
    func userToken(for p: Provisioning) -> String? { userTokens[p.key] }

    /// Ensure a line has a /user token, re-logging in if it's missing/lapsed.
    /// Voicemail aggregates across all lines; a lapsed token used to silently
    /// drop that line's messages from the list ("disappeared" — Mark 2026-07-24).
    func ensureUserToken(for p: Provisioning) async {
        if userTokens[p.key] == nil { await userLogin(for: p) }
    }

    /// Sign the line into the /user realm (extension + SIP password → token).
    /// This realm exists on every Nováre PBX and reads the extension's own
    /// mailbox from the shared db — so voicemail works on prod lines today.
    private func userLogin(for p: Provisioning) async {
        struct Body: Codable { let extension_: String; let password: String
            enum CodingKeys: String, CodingKey { case extension_ = "extension", password } }
        struct Reply: Codable { let token: String }
        do {
            var req = URLRequest(url: p.apiBase.appendingPathComponent("user/login"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(Body(extension_: p.username, password: p.password))
            let (data, _) = try await URLSession.shared.data(for: req)
            userTokens[p.key] = try JSONDecoder().decode(Reply.self, from: data).token
            // Token-registration race fix: the APNs push token often arrives
            // BEFORE this login finishes, so its registerPushToken() call found
            // no /user bearer and skipped this line. Now that the bearer exists,
            // register the push token for this line immediately.
            if let t = lastPushToken { await registerPushToken(t) }
            // GPS 1.1: the location consent check needs this same bearer —
            // re-run it now that the line can actually ask its server.
            LocationReporter.shared.tokensUpdated()
        } catch {
            // Voicemail tab will show the *97 fallback if this line has no token.
        }
    }

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

    /// Fan the device's push token out to every line's own server. Two realms
    /// exist in the wild: client-portal (box-5 style tenant servers) and /user
    /// (shared-db production, 134) — register with whichever the line has.
    func registerPushToken(_ token: String) async {
        lastPushToken = token
        struct Body: Codable { let platform: String; let token: String; let device_id: String }
        let body = try? JSONEncoder().encode(Body(platform: "apns", token: token,
                                                  device_id: UIDeviceIdentifier.stable()))
        for p in accounts {
            if let bearer = portalTokens[p.key] {
                var req = URLRequest(url: p.apiBase.appendingPathComponent("client-portal/push-token"))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                req.httpBody = body
                _ = try? await URLSession.shared.data(for: req)
            }
            if let bearer = userTokens[p.key] {
                var req = URLRequest(url: p.apiBase.appendingPathComponent("user/push-token"))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                req.httpBody = body
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    func removePushToken() async {
        for p in accounts { await removePushToken(for: p) }
    }

    private func removePushToken(for p: Provisioning) async {
        guard let token = lastPushToken else { return }
        struct Body: Codable { let token: String }
        let body = try? JSONEncoder().encode(Body(token: token))
        if let bearer = portalTokens[p.key] {
            var req = URLRequest(url: p.apiBase.appendingPathComponent("client-portal/push-token"))
            req.httpMethod = "DELETE"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            req.httpBody = body
            _ = try? await URLSession.shared.data(for: req)
        }
        if let bearer = userTokens[p.key] {
            var req = URLRequest(url: p.apiBase.appendingPathComponent("user/push-token"))
            req.httpMethod = "DELETE"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            req.httpBody = body
            _ = try? await URLSession.shared.data(for: req)
        }
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
            let caller_id_number: String?
        }
        let w = try JSONDecoder().decode(Wire.self, from: qrJSON)
        guard let api = URL(string: w.api_base) else { throw NSError(domain: "qr", code: 1) }
        self.init(accountName: w.account_name ?? w.username,
                  username: w.username, domain: w.domain,
                  port: w.port ?? 5060, transport: w.transport ?? "UDP",
                  password: w.password, apiBase: api, tenantId: w.tenant_id,
                  number: w.caller_id_number)
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
