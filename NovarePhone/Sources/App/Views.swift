import SwiftUI
import AVFoundation
import AVKit

// MARK: - Sign-in (QR scan; the ONLY way the app learns about a server)

struct SignInView: View {
    @EnvironmentObject var session: SessionStore
    @State private var showScanner = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("NovareTelecomLogo")
                .resizable().scaledToFit()
                .frame(maxWidth: 260)
                .padding(.horizontal, 24)
            Text("Nováre Phone")
                .font(.largeTitle).bold()
            Text("Scan the sign-in code from your\nMy Phone portal to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                showScanner = true
            } label: {
                Label("Scan Sign-In Code", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            if let err = session.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            Text("Nováre Telecom, a division of Novare Digital Corp\nnovaretelecom.com")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { payload in
                showScanner = false
                Task { await session.signIn(qrPayload: payload) }
            }
        }
    }
}

// MARK: - Main tabs

struct MainTabView: View {
    @StateObject private var call = CallSession.shared
    @StateObject private var locations = LocationReporter.shared
    @StateObject private var notifs = NotificationManager.shared
    @State private var tab = 0

    var body: some View {
        // iOS shows at most 5 bottom tabs. Ext takes the 5th slot per Mark.
        // Voicemail now has a real home in the Recents tab (All / Missed /
        // Voicemail toggle), with the unread count badged on that tab — so the
        // app-icon "N" always has a discoverable place to go. It is still also
        // reachable from the tape icon in the Keypad header.
        TabView(selection: $tab) {
            FavoritesView().tabItem { Label("Favorites", systemImage: "star.fill") }.tag(0)
            ExtensionsView().tabItem { Label("Ext", systemImage: "person.3.fill") }.tag(1)
            RecentsView().tabItem { Label("Recents", systemImage: "clock.fill") }
                .badge(notifs.vmUnread)   // unread-voicemail count on the Recents tab (VM's new home)
                .tag(2)
            ContactsView().tabItem { Label("Contacts", systemImage: "person.crop.circle") }.tag(3)
            DialerView().tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }.tag(4)
        }
        .fullScreenCover(isPresented: Binding(get: { call.showsInAppCallUI }, set: { if !$0 { } })) {
            InCallView().environmentObject(call)
        }
        // GPS: one-time notice, ONLY for lines whose consent isn't recorded
        // yet (future/customer phones — text comes from the server).
        .alert("Location", isPresented: Binding(
            get: { locations.noticeText != nil },
            set: { if !$0 { locations.noticeText = nil } })) {
            Button("OK") { locations.acceptNotice() }
            Button("Opt Out") { locations.declineNotice() }
        } message: {
            Text(locations.noticeText ?? "")
        }
        #if targetEnvironment(simulator)
        // Screenshot rig ONLY (compiled out of device builds): launch straight
        // onto a tab, optionally auto-dial once registered — the simulator has
        // no touch automation, so App Store screenshots are driven by env vars.
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if let t = env["NOVARE_SIM_TAB"], let i = Int(t), (0...4).contains(i) { tab = i }
            if let dial = env["NOVARE_SIM_DIAL"], !dial.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    SipEngine.shared.placeCall(to: dial)
                }
            }
        }
        #endif
    }
}

// MARK: - In-call screen (outgoing VoIP calls get NO system UI — this is it)

struct InCallView: View {
    @EnvironmentObject var call: CallSession
    @State private var showKeypad = false
    @State private var dtmfEntered = ""
    @State private var isRecording = false
    @State private var promptNumber = ""
    @State private var prompting: CallPrompt?

    enum CallPrompt { case transfer, addCall }

    private var stateText: String {
        switch call.phase {
        case .idle: return ""
        case .dialing: return "Calling…"
        case .ringing: return "Ringing…"
        case .incoming: return "Incoming call"
        case .connected: return "" // timer shown instead
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 40)
            Text(call.remote)
                .font(.system(size: 36, weight: .medium, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
            Group {
                if case .connected(let start) = call.phase {
                    Text(start, style: .timer).monospacedDigit()
                } else {
                    Text(stateText)
                }
            }
            .font(.title3).foregroundStyle(.secondary)

            if showKeypad {
                Text(dtmfEntered.isEmpty ? " " : dtmfEntered)
                    .font(.title2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(70)), count: 3), spacing: 8) {
                    ForEach(["1","2","3","4","5","6","7","8","9","*","0","#"], id: \.self) { k in
                        Button {
                            dtmfEntered.append(k)
                            SipEngine.shared.sendDTMF(k)
                        } label: {
                            Text(k).font(.title2).frame(width: 64, height: 64)
                                .background(Circle().fill(Color(.secondarySystemBackground)))
                        }.buttonStyle(.plain)
                    }
                }.frame(width: 224)
            }

            Spacer()

            VStack(spacing: 16) {
                HStack(spacing: 24) {
                    CallControlButton(icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                                      label: "Mute", active: call.isMuted) {
                        call.isMuted.toggle()
                        CallManager.shared.setMuted(call.isMuted)
                    }
                    CallControlButton(icon: "circle.grid.3x3.fill", label: "Keypad", active: showKeypad) {
                        showKeypad.toggle()
                    }
                    CallControlButton(icon: "speaker.wave.2.fill", label: "Speaker", active: call.isSpeaker) {
                        call.isSpeaker.toggle()
                        try? AVAudioSession.sharedInstance()
                            .overrideOutputAudioPort(call.isSpeaker ? .speaker : .none)
                    }
                    // CAR HANDS-FREE 1.0.16: full audio-route picker — send call
                    // audio to the car (Bluetooth/CarPlay), a headset, speaker, or
                    // earpiece in one tap. The Speaker toggle only flips
                    // speaker<->earpiece; this exposes EVERY route including the car.
                    AudioRouteButton()
                }
                HStack(spacing: 34) {
                    CallControlButton(icon: "arrow.uturn.right", label: "Transfer") {
                        promptNumber = ""; prompting = .transfer
                    }
                    CallControlButton(icon: SipEngine.shared.hasMultipleCalls ? "arrow.triangle.merge" : "plus",
                                      label: SipEngine.shared.hasMultipleCalls ? "Merge" : "Add Call") {
                        if SipEngine.shared.hasMultipleCalls {
                            SipEngine.shared.mergeCalls()
                        } else {
                            promptNumber = ""; prompting = .addCall
                        }
                    }
                    CallControlButton(icon: "record.circle", label: isRecording ? "Stop Rec" : "Record",
                                      active: isRecording) {
                        SipEngine.shared.toggleRecording()
                        isRecording = SipEngine.shared.isRecording
                    }
                }
            }
            .alert(prompting == .transfer ? "Transfer to" : "Add call to",
                   isPresented: Binding(get: { prompting != nil },
                                        set: { if !$0 { prompting = nil } })) {
                TextField("Number or extension", text: $promptNumber)
                    .keyboardType(.phonePad)
                Button(prompting == .transfer ? "Transfer" : "Call") {
                    let n = promptNumber.filter { "0123456789+*#".contains($0) }
                    if !n.isEmpty {
                        if prompting == .transfer { SipEngine.shared.transferCall(to: n) }
                        else { SipEngine.shared.addCall(to: n) }
                    }
                    prompting = nil
                }
                Button("Cancel", role: .cancel) { prompting = nil }
            }

            Button {
                CallManager.shared.endActiveCall()
            } label: {
                Image(systemName: "phone.down.fill").font(.title)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(.red)).foregroundStyle(.white)
            }
            .padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// NOVARE CHROME 1.1 (Mark, 2026-07-22) — every page carries the Nováre
/// Telecom logo in the top bar plus the Messages / Voicemail / Settings
/// buttons, so they're one tap away from anywhere (previously Keypad-only).
private struct NovareChrome: ViewModifier {
    @State private var showMessages = false
    @State private var showVoicemail = false
    @State private var showSettings = false
    @ObservedObject private var notifs = NotificationManager.shared

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            // Logo strip under the top bar — roughly double the old in-bar size
            // (Mark 2026-07-22); safeAreaInset pushes the page content down.
            .safeAreaInset(edge: .top, spacing: 0) {
                Image("NovareTelecomLogo")
                    .resizable().scaledToFit()
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.bar)
                    .accessibilityLabel("Nováre Telecom")
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showMessages = true } label: {
                        Image(systemName: "message.fill").countBadge(notifs.smsUnread)
                    }
                    Button { showVoicemail = true } label: {
                        Image(systemName: "recordingtape").countBadge(notifs.vmUnread)
                    }
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
            }
            .sheet(isPresented: $showMessages) {
                MessagesView().environmentObject(SessionStore.shared)
            }
            .sheet(isPresented: $showVoicemail) {
                VoicemailView().environmentObject(SessionStore.shared)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(SessionStore.shared)
            }
    }
}

extension View {
    /// Logo + Messages/Voicemail/Settings in the nav bar (all main pages).
    func novareChrome() -> some View { modifier(NovareChrome()) }
}

/// CAR HANDS-FREE 1.0.16 — in-call audio-route button styled to match the other
/// call controls. Wraps AVRoutePickerView, which opens the system output picker
/// listing every available route (car via Bluetooth/CarPlay, headset, speaker,
/// receiver). Lets a driver fix a mis-routed call in one tap without leaving the
/// app or digging through iOS Settings.
private struct AudioRouteButton: View {
    var body: some View {
        VStack(spacing: 6) {
            RoutePickerRepresentable()
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color(.secondarySystemBackground)))
            Text("Audio").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.activeTintColor = UIColor(Color.accentColor)
        v.tintColor = .label
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private struct CallControlButton: View {
    let icon: String
    let label: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon).font(.title2)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(active ? Color.accentColor : Color(.secondarySystemBackground)))
                    .foregroundStyle(active ? .white : .primary)
            }.buttonStyle(.plain)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DialerView: View {
    @EnvironmentObject var session: SessionStore
    @State private var number = ""
    @State private var showSettings = false
    @State private var showVoicemail = false
    @State private var showMessages = false
    @State private var dnd = SipEngine.shared.dndEnabled
    @StateObject private var history = CallHistory.shared
    @ObservedObject private var notifs = NotificationManager.shared
    private let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { dnd.toggle(); SipEngine.shared.dndEnabled = dnd } label: {
                    Image(systemName: dnd ? "bell.slash.fill" : "bell.fill")
                        .font(.title3)
                        .foregroundStyle(dnd ? .red : .accentColor)
                }
                if dnd {
                    Text("Do Not Disturb").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                // MESSAGES 1.1: business texting from the Nováre main number.
                Button { showMessages = true } label: {
                    Image(systemName: "message.fill").font(.title3)
                        .countBadge(notifs.smsUnread)
                }
                // Voicemail moved here from the tab bar (Ext took its slot —
                // iOS caps the bottom bar at 5). Same full voicemail screen.
                Button { showVoicemail = true } label: {
                    Image(systemName: "recordingtape").font(.title3)
                        .countBadge(notifs.vmUnread)
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.title3)
                }
            }
            .padding(.horizontal)
            Image("NovareTelecomLogo")
                .resizable().scaledToFit()
                .frame(maxWidth: 234)          // +30% (Mark 2026-07-22)
                .padding(.top, 2)
            if session.accounts.count > 1 {
                Menu {
                    ForEach(session.accounts.indices, id: \.self) { i in
                        Button {
                            session.activeIndex = i
                        } label: {
                            let a = session.accounts[i]
                            Label("\(a.accountName) (\(a.username))",
                                  systemImage: i == session.activeIndex ? "checkmark" : "phone")
                        }
                    }
                } label: {
                    let a = session.provisioning
                    Label("Line: \(a?.accountName ?? "") (\(a?.username ?? ""))",
                          systemImage: "phone.badge.checkmark")
                        .font(.subheadline)
                }
                .padding(.top, 8)
            }
            Spacer().frame(height: 10)     // tightened so the keypad rides up (Mark)
            Text(number.isEmpty ? " " : number)
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.4)
            // Fixed-width grid so the keys sit comfortably together (Mark-tuned:
            // full-width was too spread, 250pt too tight — this is the middle).
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(102)), count: 3), spacing: 12) {
                ForEach(keys, id: \.self) { k in
                    Button { number.append(k) } label: {
                        Text(k).font(.largeTitle).frame(width: 82, height: 82)
                            .background(Circle().fill(Color(.secondarySystemBackground)))
                    }.buttonStyle(.plain)
                }
            }
            .frame(width: 320)
            // Bottom row rides the same grid as the keys: call under the 0,
            // backspace under the #.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(102)), count: 3), spacing: 12) {
                Color.clear.frame(width: 82, height: 82)
                Button {
                    if number.isEmpty {
                        // Redial: first tap recalls the last number dialed from
                        // ANYWHERE in the app (persisted at dial time — the old
                        // history scan returned stale entries), second tap dials.
                        if let last = CallManager.lastDialedNumber
                            ?? history.records.first(where: { $0.direction == .outgoing })?.number {
                            number = last
                        }
                    } else {
                        CallManager.shared.startOutgoingCall(to: number)
                        number = ""   // keypad is blank again after the call
                    }
                } label: {
                    Image(systemName: "phone.fill").font(.title)
                        .frame(width: 82, height: 82)
                        .background(Circle().fill(.green)).foregroundStyle(.white)
                }.disabled(number.isEmpty && CallManager.lastDialedNumber == nil
                           && !history.records.contains(where: { $0.direction == .outgoing }))
                Button { if !number.isEmpty { number.removeLast() } } label: {
                    Image(systemName: "delete.left").font(.title2)
                        .frame(width: 82, height: 82)
                        .background(Circle().fill(Color(.secondarySystemBackground)))  // match the keys (Mark)
                }.buttonStyle(.plain).disabled(number.isEmpty)
            }
            .frame(width: 320)
            Spacer()
        }
        .padding()
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(session)
        }
        .sheet(isPresented: $showMessages) {
            MessagesView().environmentObject(session)
        }
        .sheet(isPresented: $showVoicemail) {
            VoicemailView().environmentObject(session)
        }
    }
}

struct RecentsView: View {
    @StateObject private var history = CallHistory.shared
    @StateObject private var contacts = ContactsStore.shared
    @StateObject private var notifs = NotificationManager.shared
    @State private var showNumbers = false   // toggle name ⇄ number for the whole list
    // VOICEMAIL HOME (Mark 2026-07-24): Recents gains an All / Missed / Voicemail
    // toggle so voicemail has an obvious, badged home without adding a 6th tab.
    @State private var seg = 0   // 0 = All calls, 1 = Missed, 2 = Voicemail

    private var shownRecords: [CallRecord] {
        seg == 1 ? history.records.filter(\.missed) : history.records
    }

    var body: some View {
        NavigationStack {
            Group {
              if seg == 2 {
                VoicemailList().environmentObject(SessionStore.shared)
              } else {
                List {
                    if shownRecords.isEmpty {
                        Text(seg == 1 ? "No missed calls." : "No calls yet.").foregroundStyle(.secondary)
                    }
                    ForEach(shownRecords) { r in
                    let name = contacts.name(forNumber: r.number)
                    // Primary line: contact name if known (unless toggled to numbers);
                    // secondary line shows the other value so both are always available.
                    let primary = (showNumbers ? nil : name) ?? r.number
                    let secondary: String? = (showNumbers ? name : (name != nil ? r.number : nil))
                    Button {
                        CallManager.shared.startOutgoingCall(to: r.number)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: r.direction == .incoming
                                  ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill")
                                .foregroundStyle(r.missed ? .red : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(primary).foregroundStyle(r.missed ? .red : .primary)
                                Text([secondary, r.start.formatted(date: .abbreviated, time: .shortened)]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if r.missed {
                                Text("Missed").font(.caption).foregroundStyle(.red)
                            } else if r.duration > 0 {
                                Text(Duration.seconds(r.duration).formatted(.time(pattern: .minuteSecond)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                }   // close List
              }     // close else
            }       // close Group
            .navigationTitle("Recents")
            .novareChrome()
            .safeAreaInset(edge: .top) {
                Picker("", selection: $seg) {
                    Text("All").tag(0)
                    Text("Missed").tag(1)
                    Text(notifs.vmUnread > 0 ? "Voicemail (\(notifs.vmUnread))" : "Voicemail").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.top, 6).padding(.bottom, 4)
                .background(.bar)
            }
            .toolbar {
                // Names/Numbers + Clear apply to the call lists only, not voicemail.
                if seg != 2 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(showNumbers ? "Names" : "Numbers") { showNumbers.toggle() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if !shownRecords.isEmpty { Button("Clear") { history.clear() } }
                    }
                }
            }
            .task { await contacts.load() }
        }
    }
}

// MARK: - Voicemail (list + play + call back; *97 always available)

struct VMessage: Codable, Identifiable {
    let id: Int
    let caller_id: String?
    let caller_name: String?
    let created_at: String?
    let duration: Int?
    let ai_summary: String?
    let transcript: String?
    var read: Int?          // 0 = unread (server-tracked); mutable so the UI can update in place

    var isUnread: Bool { (read ?? 1) == 0 }
}

/// Backward-compatible standalone Voicemail screen (still opened from the tape
/// icon in the Keypad header). The list itself now lives in VoicemailList so it
/// can ALSO be embedded inside the Recents tab (Mark 2026-07-24: "vm must have a
/// home") without duplicating any of the load/play/read/delete logic.
struct VoicemailView: View {
    var body: some View {
        NavigationStack {
            VoicemailList().navigationTitle("Voicemail")
        }
    }
}

/// The voicemail list — NO NavigationStack of its own, so it drops cleanly into
/// either the standalone VoicemailView or the Recents "Voicemail" segment.
struct VoicemailList: View {
    @EnvironmentObject var session: SessionStore
    @State private var messages: [VMessage] = []
    @State private var status: String?
    @State private var player: AVPlayer?
    @State private var playingId: Int?

    var body: some View {
            List {
                if let s = status {
                    Text(s).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(messages) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            // READ/UNREAD 1.1: unread voicemails show a blue dot +
                            // bold name so you know what still needs attention.
                            if m.isUnread {
                                Circle().fill(Color.accentColor).frame(width: 9, height: 9)
                            }
                            Text(m.caller_name ?? m.caller_id ?? "Unknown")
                                .font(.headline).fontWeight(m.isUnread ? .bold : .regular)
                            Spacer()
                            Text(String((m.created_at ?? "").prefix(16)).replacingOccurrences(of: "T", with: " "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let cid = m.caller_id, m.caller_name != nil, !cid.isEmpty {
                            Text(cid).font(.caption).foregroundStyle(.secondary)
                        }
                        if let summary = m.ai_summary ?? m.transcript, !summary.isEmpty {
                            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        HStack(spacing: 20) {
                            Button {
                                toggle(m)
                            } label: {
                                Label(playingId == m.id ? "Stop" : "Play",
                                      systemImage: playingId == m.id ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.bordered)
                            if let n = m.caller_id?.filter({ "0123456789+*#".contains($0) }), !n.isEmpty {
                                Button {
                                    player?.pause(); playingId = nil
                                    CallManager.shared.startOutgoingCall(to: n)
                                } label: {
                                    Label("Call Back", systemImage: "phone.fill")
                                }
                                .buttonStyle(.bordered).tint(.green)
                            }
                            if let d = m.duration, d > 0 {
                                Text("\(d)s").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await deleteVM(m) }
                        } label: { Label("Delete", systemImage: "trash") }
                        // READ/UNREAD 1.1: flip state so you can leave one to
                        // come back to it.
                        Button {
                            Task { await setRead(m, to: m.isUnread) }
                        } label: {
                            Label(m.isUnread ? "Mark Read" : "Mark Unread",
                                  systemImage: m.isUnread ? "envelope.open" : "envelope.badge")
                        }
                        .tint(m.isUnread ? .gray : .accentColor)
                    }
                }
                Section {
                    Button {
                        SipEngine.shared.dialVoicemail()
                    } label: {
                        Label("Call Voicemail (*97)", systemImage: "recordingtape")
                    }
                }
            }
            .task { await load() }
            .refreshable { await load() }
    }

    private func load() async {
        guard let p = session.provisioning else { return }
        guard let tok = session.userToken(for: p) else {
            messages = []
            status = "Signing this line in for messages… pull down to retry, or use Call Voicemail (*97) below."
            return
        }
        var req = URLRequest(url: p.apiBase.appendingPathComponent("user/voicemail"))
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        do {
            struct Reply: Codable { let messages: [VMessage] }
            let (data, _) = try await URLSession.shared.data(for: req)
            messages = (try JSONDecoder().decode(Reply.self, from: data)).messages
            NotificationManager.shared.setVoicemailUnread(messages.filter(\.isUnread).count)
            status = messages.isEmpty ? "No voicemails." : nil
        } catch {
            status = "Couldn't load messages — pull down to retry."
        }
    }

    private func toggle(_ m: VMessage) {
        if playingId == m.id { player?.pause(); playingId = nil; return }
        guard let p = session.provisioning, let tok = session.userToken(for: p) else { return }
        let url = p.apiBase.appendingPathComponent("user/voicemail/\(m.id)/audio")
        // AVURLAsset carries the Bearer header the /user audio endpoint expects
        // (AVPlayer alone can't set request headers).
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(tok)"]
        ])
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player?.play()
        playingId = m.id
        // Server marks the message read when it serves the audio; mirror it in the UI.
        updateLocalRead(id: m.id, read: true)
    }

    /// READ/UNREAD 1.1 — flip a voicemail's read state on the server, then locally.
    private func setRead(_ m: VMessage, to read: Bool) async {
        guard let p = session.provisioning, let tok = session.userToken(for: p) else { return }
        var req = URLRequest(url: p.apiBase.appendingPathComponent("user/voicemail/\(m.id)/read"))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["read": read])
        _ = try? await URLSession.shared.data(for: req)
        updateLocalRead(id: m.id, read: read)
    }

    private func updateLocalRead(id: Int, read: Bool) {
        if let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i].read = read ? 1 : 0
        }
        NotificationManager.shared.setVoicemailUnread(messages.filter(\.isUnread).count)
    }

    /// DELETE 1.1 — remove a voicemail on the server + locally.
    private func deleteVM(_ m: VMessage) async {
        guard let p = session.provisioning, let tok = session.userToken(for: p) else { return }
        if playingId == m.id { player?.pause(); playingId = nil }
        var req = URLRequest(url: p.apiBase.appendingPathComponent("user/voicemail/\(m.id)"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
        messages.removeAll { $0.id == m.id }
        NotificationManager.shared.setVoicemailUnread(messages.filter(\.isUnread).count)
    }
}

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var locations = LocationReporter.shared
    @State private var showScanner = false
    @State private var signOutIndex: Int?
    @State private var renameIndex: Int?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Lines") {
                    ForEach(session.accounts.indices, id: \.self) { i in
                        let a = session.accounts[i]
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(a.accountName) — ext \(a.username)")
                                if i == session.activeIndex {
                                    Text("OUTBOUND").font(.caption2).bold()
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                }
                            }
                            Text([a.number, a.domain].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            TimelineView(.periodic(from: .now, by: 2)) { _ in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(SipEngine.shared.isAccountRegistered(i) ? Color.green : Color.orange)
                                        .frame(width: 8, height: 8)
                                    Text(SipEngine.shared.isAccountRegistered(i)
                                         ? "Registered · \(SipEngine.shared.accountTransportInfo(i))"
                                         : "Connecting… · \(SipEngine.shared.accountTransportInfo(i))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Menu {
                                        ForEach(["Auto", "UDP", "TCP", "TLS"], id: \.self) { m in
                                            Button {
                                                Task { await session.setTransportMode(m == "Auto" ? nil : m, at: i) }
                                            } label: {
                                                if (a.transportMode ?? "Auto") == m {
                                                    Label(m, systemImage: "checkmark")
                                                } else {
                                                    Text(m)
                                                }
                                            }
                                        }
                                    } label: {
                                        Text("Transport: \(a.transportMode ?? "Auto")")
                                            .font(.caption2)
                                    }
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { session.activeIndex = i }
                        .swipeActions {
                            Button("Sign Out", role: .destructive) { signOutIndex = i }
                            Button("Rename") {
                                renameText = a.accountName
                                renameIndex = i
                            }.tint(.blue)
                        }
                    }
                    .onMove { session.move(from: $0, to: $1) }
                    Button {
                        showScanner = true
                    } label: {
                        Label("Add a Line (Scan Sign-In Code)", systemImage: "qrcode.viewfinder")
                    }
                }
                Section {
                    Text("Tap a line to make it the outbound line. Swipe left to rename or sign out. Use Edit (top right) to drag lines into your preferred order. Incoming calls ring on every line. Transport is Auto by default — if a network blocks calling traffic, the app finds a path that works (TCP or encrypted TLS) by itself; pick one manually only if support asks you to.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // GPS 1.1: only shown when a line's server actually offers the
                // feature — a PBX without the module keeps this row invisible.
                if locations.offered {
                    Section {
                        Toggle("Share location with Nóvare support", isOn: Binding(
                            get: { locations.sharingOn },
                            set: { on in Task { await locations.setSharing(on) } }))
                        Text("Helps support answer \"is this phone off or just out of range?\" and aids emergency calls. Your location is visible only to Nóvare, kept briefly, and never shared while the app is closed. Turning this off also deletes any stored location history. The iPhone Location permission (Settings → Privacy) must also be on.")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: { Text("Privacy") }
                }
                Section {
                    ShareLink(items: AppLog.shared.shareFiles) {
                        Label("Send Diagnostics to Support", systemImage: "square.and.arrow.up")
                    }
                    Text("After a problem call, tap this and send the file by text message. It contains the app's activity record — exactly what support needs to see what happened.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Diagnostics") }
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About Nováre Telecom", systemImage: "info.circle")
                    }
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .toolbar { if session.accounts.count > 1 { EditButton() } }
            .sheet(isPresented: $showScanner) {
                QRScannerView { payload in
                    showScanner = false
                    Task { await session.signIn(qrPayload: payload) }
                }
            }
            .confirmationDialog("Sign out this line?", isPresented: Binding(
                get: { signOutIndex != nil }, set: { if !$0 { signOutIndex = nil } })) {
                Button("Sign Out", role: .destructive) {
                    if let i = signOutIndex { Task { await session.signOut(at: i) } }
                    signOutIndex = nil
                }
            }
            .alert("Rename Line", isPresented: Binding(
                get: { renameIndex != nil }, set: { if !$0 { renameIndex = nil } })) {
                TextField("Line name", text: $renameText)
                Button("Save") {
                    if let i = renameIndex { session.rename(at: i, to: renameText) }
                    renameIndex = nil
                }
                Button("Cancel", role: .cancel) { renameIndex = nil }
            } message: {
                Text("Shown on the keypad line picker and this list. You can put the line's phone number here too.")
            }
        }
    }
}

// MARK: - About

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image("NovareTelecomLogo")
                        .resizable().scaledToFit()
                        .frame(maxWidth: 240)
                    Text("Nováre Telecom\na division of Novare Digital Corp")
                        .font(.subheadline).bold()
                        .multilineTextAlignment(.center)
                    Text("a telecom infrastructure firm™")
                        .font(.callout).italic()
                    Text("Chattanooga, Tennessee")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            Section {
                Link(destination: URL(string: "https://novaretelecom.com")!) {
                    Label("novaretelecom.com", systemImage: "globe")
                }
                Button {
                    CallManager.shared.startOutgoingCall(to: "4235915000")
                } label: {
                    Label("(423) 591-5000", systemImage: "phone.fill")
                }
            } header: { Text("Contact") }
            Section {
                LabeledContent("App version", value: version)
                Link(destination: URL(string: "https://github.com/novaredigital/novare-softphone")!) {
                    Label("Open source — AGPLv3 · source code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: { Text("This app") }
        }
        .navigationTitle("About")
    }
}

// MARK: - QR scanner (AVFoundation)

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (Data) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((Data) -> Void)?
        private let sessionQueue = DispatchQueue(label: "qr.scan")
        private let capture = AVCaptureSession()

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            capture.addInput(input)
            let output = AVCaptureMetadataOutput()
            capture.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: capture)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            sessionQueue.async { [capture] in capture.startRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let string = obj.stringValue else { return }
            capture.stopRunning()
            onCode?(Data(string.utf8))
        }
    }
}
