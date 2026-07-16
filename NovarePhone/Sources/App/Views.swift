import SwiftUI
import AVFoundation

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

    var body: some View {
        TabView {
            FavoritesView().tabItem { Label("Favorites", systemImage: "star.fill") }
            RecentsView().tabItem { Label("Recents", systemImage: "clock.fill") }
            ContactsView().tabItem { Label("Contacts", systemImage: "person.crop.circle") }
            DialerView().tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
            VoicemailView().tabItem { Label("Voicemail", systemImage: "recordingtape") }
        }
        .fullScreenCover(isPresented: Binding(get: { call.isActive }, set: { if !$0 { } })) {
            InCallView().environmentObject(call)
        }
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
                HStack(spacing: 34) {
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
    @State private var dnd = SipEngine.shared.dndEnabled
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
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.title3)
                }
            }
            .padding(.horizontal)
            Image("NovareTelecomLogo")
                .resizable().scaledToFit()
                .frame(maxWidth: 180)
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
            Spacer()
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
            HStack(spacing: 34) {
                Button {
                    CallManager.shared.startOutgoingCall(to: number)
                    number = ""   // keypad is blank again after the call
                } label: {
                    Image(systemName: "phone.fill").font(.title)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.green)).foregroundStyle(.white)
                }.disabled(number.isEmpty)
                Button { if !number.isEmpty { number.removeLast() } } label: {
                    Image(systemName: "delete.left").font(.title2)
                }.disabled(number.isEmpty)
            }
            Spacer()
        }
        .padding()
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(session)
        }
    }
}

struct RecentsView: View {
    @StateObject private var history = CallHistory.shared

    var body: some View {
        NavigationStack {
            List {
                if history.records.isEmpty {
                    Text("No calls yet.").foregroundStyle(.secondary)
                }
                ForEach(history.records) { r in
                    Button {
                        CallManager.shared.startOutgoingCall(to: r.number)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: r.direction == .incoming
                                  ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill")
                                .foregroundStyle(r.missed ? .red : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.number)
                                    .foregroundStyle(r.missed ? .red : .primary)
                                Text(r.start.formatted(date: .abbreviated, time: .shortened))
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
            }
            .navigationTitle("Recents")
            .toolbar {
                if !history.records.isEmpty {
                    Button("Clear") { history.clear() }
                }
            }
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
}

struct VoicemailView: View {
    @EnvironmentObject var session: SessionStore
    @State private var messages: [VMessage] = []
    @State private var status: String?
    @State private var player: AVPlayer?
    @State private var playingId: Int?

    var body: some View {
        NavigationStack {
            List {
                if let s = status {
                    Text(s).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(messages) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(m.caller_name ?? m.caller_id ?? "Unknown").font(.headline)
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
                }
                Section {
                    Button {
                        SipEngine.shared.dialVoicemail()
                    } label: {
                        Label("Call Voicemail (*97)", systemImage: "recordingtape")
                    }
                }
            }
            .navigationTitle("Voicemail")
            .task { await load() }
            .refreshable { await load() }
        }
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
    }
}

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
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
                    Text("Tap a line to make it the outbound line. Swipe left to rename or sign out. Use Edit (top right) to drag lines into your preferred order. Incoming calls ring on every line.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About Nóvare Telecom", systemImage: "info.circle")
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
                    Text("Nóvare Telecom\na division of Novare Digital Corp")
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
