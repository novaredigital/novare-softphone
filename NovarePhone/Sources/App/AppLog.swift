import Foundation
import UIKit

/// On-device diagnostic log. Every app + SIP event lands in a rotating text
/// file in Documents so a user can send support exactly what their phone saw
/// (Settings → Send Diagnostics). Ends the "can't see the phone's side"
/// guessing that server logs alone can't solve.
final class AppLog {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "com.novaredigital.novarephone.applog")
    private let maxBytes: UInt64 = 2_000_000   // ~2 MB, then rotate once
    let fileURL: URL
    let previousURL: URL
    private var handle: FileHandle?
    private let stamp: DateFormatter

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("novare-diagnostics.log")
        previousURL = dir.appendingPathComponent("novare-diagnostics-previous.log")
        stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        openHandle()
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        write("=== launch · Nováre Phone \(v) (\(b)) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model) ===")
    }

    /// Files that exist right now — what the Settings share sheet sends.
    var shareFiles: [URL] {
        [fileURL, previousURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func write(_ line: String) {
        #if DEBUG
        print(line)
        #endif
        queue.async { [self] in
            rotateIfNeeded()
            let text = "[\(stamp.string(from: Date()))] \(line)\n"
            if let data = text.data(using: .utf8) { handle?.write(data) }
        }
    }

    // MARK: - File plumbing (all on `queue`)

    private func openHandle() {
        queue.async { [self] in
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? handle?.seekToEnd()
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
              size > maxBytes else { return }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }
}
