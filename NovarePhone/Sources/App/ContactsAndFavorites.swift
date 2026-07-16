import SwiftUI
import Contacts

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
        }
    }
}

struct ContactsView: View {
    @StateObject private var store = ContactsStore.shared
    @StateObject private var favs = FavoritesStore.shared
    @State private var search = ""

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
                        Text(c.name)
                    }
                }
            }
            .navigationTitle("Contacts")
            .searchable(text: $search, prompt: "Search name or number")
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
