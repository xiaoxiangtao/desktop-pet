import Foundation
import OSLog

/// 日志。按 CLAUDE.md 的约定同时落文件（`log/` 下，与脚本同名），
/// 因为桌宠是双击启动的，没有终端可看——旧版 Electron 也是为此专门加了 logger.ts，
/// 那是排查"启动就白屏"这类问题的唯一线索。
public enum Log {
    private static let logger = Logger(subsystem: Paths.bundleID, category: "pet")
    private static let fileQueue = DispatchQueue(label: "pet.log")

    private static let fileURL: URL? = {
        let dir = Paths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("desktop-pet.log")
    }()

    public static func info(_ message: String) { write("INFO", message); logger.info("\(message)") }
    public static func warn(_ message: String) { write("WARN", message); logger.warning("\(message)") }
    public static func error(_ message: String) { write("ERROR", message); logger.error("\(message)") }

    private static func write(_ level: String, _ message: String) {
        guard let url = fileURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(level.padding(toLength: 5, withPad: " ", startingAt: 0)) \(message)\n"
        fileQueue.async {
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
