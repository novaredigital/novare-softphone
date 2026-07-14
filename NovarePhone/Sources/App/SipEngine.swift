import Foundation

/// Facade over the SIP stack (liblinphone via the linphonesw SPM package).
/// Kept behind this seam so (a) the UI never touches the SDK directly and
/// (b) the engine could be swapped (license fallback: baresip) without
/// rewriting the app.
///
/// NOTE: the linphonesw calls are stubbed until the SPM dependency is added
/// to the Xcode project — every method logs and no-ops so the UI is testable
/// in the simulator today.
final class SipEngine {
    static let shared = SipEngine()
    private init() {}

    private(set) var isConfigured = false
    private(set) var isRegistered = false

    /// Build the linphone Core from QR-provisioned values. Nothing hardcoded:
    /// "sip:USER@DOMAIN:PORT;transport=..." comes straight from Provisioning.
    func configure(with p: Provisioning) {
        // linphonesw: Factory.Instance.createCore + AccountParams from `p`.
        isConfigured = true
        log("configure \(p.username)@\(p.domain):\(p.port)/\(p.transport)")
        ensureRegistered()
    }

    /// REGISTER now (also invoked from a VoIP push so the PBX's 20s
    /// push-wake window finds us).
    func ensureRegistered() {
        guard isConfigured else { return }
        log("ensureRegistered()")
        // linphonesw: core.refreshRegisters()
    }

    func shutdown() {
        isConfigured = false
        isRegistered = false
        log("shutdown()")
    }

    // MARK: - Call control (invoked by CallManager only)

    func placeCall(to number: String) { log("placeCall(\(number))") }
    func answerCall() { log("answerCall()") }
    func terminateAllCalls() { log("terminateAllCalls()") }
    func setMuted(_ muted: Bool) { log("setMuted(\(muted))") }
    func setHold(_ hold: Bool) { log("setHold(\(hold))") }
    func sendDTMF(_ digits: String) { log("sendDTMF(\(digits))") }
    func audioSessionActivated(_ active: Bool) { log("audioSession(\(active))") }

    /// Voicemail one-touch — *97 on every Nováre PBX.
    func dialVoicemail() { placeCall(to: "*97") }

    private func log(_ s: String) { print("[SipEngine] \(s)") }
}
