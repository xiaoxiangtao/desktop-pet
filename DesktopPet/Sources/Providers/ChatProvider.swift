import Foundation

public enum ChatEvent: Sendable, Equatable {
    case delta(String)        // 流式增量
    case message(String)      // 一次性完整回复（HermesCLI 走这条）
    case status(String)       // "思考中" / 工具调用提示
}

public enum ProviderHealth: Sendable, Equatable {
    case ready, unavailable(String)
}

public struct ChatTurn: Sendable {
    public let text: String
    public let historyUID: String?
    public init(text: String, historyUID: String? = nil) {
        self.text = text
        self.historyUID = historyUID
    }
}

/// 接一个新 LLM 后端 = 实现本协议 + 在 ProviderRegistry 注册，共 2 个文件改动。
/// Hermes 是长在 $HOME 里的私有依赖，分发版必须能在没有它的机器上开箱对话，
/// 所以对话后端从一开始就是可替换的。
public protocol ChatProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// 一次回合。取消这个 stream 必须真正终止底层工作（子进程 / HTTP 任务），
    /// 否则旧版那个「前端重连把对话 task cancel 掉、hermes 子进程照跑完照烧 token」
    /// 的老问题会原样复活。
    func respond(to turn: ChatTurn) -> AsyncThrowingStream<ChatEvent, Error>
    func probe() async -> ProviderHealth
}
