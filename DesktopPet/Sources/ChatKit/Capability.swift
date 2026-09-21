import Foundation
import PetCore
import Providers
import VocabKit

/// 能力链：一条消息依次交给「查词」「对话」……直到某一环认领它。
///
/// **每一环必须能弃权并交给下一环**，而不是用一条错误消息终结整条链。
/// 这条要求来自一个真实的死胡同：早先的查词分支用形状判定挑出"长得像英文单词"的串
/// （实测 `zzyzxqwe` 也算），词典查不到时回一句「请稍后再试」——用户既没拿到卡片
/// 也没拿到 LLM 回答，而"稍后"永远不会成功，因为那个词本来就不在词典里。
public enum CapabilityOutcome: Sendable {
    case handled(String)   // 本环处理完毕，回复即结果
    case declined          // 本环不处理，交给下一环
}

public protocol Capability: Sendable {
    var id: String { get }
    func handle(_ input: String) async -> CapabilityOutcome
}
