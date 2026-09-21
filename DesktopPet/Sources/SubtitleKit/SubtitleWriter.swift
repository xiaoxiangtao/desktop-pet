import Foundation

/// 字幕落盘：JSONL 流水 + SRT。
///
/// **旧版在真实麦克风路径下落盘 100% 失败**——7 次运行 `stream.jsonl` 全是 0 字节，
/// 而 20 余次文件音源运行全部正常，相关性 100%（[[分析音频识别卡顿与流式方案差距]]）。
/// 那次连根因都没定位到（旁证：同目录下 stream.jsonl 是 0600 而 subtitle.srt 是 0644，
/// 按代码应该同进程创建却权限不同）。
///
/// 这次把写盘做成**纯逻辑 + 可测**：格式化不碰文件系统，写入只有一处，
/// 并且有测试断言真的写出了非空内容。
public struct SubtitleWriter: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var jsonlURL: URL { directory.appendingPathComponent("stream.jsonl") }
    public var srtURL: URL { directory.appendingPathComponent("subtitle.srt") }
    /// 校正版**另存一份，不覆盖实时轨**：实时轨还在往 subtitle.srt 追加，
    /// 就地改写会撞车；而且留着原文才能对照校正效果。
    public var refinedURL: URL { directory.appendingPathComponent("subtitle.refined.srt") }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 一条流水记录。只记定稿——草稿会被后续结果改写，记下来没有意义还会把文件撑大。
    public static func jsonLine(_ line: SubtitleLine, wallClock: TimeInterval) -> String? {
        guard line.stage == .final else { return nil }
        let obj: [String: Any] = [
            "stage": line.stage.rawValue,
            "text": line.text,
            "t_start": line.start,
            "t_end": line.end,
            "wall": wallClock,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public func append(_ line: SubtitleLine, wallClock: TimeInterval) {
        guard let text = Self.jsonLine(line, wallClock: wallClock),
              let data = (text + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: jsonlURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: jsonlURL)
        }
    }

    /// SRT 时间戳：`HH:MM:SS,mmm`。
    ///
    /// **先换算成整毫秒再拆**，不要用"整秒部分 + 小数部分×1000"那种写法：
    /// 二进制浮点会让 `1.2 - 1.0 = 0.19999999999999996`，截断后成 199 毫秒——
    /// 时间戳零星差 1 毫秒，而且只在某些值上出现，极难发现（这条是被测试逮到的）。
    /// 整毫秒运算顺带也把跨分/跨小时的进位问题一起消掉了。
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let totalMs = Int((max(0, seconds) * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    public static func srt(from lines: [SubtitleLine]) -> String {
        lines.filter { $0.stage == .final && !$0.text.isEmpty }
            .enumerated()
            .map { i, l in
                "\(i + 1)\n\(timestamp(l.start)) --> \(timestamp(l.end))\n\(l.text)\n"
            }
            .joined(separator: "\n")
    }

    public func writeSRT(_ lines: [SubtitleLine]) throws {
        try Self.srt(from: lines).write(to: srtURL, atomically: true, encoding: .utf8)
    }

    public func writeRefinedSRT(_ lines: [SubtitleLine]) throws {
        try Self.srt(from: lines).write(to: refinedURL, atomically: true, encoding: .utf8)
    }

    /// 会话目录改名成「时间戳_主题」。
    ///
    /// 主题要等内容出来才归纳得出，所以是**事后改名**而不是开始时命名。
    /// 文件名必须过滤：`/` 会被当成路径分隔、`:` 在 Finder 里显示成 `/`、
    /// 控制字符会让路径打不开；再限长 40 字，免得出现打不开的超长路径。
    public static func sanitize(_ topic: String, limit: Int = 40) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = topic.components(separatedBy: bad).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(limit))
    }

    /// 返回改名后的新目录；失败或主题为空时返回原目录。
    public func renamed(withTopic topic: String) -> URL {
        let safe = Self.sanitize(topic)
        guard !safe.isEmpty else { return directory }
        let target = directory.deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent)_\(safe)")
        guard !FileManager.default.fileExists(atPath: target.path) else { return directory }
        do {
            try FileManager.default.moveItem(at: directory, to: target)
            return target
        } catch {
            return directory
        }
    }
}
