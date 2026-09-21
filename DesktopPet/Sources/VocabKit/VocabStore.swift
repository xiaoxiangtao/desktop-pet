import Foundation
import PetCore

/// 英文查词 + 生词本，全部在本机、全部在 Swift 里。
///
/// **为什么是纯 Swift 而不是 Python sidecar**：分发版不能假设用户机器上有 3.10+ 的
/// 解释器，更不能假设有某一套私有工具。查词的全部工作就是"按主键查一次 SQLite、
/// 渲染一张卡片、写一行记录"，本地实测 0.08 秒——没有任何需要 Python 的理由。
///
/// 两个库：
/// - **ECDICT**（只读，约 100 MB，用户在向导里下载安装）：770k 词条的英汉词典。
/// - **生词本**（读写，几十 KB）：用户查过的词，落在 Application Support。
///
/// 词典没装时查词返回 `.unavailable`，生词本照常可用——两者互不依赖。
public struct VocabStore: Sendable {
    public struct Card: Sendable, Equatable {
        public let word: String
        public let reply: String          // 已渲染好的卡片文本，气泡直接显示
        public let saved: Bool
    }

    public struct Entry: Sendable, Codable, Equatable {
        public let word: String
        public let zh: String
        public let ipa: String
        public let createdAt: String

        public init(word: String, zh: String, ipa: String, createdAt: String) {
            self.word = word
            self.zh = zh
            self.ipa = ipa
            self.createdAt = createdAt
        }
    }

    public struct DeleteResult: Sendable, Equatable {
        public let success: Bool
        public let word: String
        /// 镜像到外部词库（Anki、欧路等）的结果。本项目只管本地，恒为 `skipped`；
        /// 字段保留是给接外部同步的人用的——界面已经按"本地删成功但镜像失败"
        /// 这种情况排过版，去掉会让那一层退化。
        public let anki: String
        public let eudic: String
    }

    /// 查词的三种结局。**"查不到"必须是弃权而不是错误**——它要能交给下一环（LLM）。
    /// 旧实现在这里返回「请稍后再试」，是个死胡同：词本来就不在词典里，"稍后"永远不会成功。
    public enum Outcome: Sendable, Equatable {
        case card(Card)
        case declined                     // 不该触发，或词典里没有
        case unavailable(String)          // 词典没装，要告诉用户
    }

    public let dictionaryPath: String
    public let notebookPath: String

    public init(dictionaryPath: String? = nil, notebookPath: String? = nil) {
        self.dictionaryPath = dictionaryPath ?? Paths.dictionary.path
        self.notebookPath = notebookPath ?? Paths.vocabularyDB.path
    }

    public var dictionaryAvailable: Bool {
        FileManager.default.isReadableFile(atPath: dictionaryPath)
    }

    // MARK: - 查词

    /// 聊天路径：先过形状判定，再查词典。任何一步不成立都弃权给 LLM。
    public func lookup(_ text: String) async -> Outcome {
        guard VocabEligibility.qualifies(text) else { return .declined }
        return await forceLookup(text)
    }

    /// 划词路径：用户划选表达了**明确的查词意图**，跳过形状判定直接查。
    public func forceLookup(_ text: String) async -> Outcome {
        guard dictionaryAvailable else {
            return .unavailable("词典还没装。点菜单栏的猫 →「设置…」→「词典」下载 ECDICT（约 100 MB），之后查词就能用了。")
        }
        let key = VocabEligibility.normalizeKey(text)
        guard let entry = lookUpDictionary(key) else { return .declined }
        let saved = record(entry)
        let count = lookupCount(for: entry.key)
        return .card(Card(word: entry.key,
                          reply: Self.formatCard(entry, input: text, lookupCount: count, saved: saved),
                          saved: saved))
    }

    struct DictionaryEntry: Sendable, Equatable {
        var key: String              // 词典里的标准拼写（小写）
        var lemma: String?           // 原形，仅当输入是变位形式时有值
        var phonetic: String
        var zhDefinition: String
        var enDefinition: String
        var pos: String
    }

    /// ECDICT 的表名在两种分发里不一样：官方 release 的 `stardict.db` 用 `stardict`，
    /// 我们的安装器建的是 `ecdict`。两个都试，省掉"装了却查不到"这种沉默失败。
    static let tableCandidates = ["ecdict", "stardict"]

    func lookUpDictionary(_ key: String) -> DictionaryEntry? {
        guard let db = try? SQLiteDB(path: dictionaryPath, readOnly: true) else { return nil }
        for table in Self.tableCandidates {
            let sql = "SELECT word, phonetic, definition, translation, pos, exchange FROM \(table) WHERE word = ? COLLATE NOCASE LIMIT 1"
            guard let rows = try? db.execute(sql, [key]), let row = rows.first else { continue }
            return DictionaryEntry(
                key: row.text("word").lowercased(),
                lemma: Self.lemma(fromExchange: row.text("exchange")),
                phonetic: row.text("phonetic"),
                // ECDICT 用**字面两个字符 `\n`** 分隔义项，不是真换行。
                // 这个坑在本项目里出现过三次（卡片、导出、生词本列表），所以只在这一处解。
                zhDefinition: Self.unescape(row.text("translation")),
                enDefinition: Self.unescape(row.text("definition")),
                pos: row.text("pos"))
        }
        return nil
    }

    /// ECDICT 的 `exchange` 字段形如 `0:go/1:p`，`0:` 后面是原形。
    /// 只有当原形和查询词不同才有展示价值。
    static func lemma(fromExchange exchange: String) -> String? {
        for part in exchange.split(separator: "/") where part.hasPrefix("0:") {
            let value = String(part.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
    }

    // MARK: - 卡片

    /// 卡片文本。分节、可读、**不编造**：词典没给音标就不印音标那一节，
    /// 写库失败就如实说没存上，绝不先宣布"已加入生词本"再去写。
    static func formatCard(_ entry: DictionaryEntry, input: String,
                           lookupCount: Int, saved: Bool) -> String {
        var lines: [String] = ["📚 \(input.trimmingCharacters(in: .whitespacesAndNewlines))"]
        if let lemma = entry.lemma, lemma.lowercased() != entry.key {
            lines.append("  (\(entry.key) → \(lemma))")
        }
        lines.append("")

        // ECDICT 只有一个音标字段，**不能标成 UK/US 两个读音**——那是在编造信息。
        if !entry.phonetic.isEmpty {
            lines.append("🔊 词典音标")
            lines.append("/\(entry.phonetic)/")
            lines.append("")
        }
        if !entry.zhDefinition.isEmpty {
            lines.append("🇨🇳 中文释义")
            lines.append(entry.zhDefinition)
            lines.append("")
        }
        if !entry.enDefinition.isEmpty {
            lines.append("🇬🇧 English definition")
            lines.append(entry.enDefinition)
            lines.append("")
        }
        lines.append("Source: ECDICT")
        lines.append("")
        if saved {
            lines.append(lookupCount > 1 ? "已加入生词本 · 第 \(lookupCount) 次查询"
                                         : "已加入生词本 · 第 1 次查询（首次）")
        } else {
            lines.append("未写入生词本（保存失败，请稍后重试）")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 生词本

    static let schema = """
        CREATE TABLE IF NOT EXISTS entries (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            normalized_key  TEXT    NOT NULL UNIQUE,
            input_text      TEXT    NOT NULL,
            entry_type      TEXT    NOT NULL DEFAULT 'word',
            lemma           TEXT,
            ipa_uk          TEXT,
            ipa_us          TEXT,
            zh_definition   TEXT    NOT NULL DEFAULT '',
            en_definition   TEXT    NOT NULL DEFAULT '',
            source          TEXT    NOT NULL DEFAULT 'ecdict',
            created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
            updated_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        );
        CREATE INDEX IF NOT EXISTS idx_entries_normalized_key ON entries(normalized_key);
        CREATE TABLE IF NOT EXISTS lookups (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            entry_id        INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            original_text   TEXT    NOT NULL,
            looked_up_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        );
        CREATE INDEX IF NOT EXISTS idx_lookups_entry_id ON lookups(entry_id);
        """

    func openNotebook() -> SQLiteDB? {
        guard let db = try? SQLiteDB(path: notebookPath, createDirectories: true) else { return nil }
        guard (try? db.executeScript(Self.schema)) != nil else { return nil }
        return db
    }

    /// 写一条生词 + 一条查询记录。返回是否真的写成功——**这个布尔会直接印在卡片上**，
    /// 所以不能乐观返回 true。
    @discardableResult
    func record(_ entry: DictionaryEntry) -> Bool {
        guard let db = openNotebook() else { return false }
        do {
            try db.execute("""
                INSERT INTO entries (normalized_key, input_text, lemma, ipa_uk, zh_definition, en_definition)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(normalized_key) DO UPDATE SET
                    zh_definition = excluded.zh_definition,
                    en_definition = excluded.en_definition,
                    ipa_uk        = excluded.ipa_uk,
                    updated_at    = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                """, [entry.key, entry.key, entry.lemma, entry.phonetic,
                      entry.zhDefinition, entry.enDefinition])
            try db.execute("""
                INSERT INTO lookups (entry_id, original_text)
                SELECT id, ? FROM entries WHERE normalized_key = ?
                """, [entry.key, entry.key])
            return true
        } catch {
            Log.warn("写生词本失败：\(error.localizedDescription)")
            return false
        }
    }

    func lookupCount(for key: String) -> Int {
        guard let db = openNotebook(),
              let rows = try? db.execute("""
                SELECT COUNT(*) AS n FROM lookups
                JOIN entries ON entries.id = lookups.entry_id
                WHERE entries.normalized_key = ?
                """, [key]),
              let n = rows.first.flatMap({ Int($0.text("n")) }) else { return 1 }
        return max(n, 1)
    }

    /// 生词本列表。`nil` 表示**库打不开**，必须和"本子是空的"区分开：
    /// 前者要报错，后者是正常状态（界面显示"还没有生词"）。
    public func list() async -> [Entry]? {
        guard let db = openNotebook(),
              let rows = try? db.execute("""
                SELECT normalized_key, zh_definition, ipa_uk, created_at
                FROM entries ORDER BY created_at DESC
                """) else { return nil }
        return rows.map {
            Entry(word: $0.text("normalized_key"),
                  zh: $0.text("zh_definition"),
                  ipa: $0.text("ipa_uk"),
                  createdAt: $0.text("created_at"))
        }
    }

    public func delete(_ word: String) async -> DeleteResult {
        let key = VocabEligibility.normalizeKey(word)
        guard let db = openNotebook() else {
            return DeleteResult(success: false, word: word, anki: "skipped", eudic: "skipped")
        }
        do {
            try db.execute("DELETE FROM lookups WHERE entry_id IN (SELECT id FROM entries WHERE normalized_key = ?)", [key])
            try db.execute("DELETE FROM entries WHERE normalized_key = ?", [key])
            return DeleteResult(success: db.changes > 0, word: key, anki: "skipped", eudic: "skipped")
        } catch {
            Log.warn("删除生词失败：\(error.localizedDescription)")
            return DeleteResult(success: false, word: key, anki: "skipped", eudic: "skipped")
        }
    }
}
