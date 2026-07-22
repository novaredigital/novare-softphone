import SwiftUI

/// The Ext tab — every extension on this line's server, one tap to call.
/// Fed by GET /api/user/extensions (the /user realm the line signed into at
/// QR time; nothing hardcoded). Pull to refresh; searchable.
///
/// CUSTOMIZE 1.1 (Mark):
///  - Edit mode: tap a row to hide/show it, drag the handle to reorder.
///  - Hidden extensions drop to the BOTTOM under a "Hidden" divider (still
///    callable, just out of the way) — reversible any time.
///  - Choices persist on-device (UserDefaults).
struct ExtensionsView: View {
    @EnvironmentObject var session: SessionStore
    @State private var extensions: [ExtEntry] = []
    @State private var search = ""
    @State private var loadError: String?
    @State private var editing = false
    @State private var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenExtensions") ?? [])
    // RELABEL 1.1: user's own names for extensions, on-device. Empty/cleared
    // label reverts to the server's name.
    @State private var labels: [String: String] = (UserDefaults.standard.dictionary(forKey: "extensionLabels") as? [String: String]) ?? [:]
    @State private var renaming: ExtEntry?
    @State private var renameText = ""
    // v2 key: adopting Mark's 2026-07-22 alphabetical arrangement supersedes any
    // order saved under the old key; dragging still overrides from here on.
    @State private var order: [String] = UserDefaults.standard.stringArray(forKey: "extensionOrder.v2") ?? ExtensionsView.defaultOrder

    /// Mark's arrangement (2026-07-22): Erik first, then the house rooms
    /// A→Z by name, then the city lines A→Z (DC = Washington DC, under W),
    /// then whatever's left (appends automatically in server order).
    static let defaultOrder: [String] = [
        "510",                                  // Erik
        // house — alphabetical by name
        "211",                                  // Den
        "205",                                  // Down Kitchen
        "216",                                  // Eriks Bedroom
        "213",                                  // Exercise Room
        "212", "552",                           // Garage
        "201", "203", "209", "218",             // Home 201/203/209/218
        "227",                                  // Kitchen
        "210",                                  // Mark Bedroom
        "207", "208",                           // Mark Closet
        "202",                                  // Mark Home
        "204",                                  // Master Bathroom
        "214",                                  // Office Home
        "215",                                  // Solarium
        "206",                                  // Workshop
        // cities — alphabetical
        "220",                                  // Atlanta (ATL)
        "603", "610",                           // Chicago
        "615",                                  // Knoxville
        "605", "613",                           // Las Vegas
        "607",                                  // London
        "612",                                  // Los Angeles
        "601",                                  // Madrid
        "606",                                  // Nashville
        "602", "611",                           // New York
        "225",                                  // Raleigh
        "221",                                  // San Fran
        "616",                                  // San Jose
        "614",                                  // Seattle
        "608",                                  // St Joseph
        "604",                                  // Toll Free
        "600",                                  // Warsaw
        "226"                                   // Washington DC (DC)
    ]

    struct ExtEntry: Codable, Identifiable {
        let extension_: String
        let name: String?
        var id: String { extension_ }
        enum CodingKeys: String, CodingKey { case extension_ = "extension", name }
    }

    // The user's order first, then any new server extensions in server order.
    private var ordered: [ExtEntry] {
        let idx = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return extensions.enumerated().sorted { a, b in
            let ia = idx[a.element.extension_], ib = idx[b.element.extension_]
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Custom label first, then the server name.
    private func displayName(_ e: ExtEntry) -> String {
        if let l = labels[e.extension_], !l.isEmpty { return l }
        return e.name?.isEmpty == false ? e.name! : "Extension \(e.extension_)"
    }

    private func matchesSearch(_ e: ExtEntry) -> Bool {
        guard !search.isEmpty else { return true }
        let q = search.lowercased()
        return e.extension_.contains(q) || (e.name ?? "").lowercased().contains(q)
            || displayName(e).lowercased().contains(q)
    }

    private func saveLabel(_ ext: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { labels.removeValue(forKey: ext) } else { labels[ext] = t }
        UserDefaults.standard.set(labels, forKey: "extensionLabels")
    }

    private var activeList: [ExtEntry] { ordered.filter { !hidden.contains($0.extension_) && matchesSearch($0) } }
    private var hiddenList: [ExtEntry] { ordered.filter { hidden.contains($0.extension_) && matchesSearch($0) } }

    private func toggleHidden(_ ext: String) {
        if hidden.contains(ext) { hidden.remove(ext) } else { hidden.insert(ext) }
        UserDefaults.standard.set(Array(hidden), forKey: "hiddenExtensions")
    }

    // Drag in Edit mode reorders the ACTIVE (shown) rows; hidden rows live in
    // their own bottom section. Disabled while searching (indices shift).
    private func moveRows(from source: IndexSet, to destination: Int) {
        guard search.isEmpty else { return }
        var active = ordered.filter { !hidden.contains($0.extension_) }
        active.move(fromOffsets: source, toOffset: destination)
        // Persist: new active order first, hidden ones keep their relative order after.
        order = active.map(\.extension_) + ordered.filter { hidden.contains($0.extension_) }.map(\.extension_)
        UserDefaults.standard.set(order, forKey: "extensionOrder.v2")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let err = loadError, extensions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3").font(.largeTitle).foregroundStyle(.secondary)
                        Text(err).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    List {
                        Section {
                            ForEach(activeList) { e in
                                row(e, dimmed: false)
                            }
                            .onMove(perform: moveRows)
                        }
                        if !hiddenList.isEmpty {
                            Section {
                                ForEach(hiddenList) { e in
                                    row(e, dimmed: true)
                                }
                            } header: {
                                // The divider between active and hidden.
                                VStack(alignment: .leading, spacing: 4) {
                                    Divider()
                                    Text("Hidden").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .environment(\.editMode, .constant(editing ? .active : .inactive))
                    .searchable(text: $search, prompt: "Name or extension")
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Extensions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !extensions.isEmpty {
                        Button(editing ? "Done" : "Edit") { editing.toggle() }
                    }
                }
            }
            .alert("Rename \(renaming.map { "ext \($0.extension_)" } ?? "")",
                   isPresented: Binding(get: { renaming != nil },
                                        set: { if !$0 { renaming = nil } })) {
                TextField(renaming?.name ?? "Label", text: $renameText)
                Button("Save") {
                    if let e = renaming { saveLabel(e.extension_, renameText) }
                    renaming = nil
                }
                Button("Use Server Name") {
                    if let e = renaming { saveLabel(e.extension_, "") }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("This label shows only on this phone. Use Server Name puts the original back.")
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ e: ExtEntry, dimmed: Bool) -> some View {
        Button {
            if editing { toggleHidden(e.extension_) }
            else { CallManager.shared.startOutgoingCall(to: e.extension_) }
        } label: {
            HStack {
                if editing {
                    Image(systemName: dimmed ? "eye.slash" : "eye")
                        .foregroundStyle(dimmed ? Color.secondary : Color.accentColor)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(e))
                        .foregroundStyle(dimmed ? .secondary : .primary)
                    // Show the server's name under a custom label so the
                    // original identity is never lost.
                    Text(labels[e.extension_]?.isEmpty == false
                         ? "ext \(e.extension_) · \(e.name ?? "")"
                         : "ext \(e.extension_)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if editing {
                    Text(dimmed ? "Hidden" : "Shown")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(dimmed ? Color.secondary : Color.green)
                }
            }
        }
        // RELABEL 1.1: long-press any extension to rename it (your label lives
        // on this phone only; clear the field to go back to the server name).
        .contextMenu {
            Button {
                renameText = labels[e.extension_] ?? ""
                renaming = e
            } label: { Label("Rename", systemImage: "pencil") }
            Button {
                toggleHidden(e.extension_)
            } label: {
                Label(hidden.contains(e.extension_) ? "Show" : "Hide",
                      systemImage: hidden.contains(e.extension_) ? "eye" : "eye.slash")
            }
        }
    }

    private func load() async {
        guard let p = session.provisioning else { return }
        struct Reply: Codable { let extensions: [ExtEntry] }
        var req = URLRequest(url: p.apiBase.appendingPathComponent("user/extensions"))
        req.timeoutInterval = 8
        if let token = session.userToken(for: p) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                loadError = "The extension directory isn't available on this server yet."
                return
            }
            extensions = try JSONDecoder().decode(Reply.self, from: data).extensions
            loadError = nil
        } catch {
            loadError = "Couldn't reach the server. Pull down or tap to retry."
        }
    }
}
