import SwiftUI

/// The Ext tab — every extension on this line's server, one tap to call.
/// Fed by GET /api/user/extensions (the /user realm the line signed into at
/// QR time; nothing hardcoded). Pull to refresh; searchable.
struct ExtensionsView: View {
    @EnvironmentObject var session: SessionStore
    @State private var extensions: [ExtEntry] = []
    @State private var search = ""
    @State private var loadError: String?

    struct ExtEntry: Codable, Identifiable {
        let extension_: String
        let name: String?
        var id: String { extension_ }
        enum CodingKeys: String, CodingKey { case extension_ = "extension", name }
    }

    private var filtered: [ExtEntry] {
        guard !search.isEmpty else { return extensions }
        let q = search.lowercased()
        return extensions.filter {
            $0.extension_.contains(q) || ($0.name ?? "").lowercased().contains(q)
        }
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
                    List(filtered) { e in
                        Button {
                            CallManager.shared.startOutgoingCall(to: e.extension_)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.name?.isEmpty == false ? e.name! : "Extension \(e.extension_)")
                                        .foregroundStyle(.primary)
                                    Text("ext \(e.extension_)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "phone.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "Name or extension")
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Extensions")
        }
        .task { await load() }
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
