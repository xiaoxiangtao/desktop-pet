import Foundation
import AppKit
import PetCore

/// 读取任意应用里"当前选中的文本"。
///
/// 两条路，缺一不可：
/// 1. **Accessibility API**（`kAXSelectedText`）——干净、不碰剪贴板。
/// 2. **合成 ⌘C + 读剪贴板**——兜底。
///
/// 为什么必须有兜底：Stage 0 的调研**实测 AX 在 Electron 应用上返回 `noValue`**
/// （VS Code、微信、ChatGPT 客户端这类都是），而这些恰恰是会去查词的地方。
///
/// ⌘C 兜底会短暂改写剪贴板，所以**必须原样恢复，且要连类型一起恢复**——
/// 用户剪贴板里可能是一张图、一段富文本，只恢复纯文本等于把它毁了。
public struct SelectionReader: Sendable {
    /// 合成 ⌘C 之后等多久去读剪贴板。太短读到的是旧内容。
    public static let pasteboardSettleDelay: TimeInterval = 0.12

    public init() {}

    public enum Source: String, Sendable { case accessibility, clipboard }

    public struct Selection: Sendable, Equatable {
        public let text: String
        public let source: Source
    }

    /// 清洗选中的文本：规整空白、砍掉过长的、丢掉纯符号、**挡掉中文和整段的**。
    ///
    /// 纯函数，因此可测——这一层最容易出"选中一整段结果拿去当单词查"的问题。
    public static func clean(_ raw: String, limit: Int = 200, wordLimit: Int = 3) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty, collapsed.count <= limit else { return nil }
        // 至少要有一个文字，否则是纯标点/数字，查了也没意义
        let hasWord = collapsed.unicodeScalars.contains {
            CharacterSet.letters.contains($0)
        }
        guard hasWord else { return nil }
        // **带中日韩文字的一律不查**：查词查的是英文（词典是 ECDICT），
        // 中文选区查不出东西，走到最后只会落到 LLM 变成一次没人想要的对话。
        // 混排的（"distribution 分布"）也挡掉——那种多半是划错了边界。
        guard !collapsed.unicodeScalars.contains(where: { cjk.contains($0) }) else { return nil }
        // **代码、文件名、标识符不是词**。用户报的例子：划中
        // `summarize_subtitle_to_notes.py` 会冒出查词浮标——它不含空格，
        // 按词数算就是"一个词"，前面每道闸都拦不住。
        guard !looksLikeCode(collapsed) else { return nil }
        // **超过 wordLimit 个词就不是查词，是划错了**。字符上限（200）拦不住这种：
        // 一整段话往往还不到 200 字，于是一路走到查词失败、再落到 LLM。
        // 挡在这里而不是挡在查词那步，浮标就根本不会冒出来——不会出现"点了没反应"。
        return wordCount(collapsed) <= wordLimit ? collapsed : nil
    }

    /// 看起来像代码而不像自然语言。判据都取**英文单词里不会出现**的形状：
    ///
    /// - 下划线：`snake_case`、`__init__`
    /// - 代码符号：路径分隔、括号、运算符……
    /// - 词内的点：`notes.py`、`np.array`（**词尾的点不算**，"demographic." 要照查）
    /// - 词内的大写：`camelCase`、`SelectionReader`（英文单词不会在中间换大写）
    /// - 字母数字混排：`utf8`、`CA6003`、`h1`
    ///
    /// 连字符**不在此列**：`back-propagation`、`state-of-the-art` 是正经查词对象。
    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("_") { return true }
        if text.unicodeScalars.contains(where: { codeSymbols.contains($0) }) { return true }
        for pattern in [#"[A-Za-z0-9]\.[A-Za-z0-9]"#,   // 词内的点
                        #"[a-z][A-Z]"#,                  // 词内换大写
                        #"[A-Za-z][0-9]|[0-9][A-Za-z]"#] // 字母数字混排
        where text.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static let codeSymbols = CharacterSet(charactersIn: "/\\|<>{}[]()=;:#$@*&^~`+%")

    /// 数词数。空白分词就够——中日韩在上一步已经整个挡掉了，这里不必再操心没有空格的语言。
    static func wordCount(_ text: String) -> Int {
        text.split(separator: " ").count
    }

    /// 汉字、假名、谚文。够用就行，不追求 Unicode 全覆盖。
    private static let cjk: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "\u{4E00}"..."\u{9FFF}")     // 汉字
        s.insert(charactersIn: "\u{3040}"..."\u{30FF}")     // 假名
        s.insert(charactersIn: "\u{AC00}"..."\u{D7AF}")     // 谚文
        return s
    }()

    /// 先试 AX，失败再用剪贴板兜底。
    public func read() -> Selection? {
        if let viaAX = readViaAccessibility(), let text = Self.clean(viaAX) {
            return Selection(text: text, source: .accessibility)
        }
        if let viaClipboard = readViaClipboard(), let text = Self.clean(viaClipboard) {
            return Selection(text: text, source: .clipboard)
        }
        return nil
    }

    // MARK: - AX

    private func readViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused else { return nil }
        var selected: CFTypeRef?
        // Electron 应用这里会返回 .noValue —— 实测过，所以下面必须有兜底。
        guard AXUIElementCopyAttributeValue(element as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString,
                                            &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 剪贴板兜底

    private func readViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)
        defer { Self.restore(saved, to: pasteboard) }

        let before = pasteboard.changeCount
        Self.sendCommandC()
        // 等剪贴板落定；没等够会读到**上一次**的内容，那比读不到更糟
        // （用户会看到自己十分钟前复制的东西被拿去查词）。
        let deadline = Date().addingTimeInterval(0.6)
        while pasteboard.changeCount == before && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard pasteboard.changeCount != before else { return nil }
        return pasteboard.string(forType: .string)
    }

    /// 整个剪贴板的快照——**所有类型**，不只是纯文本。
    /// 只存 string 的话，用户剪贴板里的图片或富文本会在恢复时被抹成空。
    static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var box: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { box[type] = data }
            }
            return box
        }
    }

    static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { box -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in box { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func sendCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let c: CGKeyCode = 8   // kVK_ANSI_C
        let down = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
