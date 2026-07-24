import Foundation
import UserNotifications
import SwiftUI

/// BADGES 1.1 — local notifications + the app-icon badge, AND live in-app counts
/// so the ambiguous "N" on the app icon has matching badges on the Voicemail and
/// Messages buttons (so you know what to tap). Counts refresh on foreground.
@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    private init() {}

    @Published private(set) var missedCount = 0
    @Published private(set) var vmUnread = 0
    @Published private(set) var smsUnread = 0

    /// Ask once (at launch). Local notifications need the user's OK; a decline
    /// just means no banners/badge — calls still work.
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// A call we were alerting went unanswered. Post a banner + bump the badge.
    func missedCall(from number: String) {
        missedCount += 1
        let content = UNMutableNotificationContent()
        content.title = "Missed call"
        content.body = number.isEmpty ? "Missed call" : "Missed call from \(number)"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "missed-\(UUID().uuidString)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        updateBadge()
    }

    func setVoicemailUnread(_ count: Int) { vmUnread = max(0, count); updateBadge() }
    func setSmsUnread(_ count: Int)       { smsUnread = max(0, count); updateBadge() }

    /// Opening the app = missed calls have been seen.
    func clearMissed() { missedCount = 0; updateBadge() }

    private func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(missedCount + vmUnread + smsUnread)
    }

    /// BADGES — pull the real unread counts from the server on foreground so the
    /// Recents (voicemail) tab and Messages button show a number BEFORE you open
    /// them.
    ///
    /// UNDERCOUNT FIX (Mark 2026-07-24): this used to query only the PRIMARY
    /// line, so a badge could read "1" while another line held 9 unread. It now
    /// sums unread voicemail + inbound texts across EVERY signed-in line.
    func refreshServerCounts() async {
        let accounts = SessionStore.shared.accounts
        var vmTotal = 0, smsTotal = 0
        for p in accounts {
            guard let tok = SessionStore.shared.userToken(for: p) else { continue }

            // Voicemail unread on this line
            var vm = URLRequest(url: p.apiBase.appendingPathComponent("user/voicemail"))
            vm.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            if let (data, resp) = try? await URLSession.shared.data(for: vm),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                struct VM: Codable { struct M: Codable { let read: Int? }; let messages: [M] }
                if let r = try? JSONDecoder().decode(VM.self, from: data) {
                    vmTotal += r.messages.filter { ($0.read ?? 1) == 0 }.count
                }
            }

            // Inbound texts not yet read on this line
            var sms = URLRequest(url: p.apiBase.appendingPathComponent("user/sms"))
            sms.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            if let (data, resp) = try? await URLSession.shared.data(for: sms),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                struct SM: Codable { struct M: Codable { let direction: String; let read: Int? }; let messages: [M] }
                if let r = try? JSONDecoder().decode(SM.self, from: data) {
                    smsTotal += r.messages.filter { $0.direction == "inbound" && ($0.read ?? 1) == 0 }.count
                }
            }
        }
        setVoicemailUnread(vmTotal)
        setSmsUnread(smsTotal)
    }
}

/// Small red count badge for the header buttons.
extension View {
    func countBadge(_ n: Int) -> some View {
        overlay(alignment: .topTrailing) {
            if n > 0 {
                Text("\(min(n, 99))")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.red))
                    .offset(x: 8, y: -8)
            }
        }
    }
}
