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
            // Returning to the foreground: make sure we're registered (the
            // binding may have lapsed while suspended). We deliberately do NOT
            // un-register on background — a VoIP push launches/wakes the app in
            // the background, and un-registering there would drop the very call
            // the push is delivering. iOS suspends us on its own; the binding
            // then expires and the PBX push-wakes us for the next call.
            if phase == .active { SipEngine.shared.ensureRegistered() }
        }
    }
}
