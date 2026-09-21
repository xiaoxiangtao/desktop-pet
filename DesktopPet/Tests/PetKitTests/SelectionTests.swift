import Testing
import AppKit
@testable import SelectionKit

/// 文本清洗是划词最容易出问题的一层：选中一整段结果拿去当单词查、
/// 或者选中一堆标点也去查，都在这里挡掉。纯函数，所以能测。
@Test func 清洗选中文本() {
    #expect(SelectionReader.clean("  hello  ") == "hello")
    #expect(SelectionReader.clean("multi\n  line\ttext") == "multi line text", "空白要规整成单空格")
    #expect(SelectionReader.clean("") == nil)
    #expect(SelectionReader.clean("   \n  ") == nil)
    #expect(SelectionReader.clean("——，。！") == nil, "纯标点查了也没意义")
    #expect(SelectionReader.clean("123 456") == nil, "纯数字同理")
    #expect(SelectionReader.clean("第 3 章") == nil, "查词只查英文，带汉字的一律不处理")
    #expect(SelectionReader.clean(String(repeating: "a", count: 500)) == nil, "过长的要丢掉")
    #expect(SelectionReader.clean(String(repeating: "a", count: 200))?.count == 200, "刚好到上限还算数")
}

/// 划到一整段话不是查词意图，是划错了。字符上限拦不住——一段话常常还不到 200 字，
/// 于是查词失败后落到 LLM，变成一次没人想要的 Hermes 对话（用户实测报的问题）。
@Test func 划到一整段就不查了() {
    #expect(SelectionReader.clean("distribution") != nil, "单词是查词的主场景")
    #expect(SelectionReader.clean("machine learning") != nil, "两个词是词组，照查")
    #expect(SelectionReader.clean("state of art") != nil, "三个词是上限，还算数")
    #expect(SelectionReader.clean("the state of the art") == nil, "四个词就超了")
    #expect(SelectionReader.clean("The distribution of wealth is uneven") == nil, "一整句话不处理")

    #expect(SelectionReader.wordCount("hello world") == 2)
    #expect(SelectionReader.wordCount("state of art") == 3)
}

/// 查词查的是英文（词典是 ECDICT），中文选区查不出东西，走到最后只会落到 LLM
/// 变成一次没人想要的对话。所以带中日韩文字的一概不处理，浮标也不会弹。
@Test func 中文不查词() {
    #expect(SelectionReader.clean("分布") == nil)
    #expect(SelectionReader.clean("这是一整段中文说明") == nil)
    #expect(SelectionReader.clean("distribution 分布") == nil, "混排多半是划错了边界")
    #expect(SelectionReader.clean("こんにちは") == nil, "日文同理")
    #expect(SelectionReader.clean("안녕하세요") == nil, "韩文同理")
    #expect(SelectionReader.clean("distribution") != nil, "英文不受影响")
}

/// ⌘C 兜底会改写剪贴板，**必须连类型一起原样恢复**——用户剪贴板里可能是图片或
/// 富文本，只恢复纯文本等于把它毁了。
@Test func 剪贴板快照要保住所有类型() {
    let pb = NSPasteboard(name: NSPasteboard.Name("pet.test.\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }

    pb.clearContents()
    let item = NSPasteboardItem()
    item.setData("纯文本".data(using: .utf8)!, forType: .string)
    item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)   // 假装是张图
    pb.writeObjects([item])

    let snapshot = SelectionReader.snapshot(pb)
    #expect(snapshot.count == 1)
    #expect(snapshot[0][.string] != nil)
    #expect(snapshot[0][.png] != nil, "非文本类型也要进快照，否则恢复时会被抹掉")

    // 模拟 ⌘C 把剪贴板冲掉
    pb.clearContents()
    pb.setString("被覆盖了", forType: .string)
    #expect(pb.data(forType: .png) == nil)

    SelectionReader.restore(snapshot, to: pb)
    #expect(pb.string(forType: .string) == "纯文本")
    #expect(pb.data(forType: .png) == Data([0x89, 0x50, 0x4E, 0x47]), "图片必须原样回来")
}

@Test func 空剪贴板恢复后仍是空的不报错() {
    let pb = NSPasteboard(name: NSPasteboard.Name("pet.test.\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    pb.clearContents()
    let snapshot = SelectionReader.snapshot(pb)
    pb.setString("垃圾", forType: .string)
    SelectionReader.restore(snapshot, to: pb)
    #expect(pb.string(forType: .string) == nil)
}

/// 用户报的：在笔记里划中 `summarize_subtitle_to_notes.py`，查词浮标冒了出来。
/// 它不含空格，按词数算就是"一个词"，前面每道闸都拦不住。
@Test func 代码与文件名不该触发查词() {
    for s in ["summarize_subtitle_to_notes.py", "notes.zh.md", "__init__",
              "np.array", "SelectionReader", "camelCase", "utf8", "CA6003",
              "src/main.swift", "foo()", "a==b", "#include", "100%"] {
        #expect(SelectionReader.clean(s) == nil, "该挡掉：\(s)")
    }
}

/// 别挡过头——这些都是正经的查词对象。
@Test func 正常英文词照查不误() {
    for s in ["demographic", "demographic.", "back-propagation", "state-of-the-art",
              "don't", "data governance", "New York"] {
        #expect(SelectionReader.clean(s) != nil, "不该挡：\(s)")
    }
}
