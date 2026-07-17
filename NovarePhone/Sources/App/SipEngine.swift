import Foundation
import linphonesw
import AVFAudio
import Combine
import Network

/// Published call state the in-call screen renders. Updated only from
/// SipEngine's delegate transitions so it always mirrors SIP reality.
@MainActor
final class CallSession: ObservableObject {
    static let shared = CallSession()
    enum Phase: Equatable { case idle, dialing, ringing, incoming, connected(Date) }
    @Published var phase: Phase = .idle
    @Published var remote: String = ""
    @Published var isMuted = false
    @Published var isSpeaker = false
    var isActive: Bool { phase != .idle }

    /// Whether the app should draw its OWN full-screen call UI. Outgoing calls
    /// get no system UI so the app draws its own; a connected call (answered
    /// via CallKit) shows the in-call controls. But an UNANSWERED INCOMING
    /// call belongs to CallKit's native accept/decline screen — the app must
    /// NOT put up a competing screen (its only button was a red decline, which
    /// looked like "answer" and rejected the call).
    var showsInAppCallUI: Bool {
        switch phase {
        case .idle, .incoming: return false
        default: return true
        }
    }

    // Recents bookkeeping — set by the SIP transitions below.
    fileprivate var direction: CallRecord.Direction = .outgoing
    fileprivate var beganAt: Date?
    fileprivate var connectedAt: Date?

    fileprivate func begin(_ dir: CallRecord.Direction, remote: String) {
        self.direction = dir
        self.remote = remote
        beganAt = Date()
        connectedAt = nil
    }

    fileprivate func reset() {
        if let began = beganAt, !remote.isEmpty {
            CallHistory.shared.add(number: remote,
                                   direction: direction,
                                   missed: direction == .incoming && connectedAt == nil,
                                   start: began,
                                   duration: connectedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0)
        }
        phase = .idle; remote = ""; isMuted = false; isSpeaker = false
        beganAt = nil; connectedAt = nil
    }
}

/// Real SIP engine on liblinphone (linphonesw). Kept behind this seam so the
/// UI never touches the SDK directly and the engine could be swapped (license
/// fallback: baresip) without rewriting the app.
///
/// Nothing is hardcoded: the Core account is built entirely from the
/// QR-provisioned `Provisioning` (host / port / transport / credentials).
/// CallKit is driven by CallManager; this engine reports SIP call-state
/// transitions up to it via `onIncomingCall` / `onCallEnded`.
final class SipEngine {
    static let shared = SipEngine()
    private init() {}

    private var core: Core?
    private var coreDelegate: CoreDelegate?
    private var currentCall: Call?
    private var linAccounts: [Account] = []
    private var provisionings: [Provisioning] = []
    private var pathMonitor: NWPathMonitor?
    private var lastPathKey: String?

    // Transport ladder — when a line can't register (some networks eat SIP on
    // port 5060), fetch the server's transport list over HTTPS and walk it:
    // QR transport -> TCP -> alt TCP -> TLS. The winner is persisted.
    private struct Ladder { var tried: [String]; var candidates: [(t: String, p: Int)] }
    private var ladders: [String: Ladder] = [:]
    private var pendingChoice: [String: (t: String, p: Int)] = [:]
    private var regTimers: [String: DispatchSourceTimer] = [:]

    private(set) var isConfigured = false
    var isRegistered: Bool {
        core?.defaultAccount?.state == .Ok
    }

    func isAccountRegistered(_ index: Int) -> Bool {
        linAccounts.indices.contains(index) && linAccounts[index].state == .Ok
    }

    // Set by CallManager so SIP-originated events reach CallKit.
    var onIncomingCall: ((_ from: String, _ displayName: String) -> Void)?
    var onCallEnded: (() -> Void)?
    var onCallConnected: (() -> Void)?

    // MARK: - Lifecycle

    /// Single-account convenience (first sign-in path).
    func configure(with p: Provisioning) { configure(accounts: [p], activeIndex: 0) }

    /// Build/refresh the liblinphone Core from QR-provisioned accounts. ALL
    /// accounts register simultaneously (incoming rings from any of them);
    /// `activeIndex` selects the outbound line. Nothing is hardcoded.
    func configure(accounts: [Provisioning], activeIndex: Int) {
        guard !accounts.isEmpty else { shutdown(); return }
        do {
            let factory = Factory.Instance
            if core == nil {
                let c = try factory.createCore(configPath: nil, factoryConfigPath: nil, systemContext: nil)
                // Codecs: Opus + G.711 (matches the PBX). Audio only.
                c.videoActivationPolicy?.automaticallyInitiate = false
                c.videoActivationPolicy?.automaticallyAccept = false
                // CallKit owns the audio session. Without this, liblinphone
                // activates its OWN AVAudioSession, which works for outgoing
                // (it drives it alone) but on a CallKit-answered INCOMING call
                // it fights CallKit and no mic/speaker audio flows. Telling the
                // Core CallKit is enabled makes it defer to our
                // activateAudioSession() calls from provider(didActivate:).
                c.callkitEnabled = true
                // Delegate: bridge SIP call state -> CallKit (CallManager).
                let delegate = EngineCoreDelegate(engine: self)
                c.addDelegate(delegate: delegate)
                c.keepAliveEnabled = true
                try c.start()
                self.coreDelegate = delegate
                self.core = c
                startNetworkMonitor()
            }
            guard let core = core else { return }

            core.clearAccounts()
            core.clearAllAuthInfo()
            linAccounts.removeAll()
            provisionings = accounts
            for t in regTimers.values { t.cancel() }
            regTimers.removeAll()
            ladders.removeAll()
            pendingChoice.removeAll()

            for p in accounts {
                let auth = try factory.createAuthInfo(username: p.username, userid: p.username,
                                                      passwd: p.password, ha1: nil, realm: nil, domain: p.domain)
                core.addAuthInfo(info: auth)

                let params = try core.createAccountParams()
                let identity = try factory.createAddress(addr: "sip:\(p.username)@\(p.domain)")
                try params.setIdentityaddress(newValue: identity)
                let serverUri = "sip:\(p.domain):\(p.effectivePort);transport=\(p.effectiveTransport.lowercased())"
                let serverAddr = try factory.createAddress(addr: serverUri)
                try params.setServeraddress(newValue: serverAddr)
                params.registerEnabled = true
                params.expires = 60       // matches the PBX NAT re-register cadence

                let account = try core.createAccount(params: params)
                try core.addAccount(account: account)
                linAccounts.append(account)
                log("account added \(p.username)@\(p.domain):\(p.effectivePort)/\(p.effectiveTransport)")
                watchRegistration(key: p.key)
            }
            setOutboundAccount(activeIndex)
            isConfigured = true
            log("configured \(accounts.count) account(s), outbound line #\(activeIndex)")
        } catch {
            log("configure failed: \(error)")
            isConfigured = false
        }
    }

    /// Which account outgoing calls use (the dialer's line picker).
    func setOutboundAccount(_ index: Int) {
        guard let core = core else { return }
        core.defaultAccount = linAccounts.indices.contains(index) ? linAccounts[index] : linAccounts.first
    }

    /// REGISTER now — invoked on foreground and from a VoIP push so the PBX's
    /// push-wake window sees our REGISTER and delivers the waiting call. Makes
    /// sure every line is register-enabled (a prior build could have disabled
    /// them) before refreshing.
    func ensureRegistered() {
        guard let core = core else { return }
        for account in linAccounts where account.params?.registerEnabled == false {
            if let np = account.params?.clone() { np.registerEnabled = true; account.params = np }
        }
        core.refreshRegisters()
        log("ensureRegistered()")
    }

    /// WiFi ⇄ cellular handoff. Without this the Core's sockets stay bound to
    /// the network the app registered on — away from home, dialing goes into
    /// a dead socket until relaunch. Toggling networkReachable forces a
    /// rebind + fresh REGISTER on the new path.
    private func startNetworkMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let key = path.availableInterfaces.map(\.name).joined(separator: ",")
                + "|" + String(describing: path.status)
            guard key != self.lastPathKey else { return }
            let first = self.lastPathKey == nil
            self.lastPathKey = key
            guard !first else { return }   // initial callback = current state, no rebind needed
            DispatchQueue.main.async {
                guard let core = self.core else { return }
                self.log("network path changed (\(key)) — rebinding")
                core.networkReachable = false
                core.networkReachable = true
                core.refreshRegisters()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    // MARK: - Transport ladder

    /// Human-readable transport a line is currently using (Settings shows it).
    func accountTransportInfo(_ index: Int) -> String {
        guard linAccounts.indices.contains(index),
              let addr = linAccounts[index].params?.serverAddress else { return "" }
        return "\(String(describing: addr.transport).uppercased()) :\(addr.port)"
    }

    /// Give a fresh registration ~10s; if the line is still not registered,
    /// start (or continue) the ladder. Failed responses advance it sooner.
    private func watchRegistration(key: String) {
        regTimers[key]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10)
        timer.setEventHandler { [weak self] in self?.registrationStalled(key: key) }
        timer.resume()
        regTimers[key] = timer
    }

    private func registrationStalled(key: String) {
        guard let idx = provisionings.firstIndex(where: { $0.key == key }) else { return }
        guard !isAccountRegistered(idx) else { return }
        log("ladder: \(key) not registered after timeout")
        advanceLadder(key: key)
    }

    fileprivate func handleRegistrationState(_ account: Account, _ state: RegistrationState, _ message: String) {
        guard let idx = linAccounts.firstIndex(where: { $0 === account }),
              provisionings.indices.contains(idx) else { return }
        let p = provisionings[idx]
        switch state {
        case .Ok:
            regTimers[p.key]?.cancel()
            regTimers[p.key] = nil
            if let win = pendingChoice[p.key] {
                log("ladder: \(p.key) registered on \(win.t):\(win.p) — remembering it")
                pendingChoice[p.key] = nil
                Task { @MainActor in
                    SessionStore.shared.transportLearned(key: p.key, transport: win.t, port: win.p)
                }
            }
            ladders[p.key] = nil
        case .Failed:
            log("ladder: \(p.key) registration failed (\(message))")
            advanceLadder(key: p.key)
        default:
            break
        }
    }

    private func advanceLadder(key: String) {
        guard let idx = provisionings.firstIndex(where: { $0.key == key }) else { return }
        let p = provisionings[idx]
        guard p.transportMode == nil else { return }   // manual pin: never ladder
        if ladders[key] == nil {
            ladders[key] = Ladder(tried: ["\(p.effectiveTransport):\(p.effectivePort)"], candidates: [])
            Task { [weak self] in
                // Fetched over HTTPS — gets through networks that eat SIP.
                let list = await TransportDiscovery.fetch(apiBase: p.apiBase)
                DispatchQueue.main.async {
                    guard let self = self, self.ladders[key] != nil else { return }
                    self.ladders[key]?.candidates = list.isEmpty
                        ? [("TCP", p.port), ("TLS", 5061)]   // sane guesses if discovery is unreachable
                        : list
                    self.tryNextRung(key: key)
                }
            }
            return
        }
        tryNextRung(key: key)
    }

    private func tryNextRung(key: String) {
        guard var lad = ladders[key], !lad.candidates.isEmpty,
              let idx = provisionings.firstIndex(where: { $0.key == key }),
              linAccounts.indices.contains(idx), core != nil else { return }
        let p = provisionings[idx]
        guard let next = lad.candidates.first(where: { !lad.tried.contains("\($0.t):\($0.p)") }) else {
            log("ladder: exhausted for \(key) — staying on \(p.effectiveTransport):\(p.effectivePort)")
            ladders[key] = nil
            return
        }
        lad.tried.append("\(next.t):\(next.p)")
        ladders[key] = lad
        log("ladder: trying \(next.t):\(next.p) for \(key)")
        do {
            let account = linAccounts[idx]
            if let np = account.params?.clone() {
                let serverUri = "sip:\(p.domain):\(next.p);transport=\(next.t.lowercased())"
                let addr = try Factory.Instance.createAddress(addr: serverUri)
                try np.setServeraddress(newValue: addr)
                account.params = np
                pendingChoice[key] = next
                core?.refreshRegisters()
                watchRegistration(key: key)
            }
        } catch {
            log("ladder: applying \(next.t):\(next.p) failed: \(error)")
        }
    }

    func shutdown() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathKey = nil
        for t in regTimers.values { t.cancel() }
        regTimers.removeAll()
        ladders.removeAll()
        pendingChoice.removeAll()
        provisionings.removeAll()
        core?.stop()
        core = nil
        coreDelegate = nil
        currentCall = nil
        linAccounts.removeAll()
        isConfigured = false
        log("shutdown()")
    }

    // MARK: - Call control (invoked by CallManager only)

    func placeCall(to number: String) {
        guard let core = core else { return }
        do {
            guard let addr = core.interpretUrl(url: "sip:\(number)@\(core.defaultAccount?.params?.domain ?? "")", applyInternationalPrefix: false) else {
                log("placeCall failed: bad address for \(number)"); return
            }
            let params = try core.createCallParams(call: nil)
            params.mediaEncryption = .None
            params.recordFile = Self.newRecordPath()   // armed; records only if the user taps Record
            currentCall = core.inviteAddressWithParams(addr: addr, params: params)
            log("placeCall(\(number))")
        } catch { log("placeCall failed: \(error)") }
    }

    func answerCall() {
        guard let core = core, let call = currentCall else { return }
        do {
            let params = try core.createCallParams(call: call)
            params.recordFile = Self.newRecordPath()   // armed for the Record button
            try call.acceptWithParams(params: params)
            log("answerCall()")
        } catch {
            do { try call.accept(); log("answerCall() (plain)") }
            catch { log("answer failed: \(error)") }
        }
    }

    func terminateAllCalls() {
        do { try core?.terminateAllCalls(); log("terminateAllCalls()") }
        catch { log("terminate failed: \(error)") }
        currentCall = nil
    }

    func setMuted(_ muted: Bool) { core?.micEnabled = !muted; log("setMuted(\(muted))") }

    func setHold(_ hold: Bool) {
        do { if hold { try currentCall?.pause() } else { try currentCall?.resume() } }
        catch { log("hold failed: \(error)") }
    }

    func sendDTMF(_ digits: String) {
        for ch in digits { try? currentCall?.sendDtmf(dtmf: ch.asciiValue.map { Int8($0) } ?? 0) }
        log("sendDTMF(\(digits))")
    }

    func audioSessionActivated(_ active: Bool) {
        // CallKit owns the AVAudioSession; hand activation to liblinphone.
        core?.activateAudioSession(activated: active)
        log("audioSession(\(active))")
    }

    /// Voicemail one-touch — *97 on every Nováre PBX.
    func dialVoicemail() { placeCall(to: "*97") }

    // MARK: - Transfer / conference / recording / DND

    /// App-level Do Not Disturb: incoming calls are declined busy (the PBX
    /// then follows its busy path — usually voicemail). No ring, no screen.
    var dndEnabled = false

    /// Blind transfer the live call to another number (REFER).
    func transferCall(to number: String) {
        guard let core = core, let call = currentCall else { return }
        guard let addr = core.interpretUrl(url: "sip:\(number)@\(core.defaultAccount?.params?.domain ?? "")", applyInternationalPrefix: false) else { return }
        do { try call.transferTo(referTo: addr); log("transfer -> \(number)") }
        catch { log("transfer failed: \(error)") }
    }

    /// Second call for a 3-way: current call auto-holds, new call dials.
    func addCall(to number: String) {
        placeCall(to: number)   // liblinphone pauses the active call automatically
    }

    /// Merge everything into a local 3-way conference.
    func mergeCalls() {
        guard let core = core, core.callsNb > 1 else { return }
        do { try core.addAllToConference(); log("merged \(core.callsNb) calls") }
        catch { log("merge failed: \(error)") }
    }

    var hasMultipleCalls: Bool { (core?.callsNb ?? 0) > 1 }

    /// Start/stop recording the live call. Files land in Documents (visible
    /// in the iOS Files app) as novare-call-<timestamp>.wav.
    private(set) var isRecording = false
    func toggleRecording() {
        guard let call = currentCall else { return }
        if isRecording { call.stopRecording(); isRecording = false; log("recording stopped") }
        else { call.startRecording(); isRecording = true; log("recording started") }
    }

    fileprivate static func newRecordPath() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("novare-call-\(stamp).wav").path
    }

    // MARK: - Delegate callbacks (called by CoreDelegateStub)

    fileprivate func handleCallState(_ call: Call, _ state: Call.State) {
        let remote = call.remoteAddress?.username ?? "Unknown"
        switch state {
        case .IncomingReceived:
            if dndEnabled {
                try? call.decline(reason: Reason.Busy)
                log("DND: declined incoming from \(remote)")
                Task { @MainActor in
                    CallHistory.shared.add(number: remote, direction: .incoming,
                                           missed: true, start: Date(), duration: 0)
                }
                return
            }
            currentCall = call
            let name = call.remoteAddress?.displayName ?? remote
            Task { @MainActor in
                CallSession.shared.begin(.incoming, remote: remote)
                CallSession.shared.phase = .incoming
            }
            onIncomingCall?(remote, name)
        case .OutgoingInit, .OutgoingProgress:
            currentCall = call
            Task { @MainActor in
                if CallSession.shared.beganAt == nil {
                    CallSession.shared.begin(.outgoing, remote: remote)
                }
                CallSession.shared.phase = .dialing
            }
        case .OutgoingRinging:
            Task { @MainActor in CallSession.shared.phase = .ringing }
        case .Connected, .StreamsRunning:
            Task { @MainActor in
                if case .connected = CallSession.shared.phase {} else {
                    let now = Date()
                    CallSession.shared.connectedAt = now
                    CallSession.shared.phase = .connected(now)
                }
            }
            onCallConnected?()
        case .End, .Error, .Released:
            Task { @MainActor in CallSession.shared.reset() }
            onCallEnded?()
            if call === currentCall { currentCall = nil }
        default:
            break
        }
    }

    private func log(_ s: String) { print("[SipEngine] \(s)") }
}

/// Concrete CoreDelegate that forwards call-state changes to the engine.
/// (CoreDelegate is a protocol in linphonesw; the SDK's own CoreDelegateStub
/// class is closure-based, so this uses a distinct name.)
private final class EngineCoreDelegate: CoreDelegate {
    weak var engine: SipEngine?
    init(engine: SipEngine) { self.engine = engine }

    func onCallStateChanged(core: Core, call: Call, state: Call.State, message: String) {
        engine?.handleCallState(call, state)
    }
    func onAccountRegistrationStateChanged(core: Core, account: Account, state: RegistrationState, message: String) {
        print("[SipEngine] registration -> \(state) \(message)")
        engine?.handleRegistrationState(account, state, message)
    }
}

/// Asks the line's own server (over HTTPS, which firewalls rarely block) what
/// SIP transports it offers. Used by the ladder and the Settings pin.
enum TransportDiscovery {
    struct Entry: Codable { let transport: String; let port: Int }
    struct Reply: Codable { let transports: [Entry] }
    static func fetch(apiBase: URL) async -> [(t: String, p: Int)] {
        var req = URLRequest(url: apiBase.appendingPathComponent("user/sip-transports"))
        req.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return [] }
        return reply.transports.map { ($0.transport.uppercased(), $0.port) }
    }
}
