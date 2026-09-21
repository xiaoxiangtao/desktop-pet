import Testing
import Foundation
@testable import VocabKit

/// ECDICT 的 CSV 里既有逗号也有引号，还有跨行的释义。
/// **按行 split 再按逗号 split 会做出几万条错位的词条，而且完全不报错**——
/// 所以解析器必须自己钉住。
@Test func CSV解析扛得住引号逗号和转义() {
    var parser = CSVParser(text: """
        word,phonetic,translation
        'hood,hʊd,"n. 罩；风帽\\nv. 覆盖"
        's Gravenhage,",skrɑ:vən'hɑ:ɡə",[荷兰语]海牙(= Hague)
        say,seɪ,"他说 \"\"好\"\" 然后走了"
        """)
    #expect(parser.nextRow() == ["word", "phonetic", "translation"])
    #expect(parser.nextRow() == ["'hood", "hʊd", "n. 罩；风帽\\nv. 覆盖"])
    // 音标字段本身以逗号开头且被引号包着——不处理引号的话这一行会多切出一列。
    #expect(parser.nextRow() == ["'s Gravenhage", ",skrɑ:vən'hɑ:ɡə", "[荷兰语]海牙(= Hague)"])
    // 引号内的 "" 是一个字面引号，不是字段结束。
    #expect(parser.nextRow() == ["say", "seɪ", #"他说 "好" 然后走了"#])
    #expect(parser.nextRow() == nil)
}

@Test func CSV解析保留空字段() {
    var parser = CSVParser(text: "a,,c\n")
    #expect(parser.nextRow() == ["a", "", "c"])
}

/// 列按**名字**取，不写死下标——ECDICT 加过列，写死下标会静默错位。
@Test func 建库按列名取值且拒绝明显不完整的下载() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dict-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let csv = dir.appendingPathComponent("tiny.csv")
    let db = dir.appendingPathComponent("out.sqlite3")
    // 故意把列序打乱，且带上我们用不到的列。
    try """
        definition,word,frq,translation,exchange,phonetic,pos
        a happy accident,serendipity,3000,n. 机缘巧合,,ˌserənˈdɪpɪti,n
        moved fast,ran,9000,run的过去式,0:run/1:p,ræn,v
        """.write(to: csv, atomically: true, encoding: .utf8)

    let installer = DictionaryInstaller()
    // 只有两行，低于"像是下载不完整"的门槛，必须拒绝而不是建出一个半张表的库。
    await #expect(throws: (any Error).self) {
        try await installer.buildDatabase(from: csv, to: db) { _ in }
    }
}

@Test func 建好的库查得到且带得出原形() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dict-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // 凑够行数越过"下载不完整"的门槛，同时把列序打乱。
    var rows = ["definition,word,frq,translation,exchange,phonetic,pos"]
    rows.append("a happy accident,serendipity,3000,n. 机缘巧合,,ˌserənˈdɪpɪti,n")
    rows.append("moved fast,ran,9000,run的过去式,0:run/1:p,ræn,v")
    for i in 0..<10_100 { rows.append("filler \(i),filler\(i),0,填充,,,n") }
    let csv = dir.appendingPathComponent("big.csv")
    let db = dir.appendingPathComponent("out.sqlite3")
    try rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)

    try await DictionaryInstaller().buildDatabase(from: csv, to: db) { _ in }

    let store = VocabStore(dictionaryPath: db.path,
                           notebookPath: dir.appendingPathComponent("nb.sqlite3").path)
    #expect(store.dictionaryAvailable)
    let entry = try #require(store.lookUpDictionary("serendipity"))
    #expect(entry.zhDefinition == "n. 机缘巧合")
    #expect(entry.enDefinition == "a happy accident")
    #expect(entry.phonetic == "ˌserənˈdɪpɪti")
    // 大小写不敏感：用户输入 Serendipity 也得查得到。
    #expect(store.lookUpDictionary("Serendipity") != nil)
    // exchange 里的 `0:` 是原形。
    #expect(try #require(store.lookUpDictionary("ran")).lemma == "run")
}
