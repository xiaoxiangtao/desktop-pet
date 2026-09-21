import Testing
import Foundation
@testable import PetCore
@testable import Providers

/// 拦下所有请求，按预设回放。**分发版的对话全压在这条 HTTP 路径上**，
/// 而 CI 里不可能去戳真的 API，所以用 URLProtocol 桩把它整条钉住。
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var contentType = "text/event-stream"
    /// 最后一次请求的正文，用来断言"历史真的带上去了""没 key 时不带 Authorization"。
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var lastHeaders: [String: String] = [:]
    nonisolated(unsafe) static var lastURL: URL?

    static func reset() {
        status = 200; body = ""; contentType = "text/event-stream"
        lastBody = [:]; lastHeaders = [:]; lastURL = nil
    }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastURL = request.url
        Self.lastHeaders = request.allHTTPHeaderFields ?? [:]
        // URLProtocol 看到的 request 的 httpBody 可能已被换成 stream，两条都试。
        let data = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var out = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                out.append(buffer, count: n)
            }
            return out
        } ?? Data()
        Self.lastBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": Self.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func provider(baseURL: String = "https://stub.test/v1",
                      model: String = "test-model",
                      apiKey: String? = "sk-test") -> OpenAIProvider {
    OpenAIProvider(config: .init(baseURL: baseURL, model: model, apiKey: apiKey, timeout: 5),
                   sessionConfiguration: StubProtocol.configuration())
}

private func collect(_ provider: OpenAIProvider, _ text: String,
                     uid: String = "t1") async throws -> (deltas: [String], message: String?) {
    var deltas: [String] = []
    var message: String?
    for try await event in provider.respond(to: ChatTurn(text: text, historyUID: uid)) {
        switch event {
        case .delta(let d):   deltas.append(d)
        case .message(let m): message = m
        case .status:         break
        }
    }
    return (deltas, message)
}

private let sse = """
    data: {"choices":[{"delta":{"content":"喵"}}]}

    data: {"choices":[{"delta":{"content":"，在的"}}]}

    data: [DONE]

    """

/// **必须串行**：这组测试共用 `StubProtocol` 的静态状态，
/// 并行跑会互相把 status/body 覆盖掉（实测表现为随机几条失败）。
@Suite(.serialized)
struct OpenAIProviderTests {
    // MARK: - 地址拼接

    /// 三种写法在各家文档里都出现过，全都得能用——**这是最容易让人配不通的一步**。
    @Test func 服务地址三种写法都拼得对() {
        let expected = "https://api.example.com/v1/chat/completions"
        #expect(OpenAIProvider.endpoint(from: "https://api.example.com")?.absoluteString == expected)
        #expect(OpenAIProvider.endpoint(from: "https://api.example.com/v1")?.absoluteString == expected)
        #expect(OpenAIProvider.endpoint(from: "https://api.example.com/v1/")?.absoluteString == expected)
        #expect(OpenAIProvider.endpoint(from: expected)?.absoluteString == expected)
        // 没写协议头也要能用：用户从文档里复制时常常只带域名。
        #expect(OpenAIProvider.endpoint(from: "api.example.com/v1")?.absoluteString == expected)
        // 本机推理服务是 http，不能被强行升成 https。
        #expect(OpenAIProvider.endpoint(from: "http://localhost:11434/v1")?.absoluteString
            == "http://localhost:11434/v1/chat/completions")
        #expect(OpenAIProvider.endpoint(from: "   ") == nil)
    }

    // MARK: - 流式

    @Test func 流式增量逐段发出且最后给一条定稿() async throws {
        StubProtocol.reset()
        StubProtocol.body = sse
        let (deltas, message) = try await collect(provider(), "在吗")
        #expect(deltas == ["喵", "，在的"])
        #expect(message == "喵，在的", "定稿要是完整的那一句，界面拿它做最终替换")
    }

    @Test func 流里夹的错误要抛出来而不是当成空回复() async {
        StubProtocol.reset()
        StubProtocol.body = "data: {\"error\":{\"message\":\"model overloaded\"}}\n\n"
        await #expect(throws: (any Error).self) { _ = try await collect(provider(), "hi") }
    }

    // MARK: - 历史

    @Test func 同一轮对话带上历史换了对话就清空() async throws {
        StubProtocol.reset()
        StubProtocol.body = sse
        let p = provider()
        _ = try await collect(p, "第一句", uid: "a")
        _ = try await collect(p, "第二句", uid: "a")
        var messages = StubProtocol.lastBody["messages"] as? [[String: String]] ?? []
        // system + (第一轮 user/assistant) + 本轮 user
        #expect(messages.count == 4, "OpenAI 协议无状态，不自己带历史猫就会失忆")
        #expect(messages.first?["role"] == "system")
        #expect(messages.last?["content"] == "第二句")

        _ = try await collect(p, "新对话第一句", uid: "b")
        messages = StubProtocol.lastBody["messages"] as? [[String: String]] ?? []
        #expect(messages.count == 2, "换了 historyUID 就是新对话，旧历史必须丢掉")
    }

    // MARK: - 鉴权

    /// 本机推理服务（Ollama / LM Studio）通常不需要 key。带一个空的 Bearer
    /// 会被某些服务判成鉴权失败，所以没填就**根本不带这个头**。
    @Test func 没填密钥时不带鉴权头() async throws {
        StubProtocol.reset()
        StubProtocol.body = sse
        _ = try await collect(provider(apiKey: nil), "hi")
        #expect(StubProtocol.lastHeaders["Authorization"] == nil)

        StubProtocol.reset()
        StubProtocol.body = sse
        _ = try await collect(provider(apiKey: "sk-abc"), "hi")
        #expect(StubProtocol.lastHeaders["Authorization"] == "Bearer sk-abc")
    }

    // MARK: - 错误

    /// 每条错误都直接显示在气泡里，所以必须是**用户照着能做事**的话，
    /// 不能是 "HTTP 401" 这种只有开发者看得懂的东西。
    @Test func 常见错误码说的是人话() async {
        for (code, keyword) in [(401, "密钥"), (404, "模型"), (429, "额度")] {
        StubProtocol.reset()
        StubProtocol.status = code
        StubProtocol.body = "{\"error\":\"nope\"}"
        do {
            _ = try await collect(provider(), "hi")
            Issue.record("\(code) 应当抛错")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(message.contains(keyword), "\(code) 的提示里应出现「\(keyword)」，实际：\(message)")
        }
    }
    }

    /// 有些端点（尤其本地推理服务）不认 `stream: true`，拿 400 顶回来。
    /// 这时要**自动退回非流式重试**，而不是让用户去猜为什么这个模型不能用。
    @Test func 流式被拒时自动退回非流式() async throws {
        final class Flipper: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var sawStream = false
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 8192)
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n > 0 { data = Data(buffer[0..<n]) }
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let wantsStream = json["stream"] as? Bool == true
            if wantsStream { Self.sawStream = true }
            let status = wantsStream ? 400 : 200
            let body = wantsStream
                ? "{\"error\":\"stream unsupported\"}"
                : "{\"choices\":[{\"message\":{\"content\":\"好的\"}}]}"
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    Flipper.sawStream = false
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [Flipper.self]
    let p = OpenAIProvider(config: .init(baseURL: "https://stub.test/v1", model: "m",
                                         apiKey: nil, timeout: 5),
                           sessionConfiguration: configuration)
    let (_, message) = try await collect(p, "hi")
    #expect(Flipper.sawStream, "第一次应当先试流式")
    #expect(message == "好的", "被拒之后要退回非流式，而不是把错误抛给用户")
    }

    // MARK: - 未配置

    @Test func 没配置时立刻说清楚而不是发一轮注定失败的请求() async {
        StubProtocol.reset()
        let p = OpenAIProvider(config: .init(baseURL: "", model: "", apiKey: nil),
                           sessionConfiguration: StubProtocol.configuration())
        guard case .unavailable(let why) = await p.probe() else {
        Issue.record("空配置应当 unavailable"); return
    }
    #expect(why.contains("设置"))
    #expect(StubProtocol.lastURL == nil, "字段都没填就不该真的发请求出去")
    }
}
