import Foundation

/// Appends to ~/Library/Logs/Lidfold.log as well as the system log, so a
/// stuck effect can be diagnosed after the fact.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Lidfold.log")
    private static let queue = DispatchQueue(label: "lidfold.log")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    static func write(_ message: String) {
        NSLog("Lidfold: %@", message)
        let now = Date()
        queue.async {
            // DateFormatter is not thread-safe; it only runs on this queue.
            let line = "\(stamp.string(from: now)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
