import Foundation
import PetCore

/// 跟用户自己的 Hermes Agent CLI 对话。
///
/// 这是一次**没有伪装的真实对话**：不加 persona 提示词、不重建消息历史。只发最新那条
/// 用户消息，对话本身由 Hermes 自己的命名会话（`--continue <name>`）在它那边承载。
///
/// **可选后端**：只有本机装了 Hermes Agent CLI 的人才用得上。绝大多数人应该用
/// `OpenAIProvider`——它不需要机器上预先存在任何东西。
///
/// 下面每一段注释都对应一个真实踩过的坑，删掉任何一条都可能让一个已修的 bug 复活。
public struct HermesConfig: Sendable {
    public var binary: String
    public var sessionPrefix: String
    public var sessionPerConversation: Bool
    public var timeout: TimeInterval
    /// Hermes CLI 默认加载 22 个工具集（约 26 个工具），光工具定义就占满上下文：
    /// 实测一个正文仅 233 字符的会话累计烧掉 112,853 input tokens、单次回复约 30 秒。
    /// 只留 memory 后降到约 7 秒。代价是桌宠不能上网/跑终端/读写文件。空串 = 全开。
    public var toolsets: String
    /// 空串 = 沿用 Hermes 自己的 model.default（gpt-5.6-terra，重推理档）。
    /// 桌宠对话短、口语化、对延迟敏感，用不上那个推理深度。
    /// 实测同一问题：terra medium 8.4s ┆ luna medium 6.8s ┆ **luna low 5.4s**。
    public var model: String
    public var reasoning: String
    /// hermes 子进程的工作目录，决定对话归属哪个 Hermes 项目——桌面端按会话行上记录的
    /// cwd 去匹配项目文件夹，最长路径优先。**只在"创建会话的那一轮"起作用**，见 `run`。
    public var workspace: URL
    /// 传给 hermes 子进程的额外环境变量（测试用假二进制时靠它选 fixture）。
    public var env: [String: String] = [:]

    public init(binary: String = NSString(string: "~/.local/bin/hermes").expandingTildeInPath,
                sessionPrefix: String = "desktop-pet",
                sessionPerConversation: Bool = true,
                timeout: TimeInterval = 120,
                toolsets: String = "memory",
                model: String = "gpt-5.6-luna",
                reasoning: String = "low",
                workspace: URL? = nil) {
        self.binary = binary
        self.sessionPrefix = sessionPrefix
        self.sessionPerConversation = sessionPerConversation
        self.timeout = timeout
        self.toolsets = toolsets
        self.model = model
        self.reasoning = reasoning
        self.workspace = workspace ?? Paths.developmentRoot ?? Paths.applicationSupport
    }
}

public enum HermesError: LocalizedError, Equatable {
    /// 每一条都直接显示在气泡里，所以必须是给人看的话，不带栈、不带 key。
    case launchFailed
    case timedOut
    case failed
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .launchFailed: return "启动 Hermes 失败，请检查 hermes 是否已安装。"
        case .timedOut:     return "Hermes 响应超时了，请稍后再试。"
        case .failed:       return "Hermes 那边暂时没法回复，请稍后再试。"
        case .emptyReply:   return "Hermes 没有返回内容。"
        }
    }
}

public actor HermesCLIProvider: ChatProvider {
    public nonisolated let id = "hermes_cli"
    public nonisolated let displayName = "Hermes CLI"

    private let config: HermesConfig
    private let runner: ProcessRunning
    /// 当前在跑的那个子进程，取消时要能杀掉它。
    private var running: RunningProcess?

    /// `hermes chat --oneshot` 会报告它用了哪个会话，格式是 `session_id: <id>`——
    /// 这一行打在 **stderr** 上，不是 stdout，所以带 `-Q` 时 stdout 就是纯回复。
    /// stdout 也照样剥一遍：不花钱，且万一将来版本挪了这行，也不会有个 id 漏进气泡。
    private static let sessionIDPattern = try! NSRegularExpression(
        pattern: "^session_id:\\s*(\\S+)\\s*\\n?", options: [.anchorsMatchLines])

    /// `--continue <name>` 找不到同名会话时 stderr 上的原话。
    /// **不能只看退出码**：其它失败也是 exit 1。
    private static let noSuchSession = "No session found matching"

    private static let terminateGrace: TimeInterval = 3.0

    public init(config: HermesConfig = HermesConfig(), runner: ProcessRunning = SystemProcessRunner()) {
        self.config = config
        self.runner = runner
    }

    /// 某个本地对话对应哪个 Hermes 会话。
    ///
    /// 从 history uid 派生，两边就是 1:1 的：打开一段旧对话、或断线重连之后，
    /// 都会落回同一个 Hermes 会话，不用在任何地方记录这个配对关系。
    public nonisolated func sessionName(forHistory uid: String) -> String {
        guard config.sessionPerConversation, !uid.isEmpty else { return config.sessionPrefix }
        // 2026-09-06_01-36-25_5d859dc3d751… → desktop-pet-2026-09-06_01-36-25_5d859dc3
        let parts = uid.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return "\(config.sessionPrefix)-\(uid)" }
        let short = parts[0...1].joined(separator: "_") + "_" + parts[2].prefix(8)
        return "\(config.sessionPrefix)-\(short)"
    }

    public func probe() async -> ProviderHealth {
        FileManager.default.isExecutableFile(atPath: config.binary)
            ? .ready : .unavailable("找不到可执行的 hermes：\(config.binary)")
    }

    public nonisolated func respond(to turn: ChatTurn) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = sessionName(forHistory: turn.historyUID ?? "")
                    let reply = try await ask(turn.text, session: session)
                    continuation.yield(.message(reply))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 发一条消息，拿回 Hermes 的回复。
    ///
    /// **单飞**：Hermes 会拒绝同一个会话上的第二个活跃占用者
    /// （"Session ... already has a live owner"）。旧实现在用户等待那约 10 秒里再发一条
    /// 就会撞上，回复变成一句固定的错误串。所以调用是串行的。
    func ask(_ text: String, session: String) async throws -> String {
        // actor 本身保证了串行——这正是 Python 版要手工加 asyncio.Lock 的那件事。
        try await run(text, session: session)
    }

    /// 一个回合；命名会话不存在时先把它建出来。
    ///
    /// **建会话是独立一步，这是本文件不用 `--continue <name> --create-if-missing` 的全部理由。**
    /// 那个 flag 会自己插入会话行（Hermes `hermes_cli/main.py` 的 `_create_titled_session`），
    /// 而且**不传 cwd**，然后把这次运行当作 `--resume` 接着跑，于是跳过了
    /// `run_agent._ensure_db_session` 里记录 cwd 的那一步。一条没有 cwd 的会话不属于任何项目：
    /// 桌面端是拿会话的 cwd 去匹配项目文件夹来分组的，所以每段桌宠对话都散落在未归类列表里。
    ///
    /// 而一次**普通运行**（不带 `--continue`）会走到记录 cwd 的那条路径，把本进程的 cwd
    /// 记下来。所以新对话先这样建出来、**然后**再给它命名，之后每一轮都是普通的
    /// `--continue <name>`，不再碰 cwd。
    ///
    /// 这个探测在正常路径上不花钱：`--continue` 碰到已存在的会话就直接回答了。
    /// 只有真正的新对话才多付一次启动，而那次失败是在参数解析阶段就退出的（实测 0.4 秒），
    /// 根本没起 agent。
    private func run(_ text: String, session: String) async throws -> String {
        do {
            return try await chat(text, extra: ["--continue", session]).reply
        } catch SessionMissing.notFound {
            // 落到下面去建
        }

        let result = try await chat(text, extra: [])
        if let id = result.sessionID {
            await nameSession(id, as: session)
        } else {
            // 拿不到 id 就没法命名，下一轮找不到它、会再建一个。故意记成 error。
            Log.error("hermes 没有打印 session_id，\(session) 将无法续接")
        }
        return result.reply
    }

    private enum SessionMissing: Error { case notFound }

    private func chat(_ text: String, extra: [String]) async throws -> (reply: String, sessionID: String?) {
        var argv = [config.binary, "chat", "-q", text, "--oneshot", "-Q"] + extra
        if !config.toolsets.isEmpty { argv += ["-t", config.toolsets] }
        if !config.model.isEmpty { argv += ["-m", config.model] }
        if !config.reasoning.isEmpty { argv += ["--reasoning", config.reasoning] }

        let out = try await spawn(argv)

        if out.exitCode != 0 {
            let detail = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains(Self.noSuchSession) { throw SessionMissing.notFound }
            Log.error("hermes chat 失败（exit \(out.exitCode)）：\(detail.prefix(500))")
            throw HermesError.failed
        }

        let sessionID = Self.firstSessionID(in: out.stderr) ?? Self.firstSessionID(in: out.stdout)
        let reply = Self.strippingSessionID(from: out.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw HermesError.emptyReply }
        return (reply, sessionID)
    }

    /// 给刚建出来的会话起名，好让下一轮的 `--continue <name>` 找得到它。
    ///
    /// **在回复交回去之前同步做**，不放后台：万一在那个窗口里崩了，会话就没有名字，
    /// 下一轮会再建一个，这段对话从此成为孤儿。Hermes 的标题是唯一索引，所以一个
    /// 万一已被占用的名字会在这里失败——只记日志、绝不抛出，因为答案已经拿到手了，
    /// 为一个记账问题把它丢掉更糟。
    private func nameSession(_ id: String, as name: String) async {
        do {
            let out = try await spawn([config.binary, "sessions", "rename", id, name])
            if out.exitCode != 0 {
                Log.error("给会话 \(id) 命名为 \(name) 失败：\(out.stderr.trimmingCharacters(in: .whitespaces).prefix(300))")
            }
        } catch {
            Log.error("给会话 \(id) 命名为 \(name) 时出错：\(error)")
        }
    }

    /// 在项目工作目录里跑一条 hermes 命令。
    private func spawn(_ argv: [String]) async throws -> ProcessResult {
        let spec = ProcessSpec(argv: argv, cwd: config.workspace, timeout: config.timeout, env: config.env)
        let handle = try runner.start(spec)
        running = handle
        defer { running = nil }

        do {
            return try await handle.wait(timeout: config.timeout)
        } catch ProcessError.timedOut {
            await handle.stop(grace: Self.terminateGrace)
            Log.error("hermes 超时（\(config.timeout)s）：\(argv.count > 1 ? argv[1] : "?")")
            throw HermesError.timedOut
        } catch is CancellationError {
            // 被打断，或者客户端断开了。**把子进程一起带走**——
            // 旧实现把 subprocess.run 塞在 to_thread 里，取消等待的 task 之后子进程照跑完：
            // token 照烧，答案却被丢弃。
            await handle.stop(grace: Self.terminateGrace)
            throw CancellationError()
        } catch {
            throw HermesError.launchFailed
        }
    }

    // MARK: - stdout/stderr 清理

    static func firstSessionID(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = sessionIDPattern.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func strippingSessionID(from text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = sessionIDPattern.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text) else { return text }
        var copy = text
        copy.removeSubrange(r)
        return copy
    }
}
