import Foundation

/// One entry in Recents. Kept on-device only.
struct CallRecord: Codable, Identifiable {
    let id: UUID
    let number: String
    let direction: Direction
    let missed: Bool
    let start: Date
    let duration: Int          // seconds of connected talk time; 0 = never connected

    enum Direction: String, Codable { case incoming, outgoing }
}

/// Local call log feeding the Recents tab. Appended by CallSession when a
/// call ends; capped so it can't grow without bound.
@MainActor
final class CallHistory: ObservableObject {
    static let shared = CallHistory()

    @Published private(set) var records: [CallRecord] = []

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("call-history.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([CallRecord].self, from: data) {
            records = saved
        }
    }

    func add(number: String, direction: CallRecord.Direction, missed: Bool, start: Date, duration: Int) {
        records.insert(CallRecord(id: UUID(), number: number, direction: direction,
                                  missed: missed, start: start, duration: duration), at: 0)
        if records.count > 200 { records.removeLast(records.count - 200) }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL)
        }
        // MISSED-CALL BADGE 1.1: notify + badge on a missed incoming call.
        if missed && direction == .incoming {
            NotificationManager.shared.missedCall(from: number)
        }
    }

    func clear() {
        records = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}
