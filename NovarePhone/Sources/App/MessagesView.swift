import SwiftUI

/// MESSAGES 1.1 — business texting from the Nováre Telecom number.
/// Fed by GET /user/sms; sends via POST /user/sms; read state via
/// PUT /user/sms/:id/read. Conversations are grouped by the other party's
/// number. Unread inbound texts show a dot; opening a thread marks them read;
/// swipe a conversation to flip read/unread so you can come back to it.
struct SMessage: Codable, Identifiable {
    let id: Int
    let direction: String          // "inbound" | "outbound"
    let from_number: String
    let to_number: String
    let body: String
    let status: String?
    var read: Int?
    let created_at: String?

    var isInbound: Bool { direction == "inbound" }
    var counterpart: String { isInbound ? from_number : to_number }
    var isUnread: Bool { isInbound && (read ?? 1) == 0 }
}

struct Conversation: Identifiable {
    let number: String
    let messages: [SMessage]
    var id: String { number }
    var latest: SMessage? { messages.last }
    var unreadCount: Int { messages.filter(\.isUnread).count }
}

struct MessagesView: View {
    @EnvironmentObject var session: SessionStore
    @State private var messages: [SMessage] = []
    @State private var status: String?
    @State private var composeTo = ""
    @State private var showCompose = false

    private var conversations: [Conversation] {
        let grouped = Dictionary(grouping: messages, by: \.counterpart)
        return grouped.map { Conversation(number: $0.key, messages: $0.value.sorted { $0.id < $1.id }) }
            .sorted { ($0.latest?.id ?? 0) > ($1.latest?.id ?? 0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let s = status { Text(s).font(.footnote).foregroundStyle(.secondary) }
                ForEach(conversations) { c in
                    NavigationLink {
                        ThreadView(number: c.number, allMessages: $messages)
                            .environmentObject(session)
                    } label: {
                        HStack(spacing: 8) {
                            if c.unreadCount > 0 {
                                Circle().fill(Color.accentColor).frame(width: 9, height: 9)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.pretty(c.number))
                                    .font(.headline)
                                    .fontWeight(c.unreadCount > 0 ? .bold : .regular)
                                Text(c.latest?.body ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(Self.shortDate(c.latest?.created_at))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { await setConversationRead(c, to: c.unreadCount > 0) }
                        } label: {
                            Label(c.unreadCount > 0 ? "Mark Read" : "Mark Unread",
                                  systemImage: c.unreadCount > 0 ? "envelope.open" : "envelope.badge")
                        }
                        .tint(c.unreadCount > 0 ? .gray : .accentColor)
                    }
                }
            }
            .navigationTitle("Messages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .alert("New message to", isPresented: $showCompose) {
                TextField("Phone number", text: $composeTo).keyboardType(.phonePad)
                Button("Start") { composeTo = composeTo.filter { "0123456789+".contains($0) } }
                Button("Cancel", role: .cancel) { composeTo = "" }
            }
            .navigationDestination(isPresented: Binding(
                get: { !composeTo.isEmpty }, set: { if !$0 { composeTo = "" } })) {
                ThreadView(number: composeTo, allMessages: $messages)
                    .environmentObject(session)
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    static func pretty(_ n: String) -> String {
        let d = n.filter(\.isNumber)
        if d.count == 11 && d.hasPrefix("1") {
            let a = d.dropFirst()
            return "(\(a.prefix(3))) \(a.dropFirst(3).prefix(3))-\(a.suffix(4))"
        }
        if d.count == 10 { return "(\(d.prefix(3))) \(d.dropFirst(3).prefix(3))-\(d.suffix(4))" }
        return n
    }
    static func shortDate(_ s: String?) -> String {
        guard let s = s, s.count >= 16 else { return "" }
        return String(s.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    private func load() async {
        guard let p = session.provisioning, let tok = session.userToken(for: p) else {
            status = "Sign-in required for messages — pull down to retry."
            return
        }
        var req = URLRequest(url: p.apiBase.appendingPathComponent("user/sms"))
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        do {
            struct Reply: Codable { let messages: [SMessage] }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                status = "Texting isn't enabled on this server yet."
                return
            }
            messages = (try JSONDecoder().decode(Reply.self, from: data)).messages
            status = messages.isEmpty ? "No messages yet — tap the pencil to start one." : nil
            NotificationManager.shared.setSmsUnread(messages.filter(\.isUnread).count)
        } catch {
            status = "Couldn't load messages — pull down to retry."
        }
    }

    private func setConversationRead(_ c: Conversation, to read: Bool) async {
        guard let p = session.provisioning, let tok = session.userToken(for: p) else { return }
        // Mark every inbound message in the conversation (unread ones when
        // marking read; the latest one when flagging unread to revisit).
        let targets = read ? c.messages.filter(\.isUnread)
                           : c.messages.filter(\.isInbound).suffix(1).map { $0 }
        for m in targets {
            var req = URLRequest(url: p.apiBase.appendingPathComponent("user/sms/\(m.id)/read"))
            req.httpMethod = "PUT"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["read": read])
            _ = try? await URLSession.shared.data(for: req)
            if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].read = read ? 1 : 0 }
        }
        NotificationManager.shared.setSmsUnread(messages.filter(\.isUnread).count)
    }
}

/// One conversation — bubbles + compose bar.
struct ThreadView: View {
    @EnvironmentObject var session: SessionStore
    let number: String
    @Binding var allMessages: [SMessage]
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?

    private var thread: [SMessage] {
        allMessages.filter { $0.counterpart == number }.sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(thread) { m in
                            HStack {
                                if !m.isInbound { Spacer(minLength: 40) }
                                Text(m.body)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(m.isInbound ? Color(.secondarySystemBackground) : Color.accentColor)
                                    .foregroundStyle(m.isInbound ? Color.primary : Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                if m.isInbound { Spacer(minLength: 40) }
                            }
                            .id(m.id)
                            .padding(.horizontal, 10)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: thread.count) { _ in
                    if let last = thread.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear {
                    if let last = thread.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let e = sendError {
                Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            HStack(spacing: 8) {
                TextField("Text message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            }
            .padding(10)
        }
        .navigationTitle(MessagesView.pretty(number))
        .navigationBarTitleDisplayMode(.inline)
        .task { await markThreadRead() }
    }

    private func send() async {
        guard let p = session.provisioning, let tok = session.userToken(for: p) else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true; sendError = nil
        var req = URLRequest(url: p.apiBase.appendingPathComponent("user/sms"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["to": number, "body": body])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                draft = ""
                // Optimistic append; the next refresh replaces it with the server row.
                allMessages.insert(SMessage(id: (allMessages.map(\.id).max() ?? 0) + 1,
                                            direction: "outbound", from_number: "",
                                            to_number: number, body: body,
                                            status: "sent", read: 1, created_at: nil), at: 0)
            } else {
                sendError = "Couldn't send — try again."
            }
        } catch { sendError = "Couldn't send — check connection." }
        sending = false
    }

    private func markThreadRead() async {
        guard let p = session.provisioning, let tok = session.userToken(for: p) else { return }
        for m in thread.filter(\.isUnread) {
            var req = URLRequest(url: p.apiBase.appendingPathComponent("user/sms/\(m.id)/read"))
            req.httpMethod = "PUT"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["read": true])
            _ = try? await URLSession.shared.data(for: req)
            if let i = allMessages.firstIndex(where: { $0.id == m.id }) { allMessages[i].read = 1 }
        }
        NotificationManager.shared.setSmsUnread(allMessages.filter(\.isUnread).count)
    }
}
