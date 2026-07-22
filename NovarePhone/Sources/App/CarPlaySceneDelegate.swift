import CarPlay
import UIKit
import Combine

/// CARPLAY 1.1 — the Nóvare dialer on the car's built-in screen: Recents,
/// Favorites, and Contacts lists that place calls through the SAME CallKit
/// path as the rest of the app, so the native CarPlay call screen, Bluetooth
/// audio routing, and steering-wheel controls all work. Arbitrary numbers are
/// dialed by voice ("Hey Siri, call … on Nováre Phone") — CarPlay forbids a
/// free-form keypad in third-party calling apps by design.
///
/// Lists refresh LIVE while connected: a call you just made shows in Recents,
/// a contact starred on the phone appears in Favorites, without replugging.
///
/// ⚠️ ENTITLEMENT GATE: CarPlay calling requires Apple's managed entitlement
/// `com.apple.developer.carplay-calling` (requested from Apple, then enabled
/// on the App ID). This code compiles and signs without it; until granted the
/// phone app is unaffected and CarPlay simply doesn't appear.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var recentsList: CPListTemplate?
    private var favoritesList: CPListTemplate?
    private var contactsList: CPListTemplate?
    private var subs: [AnyCancellable] = []

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        AppLog.shared.write("[CarPlay] connected")

        let recents = CPListTemplate(title: "Recents", sections: [])
        recents.tabTitle = "Recents"
        recents.tabImage = UIImage(systemName: "clock.fill")
        recents.emptyViewSubtitleVariants = ["No recent calls"]
        recentsList = recents

        let favorites = CPListTemplate(title: "Favorites", sections: [])
        favorites.tabTitle = "Favorites"
        favorites.tabImage = UIImage(systemName: "star.fill")
        favorites.emptyViewSubtitleVariants = ["Star a contact in the app to see it here"]
        favoritesList = favorites

        let contacts = CPListTemplate(title: "Contacts", sections: [])
        contacts.tabTitle = "Contacts"
        contacts.tabImage = UIImage(systemName: "person.crop.circle")
        contacts.emptyViewSubtitleVariants = ["Allow Contacts access in the app"]
        contactsList = contacts

        interfaceController.setRootTemplate(CPTabBarTemplate(templates: [recents, favorites, contacts]),
                                            animated: false, completion: nil)

        // Scene-delegate callbacks arrive on the main thread; hop into the
        // MainActor world to read the stores and wire live refresh.
        MainActor.assumeIsolated {
            refreshAll()
            // LIVE REFRESH: any change on the phone updates the car screen.
            CallHistory.shared.$records
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.onMain { $0.refreshRecents() } }
                .store(in: &subs)
            FavoritesStore.shared.$favorites
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.onMain { $0.refreshFavorites() } }
                .store(in: &subs)
            ContactsStore.shared.$contacts
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.onMain { $0.refreshContacts() } }
                .store(in: &subs)
            // Contacts may not be loaded yet (app cold-launched into CarPlay).
            Task { await ContactsStore.shared.load() }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        subs.removeAll()
        recentsList = nil; favoritesList = nil; contactsList = nil
        self.interfaceController = nil
        AppLog.shared.write("[CarPlay] disconnected")
    }

    /// Sinks already deliver on main; this just re-enters MainActor isolation
    /// cleanly for the store reads inside the refresh functions.
    private func onMain(_ body: @escaping (CarPlaySceneDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in guard let self else { return }; body(self) }
    }

    // MARK: - List building (main thread; store reads via MainActor)

    private func refreshAll() { refreshRecents(); refreshFavorites(); refreshContacts() }

    private func refreshRecents() {
        let records = MainActor.assumeIsolated { CallHistory.shared.records }
        var seen = Set<String>()
        let items: [CPListItem] = records.prefix(120).compactMap { r in
            guard !seen.contains(r.number) else { return nil }
            seen.insert(r.number)
            let subtitle = (r.direction == .incoming ? (r.missed ? "Missed" : "Incoming") : "Outgoing")
            let item = CPListItem(text: displayName(for: r.number), detailText: subtitle + " · " + r.number)
            item.handler = { [weak self] _, completion in self?.call(r.number); completion() }
            return item
        }.prefix(40).map { $0 }
        recentsList?.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }

    private func refreshFavorites() {
        let favs = MainActor.assumeIsolated { FavoritesStore.shared.favorites }
        let items: [CPListItem] = favs.prefix(40).map { f in
            let item = CPListItem(text: f.name.isEmpty ? f.number : f.name, detailText: f.number)
            item.handler = { [weak self] _, completion in self?.call(f.number); completion() }
            return item
        }
        favoritesList?.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }

    private func refreshContacts() {
        let contacts = MainActor.assumeIsolated { ContactsStore.shared.contacts }
        // CarPlay lists are meant to be glanceable — cap well under the
        // system's own item limit; full search lives on the phone.
        let items: [CPListItem] = contacts.prefix(100).map { c in
            let detail = c.numbers.count == 1 ? c.numbers[0].number : "\(c.numbers.count) numbers"
            let item = CPListItem(text: c.name, detailText: detail)
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                if c.numbers.count == 1 {
                    self.call(c.numbers[0].number)
                } else {
                    self.pushNumberPicker(for: c)
                }
                completion()
            }
            return item
        }
        contactsList?.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }

    /// A contact with several numbers gets a one-level picker (Home/Work/…).
    private func pushNumberPicker(for contact: PhoneContact) {
        let items: [CPListItem] = contact.numbers.map { n in
            let item = CPListItem(text: n.number, detailText: n.label)
            item.handler = { [weak self] _, completion in self?.call(n.number); completion() }
            return item
        }
        let list = CPListTemplate(title: contact.name, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    // MARK: - Calling

    private func call(_ number: String) {
        AppLog.shared.write("[CarPlay] place call -> \(number)")
        // Same CallKit-integrated path as Siri / the in-app dialer, so the call
        // shows on the car's native call screen and audio routes to the car.
        CallManager.shared.startOutgoingCall(to: number)
    }

    /// Contact name → favorite name → the bare number.
    private func displayName(for number: String) -> String {
        MainActor.assumeIsolated {
            if let n = ContactsStore.shared.name(forNumber: number) { return n }
            if let f = FavoritesStore.shared.favorites.first(where: { $0.number == number }),
               !f.name.isEmpty { return f.name }
            return number
        }
    }
}
