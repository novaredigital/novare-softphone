import Intents

/// SiriKit intents extension — REQUIRED for a CarPlay *communication* app.
///
/// Apple's rule: "To work with CarPlay, a VoIP app must allow the user to search
/// the call history and start audio calls using Siri." Until an app both
/// DECLARES those intents and ships an Intents extension that handles them, iOS
/// does not consider it a CarPlay communication app at all — it never appears in
/// Settings > General > CarPlay > <car> > Apps, and the head unit never hands it
/// a scene. That was the cause of the 2026-07-23 field failure on Mark's Audi:
/// the entitlement, the CarPlay scene, the scene delegate and the car icon were
/// all verified correct and the app STILL never showed, because this piece was
/// missing.
///
/// The handlers here intentionally do the minimum Apple requires: they accept
/// the intent and hand control back to the app (`.continueInApp`), where the
/// existing CallManager/CallKit path already knows how to place a call. Nothing
/// here dials on its own.
final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any { self }
}

// MARK: - Start a call ("call Erik on Nóvare Phone")

extension IntentHandler: INStartCallIntentHandling {
    func handle(intent: INStartCallIntent,
                completion: @escaping (INStartCallIntentResponse) -> Void) {
        // Hand off to the app; NovarePhoneApp's NSUserActivity handling picks
        // this up and routes it through CallManager.
        let activity = NSUserActivity(activityType: NSStringFromClass(INStartCallIntent.self))
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }

    func resolveContacts(for intent: INStartCallIntent,
                         with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        guard let contacts = intent.contacts, !contacts.isEmpty else {
            completion([INStartCallContactResolutionResult.needsValue()])
            return
        }
        completion(contacts.map { INStartCallContactResolutionResult.success(with: $0) })
    }
}

// MARK: - Search call history ("did I miss a call on Nóvare Phone")

extension IntentHandler: INSearchCallHistoryIntentHandling {
    func handle(intent: INSearchCallHistoryIntent,
                completion: @escaping (INSearchCallHistoryIntentResponse) -> Void) {
        // Recents live in the app (CallHistory) — continue there rather than
        // duplicating the store inside the extension.
        completion(INSearchCallHistoryIntentResponse(code: .continueInApp, userActivity: nil))
    }
}
