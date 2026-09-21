import Foundation
import PetCore

/// 走 OpenAI 兼容的 `/chat/completions`。**这是分发版的主力路径**：
/// 官方 API、Ollama、LM Studio、vLLM、各家中转，只要认这个协议就能接。
///
/// 为什么不做成"支持 N 家 API"：那 N 家里有 N-1 家都提供 OpenAI 兼容端点，
/// 而真正的差异（鉴权头、模型名）已经在 base URL 和 key 这两个输入里了。
/// 多写几个 provider 只是在重复同一件事。
///
/// 流式（SSE）是默认的：桌宠的气泡在逐字出字时才不像卡住。服务端不支持流式就退回
/// 一次性返回，两条路径都走同一个解析出口。
public actor OpenAIProvider: ChatProvider {
    public nonisolated let id = "openai"
    public nonisolated let displayName = "OpenAI 兼容 API"

    public struct Config: Sendable {
        public var baseURL: String
        public var model: String
        public var apiKey: String?
        public var systemPrompt: String
        public var timeout: TimeInterval
        /// 保留多少轮上下文。桌宠是闲聊，留太长只是在烧 token；
        /// 这个数字乘 2 是实际发出的消息条数（user + assistant 成对）。
        public var historyTurns: Int

        public init(baseURL: String, model: String, apiKey: String?,
                    systemPrompt: String = OpenAIProvider.defaultSystemPrompt,
                    timeout: TimeInterval = 120, historyTurns: Int = 8) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
            self.systemPrompt = systemPrompt
            self.timeout = timeout
            self.historyTurns = historyTurns
        }
    }

    /// 桌宠的性格。短、口语、不写列表——它住在屏幕角落的一个气泡里，
    /// 那里放不下 Markdown 排版，也没人想在桌宠身上读一篇小作文。
    public static let defaultSystemPrompt = """
        你是一只住在用户桌面上的猫，陪用户聊天。

        说话方式：
        - 简短、口语化，一般一到三句话。绝不写标题、项目符号或代码块。
        - 用中文回答中文，用英文回答英文。
        - 有猫的性格：好奇、随性、偶尔懒散，但不卖萌过头，也不学猫叫。
        - 不知道就说不知道，不编。

        你没有联网、读文件或运行命令的能力，被问到时如实说。
        """

    public enum ProviderError: LocalizedError, Equatable {
        case notConfigured
        case badURL(String)
        case http(Int, String)
        case emptyReply
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                "还没配置对话 API。点菜单栏的猫 →「设置…」填上服务地址和密钥就能聊了。"
            case .badURL(let raw):
                "服务地址填得不对：\(raw)"
            case .http(let code, let body):
                // 401/429 是用户自己能处理的，值得单独说清楚。
                switch code {
                case 401, 403: "API 密钥被拒绝了（\(code)），去「设置…」检查一下密钥。"
                case 404:      "找不到这个模型或地址（404），去「设置…」检查模型名和服务地址。"
                case 429:      "请求太频繁或额度用完了（429），过一会儿再试。"
                default:       "服务端返回 \(code)：\(body.prefix(200))"
                }
            case .emptyReply: "对方没有返回内容。"
            case .timedOut:   "等太久了，请稍后再试。"
            }
        }
    }

    private let config: Config
    private let session: URLSession
    /// 最近几轮对话。**由 provider 自己保存**，因为 OpenAI 协议是无状态的——
    /// 不带历史的话每一句都是全新对话，猫会立刻忘掉上一句说过什么。
    private var history: [(role: String, content: String)] = []
    /// 当前 historyUID。换了就是"新对话"，历史清空。
    private var currentUID: String?

    /// `sessionConfiguration` 只给测试用：整个分发版都压在这条 HTTP 路径上，
    /// 而它又不能在 CI 里去戳真的 API，所以留一个塞 URLProtocol 桩的口子。
    public init(config: Config, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.config = config
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = config.timeout
        configuration.timeoutIntervalForResource = config.timeout
        session = URLSession(configuration: configuration)
    }

    /// 把用户填的地址拼成端点。用户可能填 `https://api.example.com`、
    /// `.../v1` 或 `.../v1/chat/completions` 中的任意一种——三种都得能用，
    /// 因为这三种写法在各家文档里都出现过。
    static func endpoint(from baseURL: String) -> URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if !text.contains("://") { text = "https://" + text }
        if text.hasSuffix("/chat/completions") { return URL(string: text) }
        if text.hasSuffix("/v1") { return URL(string: text + "/chat/completions") }
        return URL(string: text + "/v1/chat/completions")
    }

    public func probe() async -> ProviderHealth {
        guard !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !config.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .unavailable(ProviderError.notConfigured.errorDescription!)
        }
        guard Self.endpoint(from: config.baseURL) != nil else {
            return .unavailable(ProviderError.badURL(config.baseURL).errorDescription!)
        }
        // **真发一轮最小请求**，不只是检查字段填没填。配置页上那个「测试连接」
        // 要能回答的是"现在能不能聊"，而不是"格式对不对"。
        do {
            _ = try await complete(messages: [["role": "user", "content": "ping"]],
                                   stream: false, maxTokens: 1)
            return .ready
        } catch {
            return .unavailable((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public nonisolated func respond(to turn: ChatTurn) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(turn: turn, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 取消 stream 必须真的停掉 HTTP 任务，否则"取消对话"只是不显示答案，
            // token 照烧——旧版就犯过这个错。
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(turn: ChatTurn,
                     continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) async throws {
        guard !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !config.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProviderError.notConfigured
        }
        if let uid = turn.historyUID, uid != currentUID {
            currentUID = uid
            history.removeAll()
        }

        var messages: [[String: String]] = [["role": "system", "content": config.systemPrompt]]
        messages += history.suffix(config.historyTurns * 2).map { ["role": $0.role, "content": $0.content] }
        messages.append(["role": "user", "content": turn.text])

        var reply = ""
        do {
            reply = try await streamCompletion(messages: messages) { delta in
                continuation.yield(.delta(delta))
            }
        } catch ProviderError.http(let code, let body) where code == 400 || code == 422 {
            // 有些端点（尤其是本地推理服务）不认 stream:true，拿 400 顶回来。
            // 退回非流式重试一次，比让用户去猜"为什么这个模型不能用"强。
            Log.warn("流式被拒（\(code)），退回非流式重试：\(body.prefix(120))")
            reply = try await complete(messages: messages, stream: false, maxTokens: nil)
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.emptyReply }
        history.append((role: "user", content: turn.text))
        history.append((role: "assistant", content: trimmed))
        // 流式时增量已经逐段发过了，这条 `.message` 是**定稿**：界面拿它做最终替换，
        // 既覆盖非流式路径，也修掉流式过程中可能出现的半个字。
        continuation.yield(.message(trimmed))
    }

    // MARK: - HTTP

    private func makeRequest(body: [String: Any]) throws -> URLRequest {
        guard let url = Self.endpoint(from: config.baseURL) else {
            throw ProviderError.badURL(config.baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 本地推理服务（Ollama / LM Studio）通常不需要 key，所以没填就不带这个头，
        // 而不是带一个空的 Bearer——那会被某些服务判成鉴权失败。
        if let key = config.apiKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = config.timeout
        return request
    }

    /// 非流式。`probe()` 和流式失败后的兜底都走这里。
    private func complete(messages: [[String: String]], stream: Bool, maxTokens: Int?) async throws -> String {
        var body: [String: Any] = ["model": config.model, "messages": messages, "stream": stream]
        if let maxTokens { body["max_tokens"] = maxTokens }
        let (data, response) = try await session.data(for: try makeRequest(body: body))
        try check(response, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            // probe 用 max_tokens=1 跑时内容可能真的是空的，那也算连通成功，
            // 所以这里不抛错，交给调用方判断。
            return ""
        }
        return content
    }

    /// 流式（SSE）。逐行读 `data: {...}`，`data: [DONE]` 收尾。
    private func streamCompletion(messages: [[String: String]],
                                  onDelta: @Sendable (String) -> Void) async throws -> String {
        let body: [String: Any] = ["model": config.model, "messages": messages, "stream": true]
        let (bytes, response) = try await session.bytes(for: try makeRequest(body: body))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 错误响应体也是走 bytes 来的，要先收完才能把原因告诉用户。
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw ProviderError.http(http.statusCode, String(decoding: raw, as: UTF8.self))
        }

        var full = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // 有的服务把错误也塞在流里，而不是用 HTTP 状态码。
            if let error = json["error"] as? [String: Any] {
                throw ProviderError.http(500, (error["message"] as? String) ?? "\(error)")
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String, !piece.isEmpty else { continue }
            full += piece
            onDelta(piece)
        }
        return full
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}
