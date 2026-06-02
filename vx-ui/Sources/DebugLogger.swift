import Foundation

final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    @Published private(set) var entries: [LogEntry] = []
    private let maxEntries = 1000

    // File logging — always enabled so crashes leave a trail.
    let logFileURL: URL
    private var fileHandle: FileHandle?
    private let fileLock = NSLock()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        logFileURL = logsDir.appendingPathComponent("vx-debug.log")

        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()

        let banner = "\n=== vx launched \(ISO8601DateFormatter().string(from: Date())) ===\n"
        if let data = banner.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    func log(_ message: String) {
        NSLog("%@", message)

        let entry = LogEntry(timestamp: Date(), message: message)
        writeToFile(entry)

        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    // Synchronous — called from any thread, survives crashes.
    private func writeToFile(_ entry: LogEntry) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let line = "\(dateFormatter.string(from: entry.timestamp)) \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }
}

func vxLog(_ message: String) {
    DebugLogger.shared.log(message)
}
