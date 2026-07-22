import UIKit
import PushKit

/// Owns the PushKit VoIP registry. iOS 13+ hard rule: every VoIP push MUST
/// immediately report an incoming call to CallKit or Apple kills the app —
/// so the push handler goes straight to CallManager.reportIncomingCall.
final class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate {
    private var voipRegistry: PKPushRegistry?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        registerForVoIPPushes()
        NotificationManager.shared.requestAuthorization()   // missed-call / voicemail badges (1.1)
        return true
    }

    // MISSED-CALL BADGE 1.1: opening the app = the user has seen their missed
    // calls, so clear that part of the badge.
    func applicationDidBecomeActive(_ application: UIApplication) {
        NotificationManager.shared.clearMissed()
    }

    private func registerForVoIPPushes() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
    }

    // MARK: - PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate pushCredentials: PKPushCredentials,
                      for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        // Sent to the per-tenant endpoint learned at QR sign-in — never a
        // hardcoded URL.
        Task { await SessionStore.shared.registerPushToken(token) }
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        Task { await SessionStore.shared.removePushToken() }
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        // Mandatory: report to CallKit BEFORE doing anything else.
        let caller = payload.dictionaryPayload["caller"] as? String ?? "Unknown"
        let callerName = payload.dictionaryPayload["callerName"] as? String ?? caller
        AppLog.shared.write("[Push] VoIP push received: caller=\(caller)")
        CallManager.shared.reportIncomingCall(from: caller, displayName: callerName) {
            // Lost-answer fix: if the connection was confirmed alive seconds
            // ago (open app), do NOT rebuild it — the reflexive re-register
            // was tearing down the very connection the incoming call and our
            // answer were about to use, so the PBX never saw the answer and
            // rolled to voicemail. Only refresh when the registration is
            // actually stale (app was suspended; timers frozen).
            if SipEngine.shared.hasFreshRegistration {
                AppLog.shared.write("[Push] connection fresh — riding it, no re-register")
            } else {
                SipEngine.shared.ensureRegistered()
            }
            completion()
        }
    }
}
