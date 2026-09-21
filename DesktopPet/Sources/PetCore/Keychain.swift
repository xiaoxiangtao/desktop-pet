import Foundation
import Security

/// API key 存钥匙串，不落在 settings.json 里。
///
/// settings.json 是明文、会被备份、也会被用户自己打开看——把密钥写进去意味着
/// 任何一次"把配置发给别人看看"都在泄露凭据。钥匙串是 macOS 给这件事的标准答案，
/// 而且 `kSecAttrAccessibleAfterFirstUnlock` 让 app 在没人登录 GUI 时也能读到。
public enum Keychain {
    /// 一个服务名下按 account 区分不同的 key，将来接第二个服务商不用改这层。
    static let service = Paths.bundleID

    public static func set(_ value: String, account: String) {
        // 先删再写。SecItemUpdate 要分"存在/不存在"两条路径，而删一个不存在的条目
        // 本来就是无害的，合成一条路径少一半代码。
        delete(account: account)
        guard !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { Log.warn("写钥匙串失败（\(status)）：\(account)") }
    }

    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 对话用的 API key。
    public static let chatAPIKeyAccount = "chat-api-key"

    public static var chatAPIKey: String? {
        get { get(account: chatAPIKeyAccount) }
        set { set(newValue ?? "", account: chatAPIKeyAccount) }
    }
}
