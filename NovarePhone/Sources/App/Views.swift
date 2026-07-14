import SwiftUI
import AVFoundation

// MARK: - Sign-in (QR scan; the ONLY way the app learns about a server)

struct SignInView: View {
    @EnvironmentObject var session: SessionStore
    @State private var showScanner = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "phone.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(Color(red: 0.784, green: 0.063, blue: 0.18)) // Nováre red
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
    var body: some View {
        TabView {
            DialerView().tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
            RecentsView().tabItem { Label("Recents", systemImage: "clock.fill") }
            VoicemailView().tabItem { Label("Voicemail", systemImage: "recordingtape") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

struct DialerView: View {
    @State private var number = ""
    private let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(number.isEmpty ? " " : number)
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                ForEach(keys, id: \.self) { k in
                    Button { number.append(k) } label: {
                        Text(k).font(.title).frame(width: 72, height: 72)
                            .background(Circle().fill(Color(.secondarySystemBackground)))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 40) {
                Button {
                    CallManager.shared.startOutgoingCall(to: number)
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
        }.padding()
    }
}

struct RecentsView: View {
    var body: some View {
        NavigationStack { List { Text("Call history appears here.") }.navigationTitle("Recents") }
    }
}

struct VoicemailView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Button {
                    SipEngine.shared.dialVoicemail()
                } label: {
                    Label("Call Voicemail (*97)", systemImage: "recordingtape")
                        .font(.headline).frame(maxWidth: .infinity).padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 32)
                Spacer()
            }
            .navigationTitle("Voicemail")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore

    var body: some View {
        NavigationStack {
            List {
                if let p = session.provisioning {
                    Section("Account") {
                        LabeledContent("Name", value: p.accountName)
                        LabeledContent("Extension", value: p.username)
                    }
                }
                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { await session.signOut() }
                    }
                }
                Section {
                    Text("Nováre Telecom, a division of Novare Digital Corp")
                    Link("novaretelecom.com", destination: URL(string: "https://novaretelecom.com")!)
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
        }
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
