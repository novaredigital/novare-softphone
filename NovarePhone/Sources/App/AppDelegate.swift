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
        return true
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
        CallManager.shared.reportIncomingCall(from: caller, displayName: callerName) {
            // With the call screen up, wake the SIP engine so the PBX's
            // push-wake window (20s) sees our REGISTER and delivers the call.
            SipEngine.shared.ensureRegistered()
            completion()
        }
    }
}
