import Testing
import Foundation
@testable import PetCore
@testable import Providers

/// 用假的 hermes 脚本跑完整逻辑：不需要 Hermes 订阅、不烧真实 token，
/// 而且能构造出真实环境里很难复现的分支（超时不退出、stdout 被污染、命名失败）。
/// 方案 §5.3 要求的就是这套。
private func fixturePath() -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fake-hermes").path
}

/// mode 走 `ProcessSpec.env` **显式传给子进程**，不用 `setenv`——
/// Swift Testing 默认并行跑，进程级全局环境变量会让各用例互相污染
/// （第一版就是这么挂的：期待"空回复"的用例拿到了别的用例设的 ok 模式）。
private func provider(mode: String, timeout: TimeInterval = 10,
                      extraEnv: [String: String] = [:]) -> HermesCLIProvider {
    var cfg = HermesConfig(binary: fixturePath(), timeout: timeout)
    cfg.workspace = URL(fileURLWithPath: NSTemporaryDirectory())
    cfg.env = ["FAKE_HERMES_MODE": mode].merging(extraEnv) { _, new in new }
    return HermesCLIProvider(config: cfg)
}

@Test func 会话名从history_uid派生且两边1比1() {
    let p = provider(mode: "ok")
    // 2026-09-06_01-36-25_5d859dc3d751... → desktop-pet-2026-09-06_01-36-25_5d859dc3
    #expect(p.sessionName(forHistory: "2026-09-06_01-36-25_5d859dc3d751aaaa")
            == "desktop-pet-2026-09-06_01-36-25_5d859dc3")
    // 空 uid 退回前缀
    #expect(p.sessionName(forHistory: "") == "desktop-pet")
}

@Test func 关掉每对话独立会话时所有轮次钉在前缀上() {
    var cfg = HermesConfig(binary: fixturePath())
    cfg.sessionPerConversation = false
    let p = HermesCLIProvider(config: cfg)
    #expect(p.sessionName(forHistory: "2026-09-06_01-36-25_abcdef12") == "desktop-pet")
}

@Test func 正常回合拿到回复() async throws {
    let reply = try await provider(mode: "ok").ask("你好", session: "desktop-pet-test")
    #expect(reply == "喵，我在。")
}

@Test func session_id跑到stdout上也必须从回复里剥掉() async throws {
    // 真实 hermes 打在 stderr，但代码两边都剥——万一将来版本挪了这行，
    // 不能让一个 id 漏进聊天气泡。
    let reply = try await provider(mode: "stdout-pollution").ask("hi", session: "s")
    #expect(reply == "真正的回复。")
    #expect(!reply.contains("session_id"))
}

@Test func 会话不存在时走两步创建而不是create_if_missing() async throws {
    // `--continue <name> --create-if-missing` 会建出一条**没有 cwd** 的会话行，
    // 而桌面端按 cwd 匹配项目分组，于是对话散落在未归类列表里。
    // 所以必须：普通运行建会话（cwd 被记录）→ 从 stderr 取 id → rename。
    let log = NSTemporaryDirectory() + "rename-\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: log) }

    let reply = try await provider(mode: "rename-check",
                                   extraEnv: ["FAKE_HERMES_RENAME_LOG": log])
        .ask("hi", session: "desktop-pet-新的")
    #expect(reply == "建好了。")

    let recorded = (try? String(contentsOfFile: log, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(recorded == "sess-new999 desktop-pet-新的", "rename 应拿新会话 id 和目标名字调用，实际 \(recorded ?? "(没调用)")")
}

@Test func 找不到会话的判定不能只看退出码() async throws {
    // fail 模式同样是 exit 1，但 stderr 里没有那句固定措辞，
    // 必须报错而不是误判成"会话不存在"去建新会话。
    await #expect(throws: HermesError.failed) {
        try await provider(mode: "fail").ask("hi", session: "s")
    }
}

@Test func 空回复要报错而不是显示空气泡() async throws {
    await #expect(throws: HermesError.emptyReply) {
        try await provider(mode: "empty").ask("hi", session: "s")
    }
}

@Test func 超时会报错且不会永远挂着() async throws {
    let start = Date()
    await #expect(throws: HermesError.timedOut) {
        try await provider(mode: "hang", timeout: 1.0).ask("hi", session: "s")
    }
    #expect(Date().timeIntervalSince(start) < 8, "超时后应当立刻返回，不能干等")
}

@Test func 取消对话必须真正杀掉子进程() async throws {
    // 旧实现把 subprocess.run 塞在 to_thread 里，取消等待的 task 之后子进程照跑完：
    // token 照烧、答案却被丢弃。这条守住"取消 = 进程死"。
    let p = provider(mode: "hang", timeout: 60)
    let task = Task { try await p.ask("hi", session: "s") }
    try await Task.sleep(nanoseconds: 400_000_000)

    let before = runningFakeHermesCount()
    #expect(before > 0, "假 hermes 应该正在跑")

    task.cancel()
    _ = try? await task.value
    try await Task.sleep(nanoseconds: 800_000_000)

    #expect(runningFakeHermesCount() < before, "取消后子进程应当被杀掉，仍有 \(runningFakeHermesCount()) 个在跑")
}

private func runningFakeHermesCount() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "pgrep -f 'fake-hermes' | wc -l"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let s = String(decoding: (try? pipe.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}
