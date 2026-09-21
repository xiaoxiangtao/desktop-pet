import Foundation
import PetCore

/// 定位本 target 所在 bundle 用的标记类，见 `ResourceBundle`。
final class VocabKitAnchor: ResourceAnchor {}

/// 「这句话该不该自动触发查词」的判定。
///
/// 这是一道**形状 + 常见词**的过滤器，不是语义判断。它只负责把"明显不是在问单词"的
/// 消息挡掉；挡不住的交给词典，词典查不到再弃权给 LLM（见 `VocabStore.Outcome`）。
///
/// **只用形状判定是不够的**——曾经的版本只判"长得像英文单词"，于是 `zzyzxqwe` 也被
/// 路由进查词，词典查不到就回一句「请稍后再试」，用户既拿不到卡片也拿不到回答。
/// 所以这一层与"查不到就弃权"必须成对存在。
public enum VocabEligibility {
    static let maxLength = 240

    /// 打招呼不是查词。这些词在词典里都查得到，不挡的话每次说"hi"都弹一张卡片。
    static let socialChatWords: Set<String> = [
        "hi", "hello", "hey", "yo", "bye", "goodbye", "thanks", "thx",
    ]

    /// CEFR A1 词表：入门级词汇不值得记生词本。表在 `Resources/cefr_a1_words.txt`，
    /// 取不到时退化成空集合——**不能因为一个可选数据文件缺失就让查词整个失灵**。
    static let a1Words: Set<String> = {
        let bundle = ResourceBundle.named("DesktopPet_VocabKit", anchor: VocabKitAnchor.self)
            ?? Bundle(for: VocabKitAnchor.self)
        guard let url = bundle.url(forResource: "cefr_a1_words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }()

    private static let urlPattern = try! NSRegularExpression(
        pattern: "(?:https?://|www\\.)", options: [.caseInsensitive])
    private static let codePattern = try! NSRegularExpression(
        pattern: "`|\\b(?:def|class|import)\\b|<\\s*/?\\s*[a-z][^>]*>", options: [.caseInsensitive])
    /// 单个英文词，允许连字符和撇号（`well-known`、`don't`）。
    private static let singleWordPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z]+(?:['-][A-Za-z]+)*$")

    /// 词表加载了多少条。给 `--self-check` 用——装好的包里它不该是 0。
    public static var a1WordCount: Int { a1Words.count }

    public static func qualifies(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, stripped.count <= maxLength else { return false }
        guard !text.contains("\n"), !text.contains("\r") else { return false }
        let range = NSRange(stripped.startIndex..., in: stripped)
        guard urlPattern.firstMatch(in: stripped, range: range) == nil,
              codePattern.firstMatch(in: stripped, range: range) == nil else { return false }
        let normalized = stripped.lowercased()
        guard !socialChatWords.contains(normalized), !a1Words.contains(normalized) else { return false }
        return singleWordPattern.firstMatch(in: stripped, range: range) != nil
    }

    /// 入库用的键：NFC + 小写 + 去首尾空白 + 连续空白压成一个空格。
    /// 生词本的唯一索引建在这个键上，大小写和多余空格不该产生两条记录。
    public static func normalizeKey(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return nfc.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
