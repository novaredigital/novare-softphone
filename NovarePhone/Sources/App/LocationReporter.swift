import Foundation
import CoreLocation
import UIKit

/// GPS 1.2 — location reporting to Nóvare support (consent-first).
///
/// The SERVER is the source of truth for consent (notice-based with opt-out;
/// opting out wipes that extension's stored history immediately, and the PBX
/// remembers the choice across devices). This class:
///  1. asks each signed-in line's server `GET /user/location/consent`,
///  2. when the server says enabled+consented, asks iOS for permission — the OS
///     prompt IS the user-facing notice (its purpose text mirrors the server's;
///     Mark removed the extra in-app alert 2026-07-22),
///  3. sends `POST /user/location {lat, lon, accuracy_m}`,
///  4. mirrors the consent state in a Settings toggle.
///
/// ── 2026-07-23: BACKGROUND CAPABILITY + SERVER-DRIVEN POLICY (Mark) ──────────
/// v1 was foreground-only, which meant a phone in a pocket reported nothing —
/// proven in the field 2026-07-23 (Erik's line logged fixes only in the minutes
/// around a call he *placed*, because dialling out is what brought the app
/// forward; an incoming call never does).
///
/// iOS gives no way to "just keep running": a backgrounded app is suspended
/// unless it declares a background mode, and — the part that actually bites —
/// With "When In Use" permission iOS refuses to hand over a location while
/// backgrounded even during a VoIP wake. So the fix is BOTH the `location`
/// background mode AND `Always` authorization.
///
/// The capability ships once; HOW MUCH it reports is the server's call
/// (`mode` on the consent reply), so the behaviour can be retuned from a
/// settings row without another App Store review:
///   • `.foreground` — v1 behaviour, only while the app is on screen (default,
///                     and what every pre-2026-07-23 server implies)
///   • `.emergency`  — background-capable but SILENT: significant-change is
///                     armed only so iOS keeps the app alive/relaunchable, and
///                     a fix is sent when an admin triggers a locate. Lowest
///                     battery, gentlest privacy story. Mark's preferred default.
///   • `.continuous` — background breadcrumbs as the phone moves.
///
/// Server replies: `{ok:true,throttled:true}` = accepted-but-dropped (the
/// server keeps at most one report/min per extension — never retry);
/// 403 = disabled or opted out → stop sending until a consent GET says
/// otherwise. Servers WITHOUT the endpoint (404) leave the feature fully
/// dormant: no prompt, no toggle, no reports.
@MainActor
final class LocationReporter: NSObject, ObservableObject {
    static let shared = LocationReporter()

    /// Non-nil = the one-time notice should be on screen (MainTabView alert).
    /// Shown ONLY when the server says consent is merely PRESUMED
    /// (explicit:false) — Nóvare-owned phones have recorded owner consent and
    /// never see it; future/customer phones do (Mark 2026-07-22).
    @Published var noticeText: String?
    /// Settings toggle state — some line's server has GPS on and the user
    /// hasn't opted out.
    @Published private(set) var sharingOn = false
    /// At least one line's server offers the endpoint (shows the Settings row).
    @Published private(set) var offered = false

    /// Reporting policy handed down by the server (see the class note).
    enum Mode: String { case foreground, emergency, continuous }
    @Published private(set) var mode: Mode = .foreground

    private let manager = CLLocationManager()
    private var eligible: Set<String> = []      // line keys consented per last GET
    private var stopped: Set<String> = []       // 403'd lines — cleared on next GET
    private var lastSend: [String: Date] = [:]  // client-side 1/min politeness per server
    private var monitoring = false
    private var sigMonitoring = false           // significant-change (background) armed
    private var lastLocation: CLLocation?       // most recent fix, for the heartbeat
    private var heartbeat: Timer?               // periodic re-report while foregrounded

    /// GPS 1.1 heartbeat (Mark 2026-07-22): without this the app only reports on
    /// a ~500 m move, so a stationary phone updates the location log exactly once
    /// (when foregrounded) and then looks frozen. This timer re-sends the last
    /// known fix on a fixed cadence WHILE THE APP IS OPEN. 65 s clears the
    /// server's 60 s throttle so each tick is accepted rather than dropped.
    private let heartbeatInterval: TimeInterval = 65

    private let noticeShownKey = "com.novaredigital.novarephone.location.noticeShown"
    private let optedOutKey = "com.novaredigital.novarephone.location.optedOut"

    /// True when the current policy needs the app to work while backgrounded.
    private var wantsBackground: Bool { mode == .emergency || mode == .continuous }

    private override init() {
        super.init()
        manager.delegate = self
        // Support diagnostics need "near which address", not turn-by-turn:
        // block-level accuracy + a 500 m filter = "significant change" while
        // the app is open, at negligible battery cost.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 500
    }

    private struct ConsentReply: Codable {
        let enabled: Bool; let consented: Bool; let notice: String
        let explicit: Bool?   // absent on pre-v2 servers → treat as recorded (no alert)
        let mode: String?     // absent on pre-2026-07-23 servers → .foreground
    }

    /// Re-learn consent from every line's server. Runs on foreground and after
    /// a line's /user login lands (so it also covers launch and QR sign-in).
    func refresh() async {
        let session = SessionStore.shared
        var anyOffered = false
        var needsNotice: String?   // notice text when some line's consent is only presumed
        var newEligible: Set<String> = []
        var strongestMode: Mode = .foreground
        for p in session.accounts {
            guard let tok = session.userToken(for: p) else { continue }
            var req = URLRequest(url: p.apiBase.appendingPathComponent("user/location/consent"))
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let r = try? JSONDecoder().decode(ConsentReply.self, from: data) else { continue }
            anyOffered = true
            if r.enabled && r.consented {
                newEligible.insert(p.key)
                if !(r.explicit ?? true) && needsNotice == nil { needsNotice = r.notice }
                // Most permissive wins when lines disagree: a phone can only have
                // one iOS permission level, so the strongest requirement governs.
                if let m = r.mode.flatMap(Mode.init(rawValue:)) {
                    if m == .continuous { strongestMode = .continuous }
                    else if m == .emergency && strongestMode != .continuous { strongestMode = .emergency }
                }
            }
        }
        offered = anyOffered
        eligible = newEligible
        mode = newEligible.isEmpty ? .foreground : strongestMode
        stopped.removeAll()   // a 403 stop holds only until the server says otherwise
        sharingOn = !eligible.isEmpty && !UserDefaults.standard.bool(forKey: optedOutKey)
        // Notice policy (Mark 2026-07-22): phones with RECORDED consent go
        // straight to the iOS prompt — no extra alert. Only presumed-consent
        // lines get the one-time [OK]/[Opt Out] alert, and [OK] records their
        // consent so it never shows again.
        if let text = needsNotice,
           !UserDefaults.standard.bool(forKey: noticeShownKey),
           !UserDefaults.standard.bool(forKey: optedOutKey) {
            noticeText = text
            AppLog.shared.write("[GPS] showing one-time location notice (consent not yet recorded)")
        } else if sharingOn {
            requestPermissionIfNeeded()
        }
        #if targetEnvironment(simulator)
        // e2e rig ONLY (compiled out of device builds): no touch automation
        // in the simulator, so tests accept the notice by env var.
        if noticeText != nil, ProcessInfo.processInfo.environment["NOVARE_SIM_GPS_ACCEPT"] == "1" {
            acceptNotice()
        }
        #endif
        syncMonitoring()
    }

    /// [OK] on the notice — record consent server-side (it becomes explicit,
    /// so the alert never returns), then ask iOS for permission.
    func acceptNotice() {
        UserDefaults.standard.set(true, forKey: noticeShownKey)
        UserDefaults.standard.set(false, forKey: optedOutKey)
        noticeText = nil
        AppLog.shared.write("[GPS] notice accepted")
        requestPermissionIfNeeded()
        Task { await postConsent(granted: true) }
    }

    /// [Opt Out] on the notice — server wipes any stored history and the
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

    /// Going to the background. Under `.foreground` policy everything stops (v1
    /// behaviour). Under a background policy the continuous updates stop but
    /// significant-change stays armed — that is what lets iOS relaunch the app
    /// after it is killed or the phone reboots.
    func appBackground() {
        if monitoring { manager.stopUpdatingLocation(); monitoring = false; stopHeartbeat() }
        syncMonitoring()
    }

    /// A line's /user login just landed (launch, foreground re-login, QR sign-in).
    func tokensUpdated() { Task { await refresh() } }

    /// EMERGENCY LOCATE (Mark 2026-07-23) — called when the PBX pushes a locate
    /// request. Grabs whatever fix is available and reports it once, regardless
    /// of policy, so `.emergency` phones stay silent until they are actually
    /// needed. Safe to call from a background push wake.
    func performEmergencyLocate() {
        AppLog.shared.write("[GPS] emergency locate requested")
        guard permitted, !eligible.isEmpty else {
            AppLog.shared.write("[GPS] emergency locate skipped — no permission/consent")
            return
        }
        // requestLocation() delivers one fix then stops — the cheapest way to
        // answer a locate without arming continuous updates.
        manager.requestLocation()
        if let loc = lastLocation ?? manager.location { send(loc, force: true) }
    }

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

    /// Ask for the level the current policy needs. Background policies require
    /// `Always`; iOS only allows escalating to it AFTER When-In-Use has been
    /// granted, so this walks the two-step path Apple mandates.
    private func requestPermissionIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse where wantsBackground:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// One monitoring path, driven by policy.
    ///  • foreground-visible + sharing on  → continuous updates + heartbeat
    ///  • background policy                → significant-change stays armed so the
    ///    OS wakes/relaunches us on real movement (this is what survives the app
    ///    being killed); `.continuous` also reports each of those wakes.
    private func syncMonitoring() {
        let base = sharingOn && !eligible.isEmpty && permitted
        let visible = UIApplication.shared.applicationState != .background

        // Background updates are only legal once Always is granted; setting this
        // without the background mode + Always would crash/no-op, so gate it.
        let canBackground = base && wantsBackground && manager.authorizationStatus == .authorizedAlways
        manager.allowsBackgroundLocationUpdates = canBackground
        manager.pausesLocationUpdatesAutomatically = !canBackground

        let want = base && visible
        if want && !monitoring {
            manager.startUpdatingLocation()
            monitoring = true
            startHeartbeat()
        }
        if !want && monitoring {
            manager.stopUpdatingLocation()
            monitoring = false
            stopHeartbeat()
        }

        // Significant-change: the always-on, low-power baseline. Cheap enough to
        // leave armed permanently under a background policy.
        if canBackground && !sigMonitoring {
            manager.startMonitoringSignificantLocationChanges()
            sigMonitoring = true
            AppLog.shared.write("[GPS] significant-change monitoring ARMED (mode=\(mode.rawValue))")
        }
        if !canBackground && sigMonitoring {
            manager.stopMonitoringSignificantLocationChanges()
            sigMonitoring = false
            AppLog.shared.write("[GPS] significant-change monitoring stopped")
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let t = Timer(timeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.monitoring,
                      let loc = self.lastLocation ?? self.manager.location else { return }
                self.send(loc)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    private func stopHeartbeat() { heartbeat?.invalidate(); heartbeat = nil }

    /// Report a fix — ONCE PER SERVER, not once per line (Mark 2026-07-23:
    /// "only one line or the phone needs to be tracked, all lines are connected
    /// to the one app"). Before this, one phone running 16 lines filed 16
    /// identical rows per heartbeat and stacked 16 pins on the map. Lines are
    /// grouped by their server so a phone signed into two different PBXs still
    /// reports to each, but each server hears from the device exactly once.
    private func send(_ loc: CLLocation, force: Bool = false) {
        let session = SessionStore.shared
        var seenServers: Set<String> = []
        for p in session.accounts where eligible.contains(p.key) && !stopped.contains(p.key) {
            let serverKey = p.apiBase.absoluteString
            guard seenServers.insert(serverKey).inserted else { continue }   // one line per server
            if !force, let last = lastSend[serverKey], Date().timeIntervalSince(last) < 60 { continue }
            guard let tok = session.userToken(for: p) else { continue }
            lastSend[serverKey] = Date()
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
        DispatchQueue.main.async {
            self.lastLocation = loc
            // Under `.emergency` the app stays silent in the background — the
            // significant-change wake exists only to keep it alive for a locate.
            if self.mode == .emergency,
               UIApplication.shared.applicationState == .background { return }
            self.send(loc)
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient fix failures are normal indoors; the next update wins.
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Covers the user answering the prompt (either level) either way.
        DispatchQueue.main.async {
            self.requestPermissionIfNeeded()   // escalate WhenInUse → Always if policy needs it
            self.syncMonitoring()
        }
    }
}
