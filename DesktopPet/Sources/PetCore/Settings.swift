import Foundation

/// 设置。Codable → Application Support 下的 JSON。
///
/// **API 密钥不在这里**——它在钥匙串（见 `Keychain`）。settings.json 是明文、会进备份、
/// 用户也会自己打开看，密钥写进去意味着每一次"把配置发给别人看看"都在泄露凭据。
public struct Settings: Codable, Sendable, Equatable {
    // MARK: 对话

    /// `openai` = OpenAI 兼容端点（默认，开箱即用的那条路）；
    /// `hermes_cli` = 本机装了 Hermes Agent CLI 的人才用得上的可选后端。
    public var chatProvider: String = "openai"
    public var chatTimeout: Double = 120

    /// OpenAI 兼容端点。官方 API、Ollama、LM Studio、vLLM、各家中转都认这个协议。
    /// 填 `https://api.example.com`、`.../v1` 或 `.../v1/chat/completions` 都行。
    public var openAIBaseURL: String = ""
    public var openAIModel: String = ""

    // MARK: 可选：Hermes Agent CLI

    public var hermesBinary: String = NSString(string: "~/.local/bin/hermes").expandingTildeInPath
    public var hermesModel: String = ""
    public var hermesReasoning: String = "low"
    /// 空串 = 加载全部工具集。**默认只留 memory**：全开时光工具定义就占满上下文，
    /// 实测一个正文仅 233 字符的会话累计烧掉 112,853 input tokens、单次回复约 30 秒，
    /// 只留 memory 后降到约 7 秒。
    public var hermesToolsets: String = "memory"
    public var hermesTimeout: Double = 120
    public var sessionPrefix: String = "desktop-pet"
    public var sessionPerConversation: Bool = true

    // MARK: 字幕

    public var subtitleLocale: String = "en-US"
    /// 实测这个选项值 3.8 倍延迟，而且准确率不降反升，所以默认开。
    public var subtitleFastResults: Bool = true
    public var subtitleSource: String = "microphone"   // microphone / system
    /// 字幕字号档位：small / medium / large。给档位不给数字——菜单里没有输入框。
    public var subtitleFontSize: String = "medium"
    /// 对话区收起（只看字幕）。存盘是为了下次打开气泡还是用户上次选的样子。
    public var chatCollapsed: Bool = false

    public var usesSystemAudio: Bool { subtitleSource == "system" }
    public var subtitleFontPoints: Double {
        switch subtitleFontSize { case "small": 14; case "large": 18; default: 16 }
    }

    /// 字幕结束后是否自动整理成中文笔记（走已配置的对话 API）。
    public var notesAutoRun: Bool = false
    /// 自动做笔记的时长门槛（分钟）。**短会话不值得花这个钱**——随手开两分钟试一下
    /// 也去跑一遍全文笔记纯属浪费。设为 0 表示每次都做。
    public var notesMinMinutes: Double = 20

    /// 字幕会话的存放根目录。空串 = 默认位置。用户在菜单栏选过目录后这里才有值。
    public var subtitleRoot: String = ""

    /// 字幕会话真正要落到哪。用户选过就用用户选的**原样那一层**——
    /// 再往下拼一层 `subtitles` 会让"我明明选了这个文件夹"变成一件意外的事。
    public var subtitleDirectory: URL {
        if !subtitleRoot.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: NSString(string: subtitleRoot).expandingTildeInPath)
        }
        return (Paths.developmentRoot?.appendingPathComponent("data") ?? Paths.applicationSupport)
            .appendingPathComponent("subtitles", isDirectory: true)
    }

    public var selectionLookupEnabled: Bool = true

    public init() {}

    /// 菜单/设置页改了以后发这条，界面据此当场刷新（字号这类不该等到重启）。
    public static let didChange = Notification.Name("pet.settingsDidChange")

    public static var fileURL: URL {
        Paths.applicationSupport.appendingPathComponent("settings.json")
    }

    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = decodeTolerant(data) else { return Settings() }
        return s
    }

    /// **缺字段不能整份作废**：合成的 Decodable 遇到缺失的键直接抛错，而 load() 会因此
    /// 退回默认值——每加一个新设置项，老用户的存放目录、笔记门槛就被静默清掉。
    /// 所以先拿默认值垫底，再盖上已存的值。
    static func decodeTolerant(_ data: Data) -> Settings? {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(stored) { $1 }) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: merged)
    }

    public func save() {
        try? FileManager.default.createDirectory(at: Paths.applicationSupport,
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.fileURL)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 对话配好了没有。没配好时气泡会引导用户去设置页，而不是发一轮注定失败的请求。
    public var chatConfigured: Bool {
        if chatProvider == "hermes_cli" {
            return FileManager.default.isExecutableFile(atPath: hermesBinary)
        }
        return !openAIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !openAIModel.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 环境自检：这台机器上什么齐了、什么没齐、没齐会怎样。
///
/// 设计约束：**每一条都必须是可降级的**。`hasFatalGap` 恒为 false，不是巧合而是
/// 验收标准——有任何一项"缺了就整个不能用"，那是架构问题，不是提示文案问题。
public struct DependencyReport: Sendable {
    public struct Item: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let detail: String
        public let present: Bool
        /// 缺失时会怎样。空字符串意味着"缺了就废"——那是架构缺陷。
        public let degradation: String
        /// 用户可以点一下就去处理的动作（打开设置页 / 下载词典）。
        public let action: Action?

        public enum Action: Sendable, Equatable {
            case openSettings          // 本 app 的设置页
            case installDictionary
            case systemSettings(String) // 系统设置的某一页
        }
    }

    public let items: [Item]

    public static func probe(settings: Settings = .load()) -> DependencyReport {
        let fm = FileManager.default
        var items: [Item] = []

        // macOS 版本。字幕用的 SpeechAnalyzer 是 26 起才有的，低于这个版本
        // app 根本装不上（LSMinimumSystemVersion），所以这条只是把事实写清楚。
        let os = ProcessInfo.processInfo.operatingSystemVersion
        items.append(Item(id: "os", name: "macOS 版本",
                          detail: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                          present: os.majorVersion >= 26,
                          degradation: "实时字幕需要 macOS 26 或更高版本",
                          action: nil))

        items.append(Item(id: "chat", name: "对话 API",
                          detail: settings.chatConfigured
                              ? "\(settings.openAIModel.isEmpty ? settings.chatProvider : settings.openAIModel)"
                              : "未配置",
                          present: settings.chatConfigured,
                          degradation: "不能和猫对话；查词和字幕不受影响",
                          action: .openSettings))

        let dict = Paths.dictionary.path
        items.append(Item(id: "dictionary", name: "ECDICT 词典",
                          detail: fm.isReadableFile(atPath: dict) ? sizeText(dict) : "未安装（约 100 MB）",
                          present: fm.isReadableFile(atPath: dict),
                          degradation: "查词不可用；对话和字幕不受影响",
                          action: .installDictionary))

        for permission in Permission.allCases {
            let granted = permission.status.isUsable
            items.append(Item(id: permission.rawValue,
                              name: permission.title,
                              detail: granted ? "已授权" : "未授权",
                              present: granted,
                              degradation: permission.purpose,
                              action: .systemSettings(permission.rawValue)))
        }
        return DependencyReport(items: items)
    }

    public static func sizeText(_ path: String) -> String {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber else {
            return "已安装"
        }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    public var summary: String {
        items.map { item in
            let mark = item.present ? "✓" : "✗"
            let tail = item.present ? "" : "　→ \(item.degradation)"
            return "\(mark) \(item.name)　\(item.detail)\(tail)"
        }.joined(separator: "\n")
    }

    /// 有没有哪一项缺了就整个不能用。**必须恒为 false**——那是架构缺陷。
    public var hasFatalGap: Bool { items.contains { !$0.present && $0.degradation.isEmpty } }
}
