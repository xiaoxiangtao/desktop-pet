import Testing
import Foundation
@testable import SubtitleKit

// 字幕会话目录的命名。

/// 主题落文件名前必须清洗：`/` 会被当路径分隔、`:` 在 Finder 里显示成 `/`、
/// 控制字符让路径打不开。这类问题只有在真出现时才发现，所以要测。
@Test func 主题落文件名前要清洗() {
    #expect(SubtitleWriter.sanitize("深度学习/反向传播") == "深度学习 反向传播")
    #expect(SubtitleWriter.sanitize("Lecture 3: 数据可视化") == "Lecture 3 数据可视化")
    #expect(SubtitleWriter.sanitize("  多余   空格  ") == "多余 空格")
    #expect(SubtitleWriter.sanitize("换\n行").contains("\n") == false)
    #expect(SubtitleWriter.sanitize(String(repeating: "长", count: 100)).count == 40, "要限长")
    #expect(SubtitleWriter.sanitize("///").isEmpty, "全是非法字符时应为空，调用方据此放弃改名")
}

@Test func 目录改名成时间戳加主题() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("refine-\(UUID().uuidString)")
    let session = root.appendingPathComponent("2026-09-14_21-00-00")
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: session.appendingPathComponent("subtitle.srt"))

    let moved = SubtitleWriter(directory: session).renamed(withTopic: "交叉熵与反向传播")
    #expect(moved.lastPathComponent == "2026-09-14_21-00-00_交叉熵与反向传播")
    #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("subtitle.srt").path),
            "改名要把里面的文件一起带过去")
}

@Test func 主题为空时不改名() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("refine-\(UUID().uuidString)")
    let session = root.appendingPathComponent("2026-09-14_22-00-00")
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(SubtitleWriter(directory: session).renamed(withTopic: "//") == session)
}
