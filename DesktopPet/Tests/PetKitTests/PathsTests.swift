import Testing
import Foundation
@testable import PetCore
@testable import VocabKit

@Test func 数据一律落在自己的目录下() {
    // 分发版不能往用户的 $HOME 里乱放东西，也不能假设某个别的工具的目录存在。
    #expect(Paths.vocabularyDB.path.contains("Application Support"))
    #expect(Paths.dictionary.path.contains(Paths.bundleID))
}

@Test func 开发期能定位到仓库根() {
    // 靠 `.desktop-pet-repo` 标志文件确认，而不是只看 #filePath 推出来的目录存在——
    // #filePath 在分发的二进制里仍是构建机上的路径，不确认的话 .app 会误判成开发模式。
    #expect(Paths.developmentRoot != nil, "swift test 跑在源码树里，应能找到仓库根")
}

// MARK: - 查词

@Test func 形状判定挡掉不该查的东西() {
    #expect(!VocabEligibility.qualifies("hello"), "社交寒暄词不触发")
    #expect(!VocabEligibility.qualifies("about"), "CEFR A1 词不值得记生词本")
    #expect(!VocabEligibility.qualifies("这是中文"))
    #expect(!VocabEligibility.qualifies("two words"), "只对单个词自动触发")
    #expect(!VocabEligibility.qualifies("https://example.com"))
    #expect(!VocabEligibility.qualifies("import foo"))
    #expect(!VocabEligibility.qualifies("line1\nline2"))
    #expect(VocabEligibility.qualifies("serendipity"))
    #expect(VocabEligibility.qualifies("well-known"), "连字符词是合法的")
}

@Test func 规范化键把大小写和多余空格收敛掉() {
    #expect(VocabEligibility.normalizeKey("  Serendipity  ") == "serendipity")
    #expect(VocabEligibility.normalizeKey("by  all   means") == "by all means")
}

/// **"查不到"必须是弃权而不是错误**——它要能交给下一环（LLM）。
/// 旧实现在这里返回「请稍后再试」，是个死胡同：词本来就不在词典里，"稍后"永远不会成功。
@Test func 查不到的词弃权而不是报错() async {
    let store = VocabStore(dictionaryPath: "/nonexistent/ecdict.sqlite3",
                           notebookPath: NSTemporaryDirectory() + "pet-test-\(UUID()).sqlite3")
    #expect(await store.lookup("hello") == .declined, "形状判定先挡掉，不该走到词典")
    // 词典不在时，明确的查词意图要得到一句能照着做的话，而不是静默失败。
    guard case .unavailable(let why) = await store.forceLookup("serendipity") else {
        Issue.record("词典缺失时应返回 .unavailable"); return
    }
    #expect(why.contains("设置"), "要告诉用户去哪儿装")
}

@Test func 生词本能写能读能删且区分空本子与打不开() async throws {
    let path = NSTemporaryDirectory() + "pet-test-\(UUID()).sqlite3"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = VocabStore(dictionaryPath: "/nonexistent", notebookPath: path)

    // 空本子 ≠ 打不开：前者是正常状态，返回空数组；nil 只留给真的读不了库。
    let empty = try #require(await store.list(), "库建得出来就不该返回 nil")
    #expect(empty.isEmpty)

    let entry = VocabStore.DictionaryEntry(key: "serendipity", lemma: nil, phonetic: "ˌserənˈdɪpɪti",
                                           zhDefinition: "n. 机缘巧合", enDefinition: "a happy accident",
                                           pos: "n")
    #expect(store.record(entry))
    let one = try #require(await store.list())
    #expect(one.count == 1 && one[0].word == "serendipity" && one[0].ipa == "ˌserənˈdɪpɪti")

    // 同一个词查第二次只增加查询次数，不产生第二条记录。
    #expect(store.record(entry))
    #expect(try #require(await store.list()).count == 1)
    #expect(store.lookupCount(for: "serendipity") == 2)

    let deleted = await store.delete("Serendipity")   // 大小写不该影响删除
    #expect(deleted.success)
    #expect(try #require(await store.list()).isEmpty)
}

@Test func 卡片不编造词典没给的信息() {
    let noPhonetic = VocabStore.DictionaryEntry(key: "x", lemma: nil, phonetic: "",
                                                zhDefinition: "n. 某物", enDefinition: "", pos: "")
    let card = VocabStore.formatCard(noPhonetic, input: "x", lookupCount: 1, saved: true)
    #expect(!card.contains("音标"), "词典没给音标就不该有音标那一节")
    #expect(!card.contains("English definition"), "空的英文释义不该占一节")
    #expect(card.contains("第 1 次查询（首次）"))

    // 写库失败时必须如实说没存上，不能先宣布"已加入生词本"。
    let failed = VocabStore.formatCard(noPhonetic, input: "x", lookupCount: 1, saved: false)
    #expect(failed.contains("未写入生词本"))
}

@Test func ECDICT的义项分隔符是字面反斜杠n() {
    // ECDICT 用**字面两个字符 `\n`** 分隔义项，不是真换行。
    // 这个坑在本项目里出现过三次（卡片、导出、生词本列表），所以只在一处解。
    #expect(VocabStore.unescape("n. 分布\\nv. 分配") == "n. 分布\nv. 分配")
}

@Test func 从exchange字段取得出原形() {
    #expect(VocabStore.lemma(fromExchange: "0:go/1:p") == "go")
    #expect(VocabStore.lemma(fromExchange: "s:cats") == nil)
    #expect(VocabStore.lemma(fromExchange: "") == nil)
}

// MARK: - 设置与环境自检

@Test func 设置能存能读且往返一致() throws {
    var s = Settings()
    s.openAIModel = "gpt-4o-mini"
    s.subtitleFastResults = false
    s.openAIBaseURL = "http://localhost:11434/v1"
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(Settings.self, from: data)
    #expect(back == s)
}

@Test func 对话配没配得出来() {
    var s = Settings()
    #expect(!s.chatConfigured, "什么都没填时不该去发一轮注定失败的请求")
    s.openAIBaseURL = "https://api.example.com/v1"
    #expect(!s.chatConfigured, "只有地址没有模型名也不算配好")
    s.openAIModel = "gpt-4o-mini"
    #expect(s.chatConfigured)
}

@Test func 每一项缺失都有降级路径() {
    // 核心约束：不能有"缺了就整个不能用"的依赖。这条把它变成断言，
    // 而不是等别人装到自己机器上才发现。
    let report = DependencyReport.probe()
    #expect(!report.hasFatalGap, "存在无降级路径的依赖：\(report.summary)")
    for item in report.items {
        #expect(!item.degradation.isEmpty, "\(item.name) 没写清楚缺失时会怎样")
    }
}

/// 字幕存放位置可以在菜单栏改。**用户选的那一层就是根**——
/// 再往下拼一个 `subtitles` 会让"我明明选了这个文件夹"变成一件意外的事。
@Test func 字幕根目录跟着设置走() {
    var s = Settings()
    #expect(s.subtitleDirectory.lastPathComponent == "subtitles", "没设过就用默认位置")

    s.subtitleRoot = "/tmp/pet-subtitles"
    #expect(s.subtitleDirectory.path == "/tmp/pet-subtitles", "选过就原样用，不再拼一层")

    s.subtitleRoot = "~/Documents/subtitles"
    #expect(s.subtitleDirectory.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path),
            "~ 要展开，否则会在当前目录下建一个名叫 ~ 的文件夹")

    s.subtitleRoot = "   "
    #expect(s.subtitleDirectory.lastPathComponent == "subtitles", "全是空格等于没设")
}

/// 老版本存下的 settings.json 没有新加的键，读出来不能整份退回默认值——
/// 否则每加一个设置项，用户选过的存放目录、笔记门槛就被静默清掉。
@Test func 设置缺新字段时保留已存的值() throws {
    let old = #"{"subtitleRoot": "/tmp/subs", "notesMinMinutes": 10, "subtitleSource": "system"}"#
    let s = try #require(Settings.decodeTolerant(Data(old.utf8)))
    #expect(s.subtitleRoot == "/tmp/subs")
    #expect(s.notesMinMinutes == 10)
    #expect(s.usesSystemAudio)
    #expect(s.subtitleFontSize == "medium" && s.subtitleFontPoints == 16)
    #expect(s.chatCollapsed == false)
}
