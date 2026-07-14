import SwiftUI

/// Nováre Phone — entry point.
/// The app holds NO server configuration. Everything (SIP host, port,
/// transport, credentials, push-registration URL) arrives in the QR
/// payload at sign-in and lives in the Keychain afterward.
@main
struct NovarePhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = SessionStore.shared

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
    }
}
