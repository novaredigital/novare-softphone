import Foundation
import CoreLocation
import UIKit

/// GPS 1.1 — location reporting to Nóvare support (consent-first).
///
/// The SERVER is the source of truth for consent (notice-based with opt-out;
/// opting out wipes that extension's stored history immediately, and the PBX
/// remembers the choice across devices). This class:
///  1. asks each signed-in line's server `GET /user/location/consent`,
///  2. shows the server's notice text ONCE with [OK] / [Opt Out],
///  3. sends `POST /user/location {lat, lon, accuracy_m}` on foreground /
///     registration and as the phone moves — FOREGROUND ONLY in v1: the only
///     iOS permission requested is When-In-Use and there is no location
///     background mode, so nothing is ever reported while the app is closed,
///  4. mirrors the consent state in a Settings toggle.
///
/// Server replies: `{ok:true,throttled:true}` = accepted-but-dropped (the
/// server keeps at most one report/min per extension — never retry);
/// 403 = disabled or opted out → stop sending until a consent GET says
/// otherwise. Servers WITHOUT the endpoint (404 — e.g. a PBX that hasn't
/// shipped the module) leave the feature fully dormant: no notice, no toggle,
/// no reports.
@MainActor
final class LocationReporter: NSObject, ObservableObject {
    static let shared = LocationReporter()

    /// Non-nil = the one-time notice should be on screen now (MainTabView alert).
    @Published var noticeText: String?
    /// Settings toggle state — some line's server has GPS on and the user
    /// hasn't opted out.
    @Published private(set) var sharingOn = false
    /// At least one line's server offers the endpoint (shows the Settings row).
    @Published private(set) var offered = false

    private let manager = CLLocationManager()
    private var eligible: Set<String> = []      // line keys consented per last GET
    private var stopped: Set<String> = []       // 403'd lines — cleared on next GET
    private var lastSend: [String: Date] = [:]  // client-side 1/min politeness per line
    private var monitoring = false

    private let noticeShownKey = "com.novaredigital.novarephone.location.noticeShown"
    private let optedOutKey = "com.novaredigital.novarephone.location.optedOut"

    private override init() {
        super.init()
        manager.delegate = self
        // Support diagnostics need "near which address", not turn-by-turn:
        // block-level accuracy + a 500 m filter = "significant change" while
        // the app is open, at negligible battery cost.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 500
    }

    private struct ConsentReply: Codable { let enabled: Bool; let consented: Bool; let notice: String }

    /// Re-learn consent from every line's server. Runs on foreground and after
    /// a line's /user login lands (so it also covers launch and QR sign-in).
    func refresh() async {
        let session = SessionStore.shared
        var anyOffered = false, anyEnabled = false
        var newEligible: Set<String> = []
        var notice: String?
        for p in session.accounts {
            guard let tok = session.userToken(for: p) else { continue }
            var req = URLRequest(url: p.apiBase.appendingPathComponent("user/location/consent"))
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let r = try? JSONDecoder().decode(ConsentReply.self, from: data) else { continue }
            anyOffered = true
            if r.enabled { anyEnabled = true }
            if r.enabled && r.consented { newEligible.insert(p.key); notice = notice ?? r.notice }
        }
        offered = anyOffered
        eligible = newEligible
        stopped.removeAll()   // a 403 stop holds only until the server says otherwise
        sharingOn = !eligible.isEmpty && !UserDefaults.standard.bool(forKey: optedOutKey)
        // One-time notice: once per install, only when a server actually has
        // the feature on, never again after an opt-out (server remembers too).
        if anyEnabled, let text = notice,
           !UserDefaults.standard.bool(forKey: noticeShownKey),
           !UserDefaults.standard.bool(forKey: optedOutKey) {
            noticeText = text
            AppLog.shared.write("[GPS] showing one-time location notice")
        }
        #if targetEnvironment(simulator)
        // Screenshot/e2e rig ONLY (compiled out of device builds): the
        // simulator has no touch automation, so tests accept the notice by env.
        if noticeText != nil, ProcessInfo.processInfo.environment["NOVARE_SIM_GPS_ACCEPT"] == "1" {
            acceptNotice()
        }
        #endif
        syncMonitoring()
    }

    /// [OK] on the notice — record the explicit opt-in server-side (timestamp +
    /// policy version), then ask iOS for When-In-Use.
    func acceptNotice() {
        UserDefaults.standard.set(true, forKey: noticeShownKey)
        UserDefaults.standard.set(false, forKey: optedOutKey)
        noticeText = nil
        AppLog.shared.write("[GPS] notice accepted")
        requestPermissionIfNeeded()
        Task { await postConsent(granted: true) }
    }

    /// [Opt Out] on the notice — server deletes any stored history and the
    /// notice never shows again.
    func declineNotice() {
        UserDefaults.standard.set(true, forKey: noticeShownKey)
        UserDefaults.standard.set(true, forKey: optedOutKey)
        noticeText = nil
        AppLog.shared.write("[GPS] notice declined — opted out")
        Task { await postConsent(granted: false) }
    }

    /// Settings toggle ("Share location with Nóvare support").
    func setSharing(_ on: Bool) async {
        UserDefaults.standard.set(true, forKey: noticeShownKey)   // the toggle IS the informed choice
        UserDefaults.standard.set(!on, forKey: optedOutKey)
        AppLog.shared.write("[GPS] settings toggle → \(on ? "on" : "off")")
        if on { requestPermissionIfNeeded() }
        await postConsent(granted: on)
    }

    // MARK: - App lifecycle hooks

    func appActive() async { await refresh() }
    func appBackground() { if monitoring { manager.stopUpdatingLocation(); monitoring = false } }
    /// A line's /user login just landed (launch, foreground re-login, QR sign-in).
    func tokensUpdated() { Task { await refresh() } }

    // MARK: - Internals

    private func postConsent(granted: Bool) async {
        struct Body: Codable { let granted: Bool; let version: String }
        let session = SessionStore.shared
        var confirmed: Set<String> = []
        for p in session.accounts {
            guard let tok = session.userToken(for: p) else { continue }
            var req = URLRequest(url: p.apiBase.appendingPathComponent("user/location/consent"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONEncoder().encode(Body(granted: granted, version: "v1"))
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200, granted {
                confirmed.insert(p.key)
            }
        }
        if granted { eligible.formUnion(confirmed) } else { eligible.removeAll() }
        stopped.removeAll()
        sharingOn = granted && !eligible.isEmpty
        syncMonitoring()
    }

    private var permitted: Bool {
        manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
    }

    private func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// One monitoring path: while the app is frontmost and sharing is on,
    /// continuous coarse updates run; the first fix after foregrounding IS the
    /// "on foreground/registration" report, and the 500 m filter delivers the
    /// significant-change ones. Everything stops on background.
    private func syncMonitoring() {
        let want = sharingOn && !eligible.isEmpty && permitted
            && UIApplication.shared.applicationState != .background
        if want && !monitoring { manager.startUpdatingLocation(); monitoring = true }
        if !want && monitoring { manager.stopUpdatingLocation(); monitoring = false }
    }

    private func send(_ loc: CLLocation) {
        let session = SessionStore.shared
        for p in session.accounts where eligible.contains(p.key) && !stopped.contains(p.key) {
            if let last = lastSend[p.key], Date().timeIntervalSince(last) < 60 { continue }
            guard let tok = session.userToken(for: p) else { continue }
            lastSend[p.key] = Date()
            struct Body: Codable { let lat: Double; let lon: Double; let accuracy_m: Double }
            var req = URLRequest(url: p.apiBase.appendingPathComponent("user/location"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONEncoder().encode(Body(lat: loc.coordinate.latitude,
                                                          lon: loc.coordinate.longitude,
                                                          accuracy_m: max(0, loc.horizontalAccuracy)))
            let key = p.key
            Task {
                guard let (_, resp) = try? await URLSession.shared.data(for: req),
                      let code = (resp as? HTTPURLResponse)?.statusCode else { return }
                if code == 200 {
                    AppLog.shared.write("[GPS] report sent (\(key))")
                } else if code == 403 {
                    // Disabled or opted out server-side (e.g. from the office
                    // portal) — stop until a consent GET re-opens it.
                    self.stopped.insert(key)
                    AppLog.shared.write("[GPS] server refused (403) — stopping reports (\(key))")
                }
            }
        }
    }
}

extension LocationReporter: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async { self.send(loc) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient fix failures are normal indoors; the next update wins.
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Covers the user answering the When-In-Use prompt either way.
        DispatchQueue.main.async { self.syncMonitoring() }
    }
}
