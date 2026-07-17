import SwiftUI
import UIKit

/// Nováre Phone — entry point.
/// The app holds NO server configuration. Everything (SIP host, port,
/// transport, credentials, push-registration URL) arrives in the QR
/// payload at sign-in and lives in the Keychain afterward.
@main
struct NovarePhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = SessionStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if session.isSignedIn {
                MainTabView()
                    .environmentObject(session)
            } else {
                SignInView()
                    .environmentObject(session)
            }
        }
        .onChange(of: scenePhase) { phase in
            // Push-wake handoff: when the app leaves the foreground with no
            // active call, un-REGISTER so the PBX immediately push-wakes us
            // for incoming calls (a stale binding would swallow them until it
            // expired). Foreground re-registers. A background task buys the
            // seconds the un-REGISTER needs to reach the server.
            switch phase {
            case .background:
                guard !CallSession.shared.isActive else { break }
                let task = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                SipEngine.shared.setBackgrounded(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    UIApplication.shared.endBackgroundTask(task)
                }
            case .active:
                SipEngine.shared.setBackgrounded(false)
            default:
                break
            }
        }
    }
}
