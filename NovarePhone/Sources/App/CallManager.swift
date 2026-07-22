import Foundation
import CallKit
import AVFAudio
import UIKit

/// CallKit integration — the native ring screen, lock-screen answer, and the
/// system's audio session handoff. One CXProvider for the app's lifetime.
final class CallManager: NSObject, CXProviderDelegate {
    static let shared = CallManager()

    private let provider: CXProvider
    private let callController = CXCallController()
    private var activeCallUUID: UUID?
    private var lastReportedAt: Date?

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]
        // Branding on the native call UI comes from the app icon + display name.
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)

        // Engine → CallKit bridge: a SIP INVITE (app already awake) surfaces the
        // native ring screen; a remote hangup / failure ends the CallKit call so
        // the system UI dismisses. (The VoIP-push path reports via AppDelegate.)
        SipEngine.shared.onIncomingCall = { [weak self] number, name in
            self?.reportIncomingCall(from: number, displayName: name) {}
        }
        SipEngine.shared.onCallEnded = { [weak self] in
            self?.endActiveCall()
        }
        SipEngine.shared.onCallConnected = { [weak self] in
            guard let uuid = self?.activeCallUUID else { return }
            self?.provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        }
    }

    // MARK: - Incoming (from a VoIP push or a live SIP INVITE)

    func reportIncomingCall(from number: String, displayName: String, completion: @escaping () -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.localizedCallerName = displayName
        update.hasVideo = false
        // Idempotent: one incoming call reaches here TWICE — first from the
        // VoIP push (before the SIP INVITE), then again when the SIP
        // .IncomingReceived fires. Reporting a second CXCall makes iOS show two
        // calls with a Swap button, neither answerable — so UPDATE the existing
        // call instead. BUT only if iOS still has that call LIVE: a stale UUID
        // from a prior call must never swallow a fresh incoming call (that made
        // the phone silently not ring). The call observer is the source of truth.
        if let existing = activeCallUUID {
            let observerLive = callController.callObserver.calls.contains { $0.uuid == existing && !$0.hasEnded }
            // The call observer updates asynchronously: two forks of the same
            // call can land within milliseconds, before the observer has seen
            // the first report — which reported a SECOND CXCall (swap UI, and
            // CallKit never activated the audio session → dead air). Treat a
            // report from the last few seconds as live even if the observer
            // hasn't caught up yet.
            let justReported = lastReportedAt.map { Date().timeIntervalSince($0) < 3 } ?? false
            if observerLive || justReported {
                AppLog.shared.write("[CallManager] incoming update (existing call) from \(number)")
                provider.reportCall(with: existing, updated: update)
                completion()
                return
            }
        }
        let uuid = UUID()
        activeCallUUID = uuid
        lastReportedAt = Date()
        AppLog.shared.write("[CallManager] incoming reported to CallKit from \(number)")
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in completion() }
    }

    // MARK: - Outgoing

    /// True redial source: the last number DIALED from anywhere in the app
    /// (keypad, Favorites, Recents, Ext) — even if the call never connected.
    private static let lastDialedKey = "com.novaredigital.novarephone.lastdialed"
    static var lastDialedNumber: String? {
        UserDefaults.standard.string(forKey: lastDialedKey)
    }

    /// SAFETY 1.0.17 — never place 911 (or the 933 e911-test line) over VoIP.
    /// A softphone SIP call to 911 may not reach the caller's LOCAL emergency
    /// center and does not carry cellular location, so it's a genuine hazard.
    /// Hand the call to the iPhone's native cellular dialer, which routes
    /// emergency calls correctly. Returns true if it handled (caller must stop).
    static func emergencyHandoffIfNeeded(_ number: String) -> Bool {
        let digits = number.filter(\.isNumber)
        guard digits == "911" || digits == "933" else { return false }
        AppLog.shared.write("[EMERGENCY] \(digits) dialed — handing off to native cellular dialer, NOT VoIP")
        if let url = URL(string: "tel://\(digits)") {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }
        return true
    }

    func startOutgoingCall(to number: String) {
        if Self.emergencyHandoffIfNeeded(number) { return }   // 911/933 -> native cellular dialer
        UserDefaults.standard.set(number, forKey: Self.lastDialedKey)
        let uuid = UUID()
        activeCallUUID = uuid
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .phoneNumber, value: number))
        callController.request(CXTransaction(action: action)) { _ in }
    }

    func endActiveCall() {
        if let uuid = activeCallUUID {
            callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
        }
        // Always tear down at the SIP layer and clear our handle so the NEXT
        // incoming call is never blocked by a stale UUID (see reportIncomingCall).
        SipEngine.shared.terminateAllCalls()
        activeCallUUID = nil
        lastReportedAt = nil
    }

    /// In-call screen mute button — go through CallKit so the system stays in
    /// sync; fall back straight to the engine when there is no CallKit call.
    func setMuted(_ muted: Bool) {
        guard let uuid = activeCallUUID else { SipEngine.shared.setMuted(muted); return }
        callController.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { err in
            if err != nil { SipEngine.shared.setMuted(muted) }
        }
    }

    // MARK: - CXProviderDelegate (system → us)

    func providerDidReset(_ provider: CXProvider) {
        SipEngine.shared.terminateAllCalls()
        activeCallUUID = nil
        lastReportedAt = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Must run BEFORE accepting: wires liblinphone into the CallKit audio
        // session so lock-screen answers get sound (the locked-silence bug).
        SipEngine.shared.prepareAudioSession()
        if SipEngine.shared.hasRingingSipCall {
            SipEngine.shared.answerCall()
        } else {
            // Ghost-ring fix: the push drew the ring screen but the real SIP
            // call hasn't arrived yet (slow network). Answering used to be a
            // no-op — dead air while the call drifted to voicemail. Instead:
            // hold the CallKit call as "connecting", auto-answer the SIP call
            // the moment it lands, and end cleanly if it never does.
            AppLog.shared.write("[CallManager] answered before SIP call arrived — holding, auto-answer armed")
            SipEngine.shared.armAutoAnswer(seconds: 20)
            let uuid = action.callUUID
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self = self, self.activeCallUUID == uuid else { return }
                if case .connected = CallSession.shared.phase { return }
                AppLog.shared.write("[CallManager] no SIP call within 20s of answer — ending cleanly")
                self.provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                SipEngine.shared.terminateAllCalls()
                self.activeCallUUID = nil
            }
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        SipEngine.shared.terminateAllCalls()
        activeCallUUID = nil
        lastReportedAt = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        SipEngine.shared.placeCall(to: action.handle.value)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        SipEngine.shared.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        SipEngine.shared.setHold(action.isOnHold)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        SipEngine.shared.sendDTMF(action.digits)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        SipEngine.shared.audioSessionActivated(true)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        SipEngine.shared.audioSessionActivated(false)
    }
}
