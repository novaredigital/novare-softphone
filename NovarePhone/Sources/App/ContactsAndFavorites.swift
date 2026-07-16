import SwiftUI
import Contacts
import ContactsUI

// MARK: - Device contacts (read-only; contacts never leave the phone)

struct PhoneContact: Identifiable {
    let id: String
    let name: String
    let numbers: [(label: String, number: String)]
}

@MainActor
final class ContactsStore: ObservableObject {
    static let shared = ContactsStore()

    @Published private(set) var contacts: [PhoneContact] = []
    @Published private(set) var denied = false

    func load() async {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            if !granted { denied = true; return }
        } else if status == .denied || status == .restricted {
            denied = true; return
        }
        denied = false
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactOrganizationNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var out: [PhoneContact] = []
        let fetched: [PhoneContact] = await Task.detached {
            var list: [PhoneContact] = []
            try? store.enumerateContacts(with: request) { c, _ in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let display = name.isEmpty ? c.organizationName : name
                let numbers = c.phoneNumbers.map { n in
                    (label: CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: n.label ?? ""),
                     number: n.value.stringValue)
                }
                guard !display.isEmpty, !numbers.isEmpty else { return }
                list.append(PhoneContact(id: c.identifier, name: display, numbers: numbers))
            }
            return list
        }.value
        out = fetched
        contacts = out
    }
}

// MARK: - Favorites (local, like the Phone app's star list)

struct Favorite: Codable, Identifiable, Equatable {
    var id: String { name + number }
    let name: String
    let number: String
}

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: [Favorite] = []

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("favorites.json")
    }

    private init() {
        if let d = try? Data(contentsOf: fileURL),
           let f = try? JSONDecoder().decode([Favorite].self, from: d) { favorites = f }
    }

    func isFavorite(_ number: String) -> Bool { favorites.contains { $0.number == number } }

    func add(name: String, number: String) {
        guard !isFavorite(number) else { return }
        favorites.append(Favorite(name: name, number: number))
        save()
    }

    func remove(at offsets: IndexSet) { favorites.remove(atOffsets: offsets); save() }
    func remove(number: String) { favorites.removeAll { $0.number == number }; save() }
    func move(from: IndexSet, to: Int) { favorites.move(fromOffsets: from, toOffset: to); save() }

    private func save() {
        if let d = try? JSONEncoder().encode(favorites) { try? d.write(to: fileURL) }
    }
}

// MARK: - One-time Favorites seed (Mark's iPhone Phone-app favorites, 2026-07-16)

/// Ordered exactly like the Phone app screenshots. Runs ONCE, only into an
/// empty Favorites list, after Contacts access is granted. Names are matched
/// against the device contacts; the number is picked by its label, falling
/// back to the contact's first number. Unmatched names are skipped silently.
private let favoritesSeed: [(name: String, label: String)] = [
    ("Phone Call Recorder", "home"),
    ("Erik Broeren", "iPhone"),
    ("Mary Roser", "phone"),
    ("Doug Adair", "work"),
    ("Loren & Julie Churchill", "phone"),
    ("Loren Churchhill", "mobile"),
    ("Sean Churchill", "mobile"),
    ("Terry Burnett", "mobile"),
    ("Lisa Berry", "mobile"),
    ("kelly Stoker (moms Friend)", "mobile"),
    ("Joseph Farmer", "work"),
    ("Jane Cobb Pickering", "phone"),
    ("Jeffrey Jump", "work"),
    ("John Miller", "work"),
    ("Philip Carson", "work"),
    ("Todd Fowler", "work"),
    ("Justin Arnold", "work"),
    ("Shannon Faires", "work"),
    ("Chattanooga Allergy Clinic Alicia Nurse", "work"),
    ("Food City Pharmacy", "work"),
    ("Mike Wynn", "mobile"),
    ("Highland Vet Center", "mobile"),
    ("Paige (VCSG) Wichman (VCSG)", "work"),
    ("Animal Emergency Hospital", "work"),
    ("Pet D-tails Grooming", "mobile"),
    ("Jason Irrigation", "mobile"),
    ("Terry Culbertson Morgan Alarm Security", "mobile"),
    ("Morgan Alarm Monitoring", "work"),
    ("Catherine Thomas", "home"),
]

extension FavoritesStore {
    func seedFromContactsIfNeeded(_ contacts: [PhoneContact]) {
        // v2: v1's substring fallback let tiny contact names hijack slots
        // ("AI" matched inside "PAIge…"). v2 wipes a v1-seeded list and
        // rebuilds with safe matching.
        let v1 = "com.novaredigital.novarephone.favseed1"
        let v2 = "com.novaredigital.novarephone.favseed2"
        guard !UserDefaults.standard.bool(forKey: v2), !contacts.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: v1) { while !favorites.isEmpty { remove(at: IndexSet(integer: 0)) } }
        guard favorites.isEmpty else { return }

        let norm: (String) -> String = { $0.lowercased().filter { !$0.isWhitespace } }
        let tokens: (String) -> Set<String> = {
            Set($0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 })
        }
        for item in favoritesSeed {
            let want = norm(item.name)
            let wantTokens = tokens(item.name)
            // 1) exact name; 2) containment ONLY for names ≥6 chars; 3) every
            //    word (≥3 letters) of the contact's name appears in the
            //    favorite's displayed name (handles "Alicia Nurse" whose card
            //    keeps the clinic in the company field). Longest match wins.
            let candidates = contacts.filter { c in
                let n = norm(c.name)
                if n == want { return true }
                if n.count >= 6 && (n.contains(want) || want.contains(n)) { return true }
                let t = tokens(c.name)
                return !t.isEmpty && t.isSubset(of: wantTokens)
            }
            guard let c = candidates.max(by: { norm($0.name).count < norm($1.name).count }),
                  !c.numbers.isEmpty else { continue }
            let n = c.numbers.first(where: { $0.label.compare(item.label, options: .caseInsensitive) == .orderedSame })
                 ?? c.numbers[0]
            add(name: c.name, number: n.number)
        }
        if !favorites.isEmpty {
            UserDefaults.standard.set(true, forKey: v2)
            UserDefaults.standard.set(true, forKey: v1)
        }
    }
}

// MARK: - Views

struct FavoritesView: View {
    @StateObject private var favs = FavoritesStore.shared

    var body: some View {
        NavigationStack {
            List {
                if favs.favorites.isEmpty {
                    Text("Star people in Contacts and they appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(favs.favorites) { f in
                    Button {
                        CallManager.shared.startOutgoingCall(to: dialable(f.number))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.headline)
                                Text(f.number).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "phone.fill").foregroundStyle(.green)
                        }
                    }
                }
                .onDelete { favs.remove(at: $0) }
                .onMove { favs.move(from: $0, to: $1) }
            }
            .navigationTitle("Favorites")
            .toolbar { if !favs.favorites.isEmpty { EditButton() } }
            .task {
                await ContactsStore.shared.load()
                favs.seedFromContactsIfNeeded(ContactsStore.shared.contacts)
            }
        }
    }
}

/// Apple's native contact card (view/edit/delete existing, or create new) —
/// identical to the Contacts app, so edits sync to the address book + iCloud.
struct ContactCardView: UIViewControllerRepresentable {
    let contactId: String?          // nil = create a new contact

    func makeCoordinator() -> Coord { Coord() }
    final class Coord: NSObject, CNContactViewControllerDelegate {
        func contactViewController(_ vc: CNContactViewController, didCompleteWith contact: CNContact?) {
            vc.dismiss(animated: true)
        }
    }
    func makeUIViewController(context: Context) -> UINavigationController {
        let store = CNContactStore()
        let vc: CNContactViewController
        if let id = contactId,
           let full = try? store.unifiedContact(withIdentifier: id,
                                                keysToFetch: [CNContactViewController.descriptorForRequiredKeys()]) {
            vc = CNContactViewController(for: full)
            vc.allowsEditing = true
            vc.allowsActions = false   // our rows handle dialing; card is for editing
        } else {
            vc = CNContactViewController(forNewContact: nil)
        }
        vc.contactStore = store
        vc.delegate = context.coordinator
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

private struct ContactCardTarget: Identifiable {
    let id: String
    let contactId: String?
}

struct ContactsView: View {
    @StateObject private var store = ContactsStore.shared
    @StateObject private var favs = FavoritesStore.shared
    @State private var search = ""
    @State private var card: ContactCardTarget?

    private var filtered: [PhoneContact] {
        guard !search.isEmpty else { return store.contacts }
        return store.contacts.filter { $0.name.localizedCaseInsensitiveContains(search)
            || $0.numbers.contains { $0.number.contains(search) } }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.denied {
                    Text("Contacts access is off. Allow it in Settings → Nóvare Phone → Contacts.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { c in
                    DisclosureGroup {
                        ForEach(c.numbers, id: \.number) { n in
                            HStack {
                                Button {
                                    CallManager.shared.startOutgoingCall(to: dialable(n.number))
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(n.label.isEmpty ? "phone" : n.label)
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(n.number)
                                    }
                                }
                                Spacer()
                                Button {
                                    if favs.isFavorite(n.number) { favs.remove(number: n.number) }
                                    else { favs.add(name: c.name, number: n.number) }
                                } label: {
                                    Image(systemName: favs.isFavorite(n.number) ? "star.fill" : "star")
                                        .foregroundStyle(.yellow)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } label: {
                        HStack {
                            Text(c.name)
                            Spacer()
                            Button {
                                card = ContactCardTarget(id: c.id, contactId: c.id)
                            } label: {
                                Image(systemName: "info.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Contacts")
            .searchable(text: $search, prompt: "Search name or number")
            .toolbar {
                Button {
                    card = ContactCardTarget(id: "new", contactId: nil)
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(item: $card, onDismiss: { Task { await store.load() } }) { t in
                ContactCardView(contactId: t.contactId).ignoresSafeArea()
            }
            .task { await store.load() }
            .refreshable { await store.load() }
        }
    }
}

/// Strip formatting so "+1 (423) 265-1411" dials as digits the PBX routes.
func dialable(_ number: String) -> String {
    let kept = number.filter { "0123456789+*#".contains($0) }
    return kept.isEmpty ? number : kept
}
