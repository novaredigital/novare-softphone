import Foundation
import linphonesw
import AVFAudio
import Combine

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

    fileprivate func reset() { phase = .idle; remote = ""; isMuted = false; isSpeaker = false }
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

    private(set) var isConfigured = false
    var isRegistered: Bool {
        core?.defaultAccount?.state == .Ok
    }

    // Set by CallManager so SIP-originated events reach CallKit.
    var onIncomingCall: ((_ from: String, _ displayName: String) -> Void)?
    var onCallEnded: (() -> Void)?
    var onCallConnected: (() -> Void)?

    // MARK: - Lifecycle

    /// Build the liblinphone Core from QR-provisioned values and register.
    func configure(with p: Provisioning) {
        do {
            let factory = Factory.Instance
            let core = try factory.createCore(configPath: nil, factoryConfigPath: nil, systemContext: nil)

            // Credentials.
            let realm = p.domain
            let auth = try factory.createAuthInfo(username: p.username, userid: p.username,
                                                  passwd: p.password, ha1: nil, realm: nil, domain: realm)
            core.addAuthInfo(info: auth)

            // Account: sip:USER@DOMAIN registering at DOMAIN:PORT;transport=...
            let params = try core.createAccountParams()
            let identity = try factory.createAddress(addr: "sip:\(p.username)@\(p.domain)")
            try params.setIdentityaddress(newValue: identity)
            let serverUri = "sip:\(p.domain):\(p.port);transport=\(p.transport.lowercased())"
            let serverAddr = try factory.createAddress(addr: serverUri)
            try params.setServeraddress(newValue: serverAddr)
            params.registerEnabled = true
            params.expires = 60           // matches the PBX NAT re-register cadence

            let account = try core.createAccount(params: params)
            try core.addAccount(account: account)
            core.defaultAccount = account

            // Codecs: Opus + G.711 (matches the PBX). Audio only.
            core.videoActivationPolicy?.automaticallyInitiate = false
            core.videoActivationPolicy?.automaticallyAccept = false

            // Delegate: bridge SIP call state -> CallKit (CallManager).
            let delegate = EngineCoreDelegate(engine: self)
            core.addDelegate(delegate: delegate)
            self.coreDelegate = delegate

            try core.start()
            self.core = core
            isConfigured = true
            log("configured \(p.username)@\(p.domain):\(p.port)/\(p.transport)")
        } catch {
            log("configure failed: \(error)")
            isConfigured = false
        }
    }

    /// REGISTER now (also invoked from a VoIP push so the PBX's push-wake
    /// window sees our REGISTER and delivers the waiting call).
    func ensureRegistered() {
        guard let core = core else { return }
        core.refreshRegisters()
        log("ensureRegistered()")
    }

    func shutdown() {
        core?.stop()
        core = nil
        coreDelegate = nil
        currentCall = nil
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
            currentCall = core.inviteAddressWithParams(addr: addr, params: params)
            log("placeCall(\(number))")
        } catch { log("placeCall failed: \(error)") }
    }

    func answerCall() {
        do { try currentCall?.accept(); log("answerCall()") }
        catch { log("answer failed: \(error)") }
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

    // MARK: - Delegate callbacks (called by CoreDelegateStub)

    fileprivate func handleCallState(_ call: Call, _ state: Call.State) {
        let remote = call.remoteAddress?.username ?? "Unknown"
        switch state {
        case .IncomingReceived:
            currentCall = call
            let name = call.remoteAddress?.displayName ?? remote
            Task { @MainActor in
                CallSession.shared.remote = remote
                CallSession.shared.phase = .incoming
            }
            onIncomingCall?(remote, name)
        case .OutgoingInit, .OutgoingProgress:
            currentCall = call
            Task { @MainActor in
                CallSession.shared.remote = remote
                CallSession.shared.phase = .dialing
            }
        case .OutgoingRinging:
            Task { @MainActor in CallSession.shared.phase = .ringing }
        case .Connected, .StreamsRunning:
            Task { @MainActor in
                if case .connected = CallSession.shared.phase {} else {
                    CallSession.shared.phase = .connected(Date())
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
    }
}
