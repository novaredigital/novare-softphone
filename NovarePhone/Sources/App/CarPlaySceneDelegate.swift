import CarPlay
import UIKit

/// CARPLAY 1.1 — the Nóvare dialer on the car's built-in screen. A calling
/// CarPlay app shows lists (Recents, Favorites) on the head unit and places
/// calls through the SAME CallKit path as the rest of the app, so the in-call
/// screen, Bluetooth audio routing, and steering-wheel controls all work.
///
/// ⚠️ ENTITLEMENT GATE: CarPlay calling requires Apple's managed entitlement
/// `com.apple.developer.carplay-calling`, which is REQUESTED from Apple (not
/// auto-granted) and then enabled on the App ID + provisioning profile. This
/// code compiles and signs without it, but the CarPlay scene only connects on
/// a real head unit / the CarPlay Simulator once Apple grants it. Until then
/// the phone app is unaffected — CarPlay simply doesn't appear.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        AppLog.shared.write("[CarPlay] connected")
        let tab = CPTabBarTemplate(templates: [recentsTemplate(), favoritesTemplate()])
        interfaceController.setRootTemplate(tab, animated: false, completion: nil)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        AppLog.shared.write("[CarPlay] disconnected")
    }

    // MARK: - Templates (built on the main thread — scene delegate callbacks are main)

    private func recentsTemplate() -> CPListTemplate {
        let records = MainActor.assumeIsolated { CallHistory.shared.records }
        // Collapse to the most recent 40, de-duplicated by number so the driver
        // sees a short, glanceable list rather than every leg.
        var seen = Set<String>()
        let items: [CPListItem] = records.prefix(120).compactMap { r in
            guard !seen.contains(r.number) else { return nil }
            seen.insert(r.number)
            let subtitle = (r.direction == .incoming ? (r.missed ? "Missed" : "Incoming") : "Outgoing")
            let item = CPListItem(text: displayName(for: r.number), detailText: subtitle + " · " + r.number)
            item.handler = { [weak self] _, completion in self?.call(r.number); completion() }
            return item
        }.prefix(40).map { $0 }
        let list = CPListTemplate(title: "Recents", sections: [CPListSection(items: items)])
        list.tabTitle = "Recents"
        list.tabImage = UIImage(systemName: "clock.fill")
        if items.isEmpty { list.emptyViewSubtitleVariants = ["No recent calls"] }
        return list
    }

    private func favoritesTemplate() -> CPListTemplate {
        let favs = MainActor.assumeIsolated { FavoritesStore.shared.favorites }
        let items: [CPListItem] = favs.map { f in
            let item = CPListItem(text: f.name.isEmpty ? f.number : f.name, detailText: f.number)
            item.handler = { [weak self] _, completion in self?.call(f.number); completion() }
            return item
        }
        let list = CPListTemplate(title: "Favorites", sections: [CPListSection(items: items)])
        list.tabTitle = "Favorites"
        list.tabImage = UIImage(systemName: "star.fill")
        if items.isEmpty { list.emptyViewSubtitleVariants = ["Star a contact in the app to see it here"] }
        return list
    }

    // MARK: - Calling

    private func call(_ number: String) {
        AppLog.shared.write("[CarPlay] place call -> \(number)")
        // Same CallKit-integrated path as Siri / the in-app dialer, so the call
        // shows on the car screen and audio routes to the car automatically.
        CallManager.shared.startOutgoingCall(to: number)
    }

    /// Prefer a saved Favorite name for a number; otherwise show the number.
    private func displayName(for number: String) -> String {
        let match = MainActor.assumeIsolated { FavoritesStore.shared.favorites.first { $0.number == number } }
        return match?.name.isEmpty == false ? match!.name : number
    }
}
