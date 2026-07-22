import Foundation
import UserNotifications

/// MISSED-CALL + VOICEMAIL BADGE 1.1 — local notifications and the app-icon
/// badge. Because the PBX push-wakes the app for every incoming call, the app
/// is alive when a call it woke for goes unanswered, so it can post a
/// missed-call notification and badge the icon right then. Voicemail badging is
/// refreshed whenever the Voicemail list loads (foreground). All local — no new
/// server dependency.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    private var missedCount = 0
    private var vmUnread = 0
    private var smsUnread = 0

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

    /// Called when the Voicemail list loads; badge reflects unread messages.
    func setVoicemailUnread(_ count: Int) {
        vmUnread = max(0, count)
        updateBadge()
    }

    /// MESSAGES 1.1: unread inbound texts contribute to the badge too.
    func setSmsUnread(_ count: Int) {
        smsUnread = max(0, count)
        updateBadge()
    }

    /// Clear the missed-call portion when the user has seen Recents / opened the app.
    func clearMissed() {
        missedCount = 0
        updateBadge()
    }

    private func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(missedCount + vmUnread + smsUnread)
    }
}
