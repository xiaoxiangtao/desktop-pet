import Testing
import Foundation
@testable import SubtitleKit

/// 落盘这一层是旧版**100% 失败**的地方（7 次真实麦克风运行 stream.jsonl 全是 0 字节），
/// 而且当时根因都没定位到。所以这次把格式化做成纯函数、写入只有一处，并且断言真的写出了东西。

@Test func SRT时间戳格式正确且跨小时进位() {
    #expect(SubtitleWriter.timestamp(0) == "00:00:00,000")
    #expect(SubtitleWriter.timestamp(1.5) == "00:00:01,500")
    #expect(SubtitleWriter.timestamp(61.25) == "00:01:01,250")
    #expect(SubtitleWriter.timestamp(3661.007) == "01:01:01,007")
    // 一小时以上必须进位到小时位——上课场景是主用例，两小时的课很常见
    #expect(SubtitleWriter.timestamp(7325.5) == "02:02:05,500")
    #expect(SubtitleWriter.timestamp(-3) == "00:00:00,000", "负数不能算出乱码时间戳")
}

@Test func SRT只收定稿并按序编号() {
    let lines = [
        SubtitleLine(stage: .volatile, text: "草稿会被改写", start: 0, end: 1),
        SubtitleLine(stage: .final, text: "Hello there", start: 0, end: 1.2),
        SubtitleLine(stage: .final, text: "", start: 1.2, end: 1.3),        // 空的要丢掉
        SubtitleLine(stage: .final, text: "second line", start: 1.3, end: 2.5),
    ]
    let srt = SubtitleWriter.srt(from: lines)
    let expected = """
    1
    00:00:00,000 --> 00:00:01,200
    Hello there

    2
    00:00:01,300 --> 00:00:02,500
    second line

    """
    #expect(srt == expected, "实际输出：\n\(srt)")
    #expect(!srt.contains("草稿会被改写"), "草稿会被后续结果改写，不能进存档")
    // 空文本那条不能占编号，所以最大编号是 2（不能用 contains("3") 判——时间戳里有 3）
    #expect(!srt.contains("\n3\n"), "空文本不该占一个编号")
}

@Test func JSONL只记定稿() {
    let draft = SubtitleLine(stage: .volatile, text: "draft", start: 0, end: 1)
    #expect(SubtitleWriter.jsonLine(draft, wallClock: 1) == nil, "草稿记下来会被改写，还把文件撑大")

    let final = SubtitleLine(stage: .final, text: "done", start: 1, end: 2)
    let line = try! #require(SubtitleWriter.jsonLine(final, wallClock: 3.5))
    let obj = try! JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
    #expect(obj["text"] as? String == "done")
    #expect(obj["t_start"] as? Double == 1)
    #expect(obj["wall"] as? Double == 3.5)
}

@Test func 落盘真的写得出非空内容() throws {
    // 旧版就是在这一步静默失败的，所以这条测试直接断言文件非空。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("subs-\(UUID().uuidString)")
    let writer = SubtitleWriter(directory: dir)
    try writer.prepare()
    defer { try? FileManager.default.removeItem(at: dir) }

    let lines = [
        SubtitleLine(stage: .final, text: "first", start: 0, end: 1),
        SubtitleLine(stage: .final, text: "second", start: 1, end: 2),
    ]
    for (i, l) in lines.enumerated() { writer.append(l, wallClock: Double(i)) }
    try writer.writeSRT(lines)

    let jsonl = try String(contentsOf: writer.jsonlURL, encoding: .utf8)
    #expect(jsonl.split(separator: "\n").count == 2, "两条定稿应当写出两行，实际：\(jsonl.count) 字符")
    #expect(!jsonl.isEmpty, "stream.jsonl 不能是 0 字节——这正是旧版的老毛病")

    let srt = try String(contentsOf: writer.srtURL, encoding: .utf8)
    #expect(srt.contains("first") && srt.contains("second"))
}

@Test func WAV头被周期性补齐才能在崩溃后仍可播放() throws {
    // AVAudioFile 只在释放时回填 RIFF/data 的长度字段。进程被杀时头里写着 0，
    // 播放器和 whisper 都会把它当空文件——数据完好却没人认。
    // 实测过：546KB / 17.1 秒 / RMS 399 的真实录音，afinfo 报 duration 0.000000。
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wavpatch-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    // **按 AVAudioFile 真实写出的布局造样本**：它在偏移 12 处插了一个 28 字节的
    // JUNK 块（给 RF64 预留），data 块因此被推到偏移 48。
    // 第一版测试按教科书的 44 字节头造样本，于是硬编码偏移的实现"测试通过、
    // 真机失效"——这条注释就是为了不让那个洞再开一次。
    var bytes = [UInt8]()
    bytes += Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)      // 0..12
    bytes += Array("JUNK".utf8) + [28, 0, 0, 0] + [UInt8](repeating: 0, count: 28)  // 12..48
    bytes += Array("fmt ".utf8) + [16, 0, 0, 0] + [UInt8](repeating: 1, count: 16)  // 48..72
    bytes += Array("data".utf8) + [0, 0, 0, 0]                            // 72..80，size 故意写 0
    let headerLength = bytes.count
    bytes += [UInt8](repeating: 3, count: 1000)
    try Data(bytes).write(to: url)

    AudioRecorder.patchWAVHeader(at: url)

    let patched = try Data(contentsOf: url)
    let riff = patched[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    // data 的 size 字段在 data 标识之后 4 字节（本布局里是 76..80）
    let dataSizeOffset = headerLength - 4
    let dataSize = patched[dataSizeOffset..<(dataSizeOffset + 4)]
        .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    #expect(riff == UInt32(patched.count - 8), "RIFF 块大小应为 文件长 - 8")
    #expect(dataSize == 1000, "data 块大小应为真实音频字节数，实际 \(dataSize)")
    #expect(patched.count == headerLength + 1000, "补头不能改动音频数据的长度")
}

@Test func 补头是幂等的() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wavidem-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    var bytes = [UInt8](repeating: 7, count: 44 + 500)
    bytes.replaceSubrange(0..<4, with: Array("RIFF".utf8))
    try Data(bytes).write(to: url)
    AudioRecorder.patchWAVHeader(at: url)
    let once = try Data(contentsOf: url)
    AudioRecorder.patchWAVHeader(at: url)
    #expect(try Data(contentsOf: url) == once, "补两次结果应当一致")
}

/// 喂给模型之前要先把 SRT 剥成纯文本。**去重是必需的**：实时字幕的定稿行之间
/// 常有重叠（同一句被修正后再发一次），不去重就是在花钱买重复的笔记要点。
@Test func SRT剥成纯文本并去掉相邻重复() {
    let srt = """
        1
        00:00:00,000 --> 00:00:03,000
        So today we will look at cross entropy

        2
        00:00:03,000 --> 00:00:06,000
        So today we will look at cross entropy

        3
        00:00:06,000 --> 00:00:09,000
        and how it relates to maximum likelihood
        """
    let plain = NotesWriter.stripSRT(srt)
    #expect(!plain.contains("-->"), "时间戳行要去掉")
    #expect(!plain.contains("00:00"), "序号和时间都不该留下")
    #expect(plain == "So today we will look at cross entropy and how it relates to maximum likelihood")
}

/// 长文要切块，但**不能在句子中间断开**——断句处切开的半句会让那一块的要点跑偏。
@Test func 长文按句子边界切块() {
    let sentence = "This is a reasonably long sentence about something. "
    let text = String(repeating: sentence, count: 400)
    let chunks = NotesWriter.split(text, limit: 2000)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.hasSuffix(".") }, "每块都该收在句号上")
    // 内容不能在切块时丢掉。
    #expect(chunks.joined().filter { $0 == "." }.count == text.filter { $0 == "." }.count)
}

@Test func 短文不切块() {
    #expect(NotesWriter.split("One short sentence.", limit: 2000).count == 1)
}
