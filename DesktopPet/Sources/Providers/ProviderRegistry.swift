import Foundation
import PetCore

/// 按设置挑一个对话后端。
///
/// 接一个新后端 = 实现 `ChatProvider` + 在这里加一个 case，共 2 个文件改动。
/// 这一层存在的理由是分发：**别人的机器上没有 Hermes**，默认必须落在一个
/// 填个地址和密钥就能用的路径上。
public enum ProviderRegistry {
    public static let openAI = "openai"
    public static let hermesCLI = "hermes_cli"

    public static func make(from settings: Settings = .load()) -> any ChatProvider {
        switch settings.chatProvider {
        case hermesCLI:
            return HermesCLIProvider(config: HermesConfig(
                binary: settings.hermesBinary,
                sessionPrefix: settings.sessionPrefix,
                sessionPerConversation: settings.sessionPerConversation,
                timeout: settings.hermesTimeout,
                toolsets: settings.hermesToolsets,
                model: settings.hermesModel,
                reasoning: settings.hermesReasoning))
        default:
            return OpenAIProvider(config: OpenAIProvider.Config(
                baseURL: settings.openAIBaseURL,
                model: settings.openAIModel,
                apiKey: Keychain.chatAPIKey,
                timeout: settings.chatTimeout))
        }
    }

    /// 设置页上那个「测试连接」。**真发一轮请求**，不只校验字段格式。
    public static func test(settings: Settings, apiKey: String?) async -> ProviderHealth {
        guard settings.chatProvider != hermesCLI else {
            return await HermesCLIProvider(config: HermesConfig(binary: settings.hermesBinary)).probe()
        }
        return await OpenAIProvider(config: OpenAIProvider.Config(
            baseURL: settings.openAIBaseURL,
            model: settings.openAIModel,
            apiKey: apiKey,
            timeout: 30)).probe()
    }
}
