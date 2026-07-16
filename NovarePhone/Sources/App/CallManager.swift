import Foundation
import CallKit
import AVFAudio

/// CallKit integration — the native ring screen, lock-screen answer, and the
/// system's audio session handoff. One CXProvider for the app's lifetime.
final class CallManager: NSObject, CXProviderDelegate {
    static let shared = CallManager()

    private let provider: CXProvider
    private let callController = CXCallController()
    private var activeCallUUID: UUID?

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
        let uuid = UUID()
        activeCallUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.localizedCallerName = displayName
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in completion() }
    }

    // MARK: - Outgoing

    func startOutgoingCall(to number: String) {
        let uuid = UUID()
        activeCallUUID = uuid
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .phoneNumber, value: number))
        callController.request(CXTransaction(action: action)) { _ in }
    }

    func endActiveCall() {
        guard let uuid = activeCallUUID else {
            // No CallKit call to unwind (e.g. UI hang-up raced the report) —
            // end at the SIP layer so the user is never stuck in a call.
            SipEngine.shared.terminateAllCalls()
            return
        }
        callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
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
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        SipEngine.shared.answerCall()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        SipEngine.shared.terminateAllCalls()
        activeCallUUID = nil
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
