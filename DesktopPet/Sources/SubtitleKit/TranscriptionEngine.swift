import Foundation
import AVFoundation

/// 一条字幕。`stage` 区分草稿与定稿——UI 必须做**双态文本**（未确认灰 / 已确认白）：
/// 从"每 5.85 秒突然蹦一整段"变成"边说边流动"，是数量级的主观差异。
public struct SubtitleLine: Sendable, Equatable {
    public enum Stage: String, Sendable { case volatile, final }
    public let stage: Stage
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(stage: Stage, text: String, start: TimeInterval, end: TimeInterval) {
        self.stage = stage
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 一块音频的**所有权移交**。
///
/// `AVAudioPCMBuffer` 不是 `Sendable`（Swift 6 严格并发会直接拒绝跨 actor 传），
/// 但在这条链路上它确实是安全的：采集回调造出 buffer 后立刻交出去、自己再也不碰，
/// 消费端也不会把它发回去。`@unchecked` 在这里标注的就是这条纪律，
/// 不是"我懒得处理"——一旦哪天有人把同一个 buffer 同时喂给两条轨，这条注释就是失效点。
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// 转写引擎。抽成协议是为了让实时轨（SpeechAnalyzer）与存档轨（whisper sidecar）
/// 能并排存在——方案定的双轨结构：实时轨要快、可改写；存档轨要准、可以慢。
public protocol TranscriptionEngine: Sendable {
    /// 喂一段 PCM。
    func feed(_ chunk: AudioChunk) async
    /// 输入结束，收尾。
    func finish() async
    /// 产出的字幕流。
    var lines: AsyncStream<SubtitleLine> { get }
}

/// 音源。抽成协议是为了让麦克风、系统音频、文件（测试用）可以互换。
public protocol AudioSource: Sendable {
    var format: AVAudioFormat { get }
    func start(_ sink: @escaping @Sendable (AudioChunk) -> Void) throws
    func stop()
}

/// 把任意采样率/声道的输入转成分析器要求的格式。
///
/// **格式不匹配时 SpeechAnalyzer 不报错、直接静默不出文本**——编译通过、运行无异常、
/// 一个字都没有。这是这套 API 最容易踩的坑（Stage 0 探针里踩过），所以必须转。
public final class FormatConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat

    public init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let c = AVAudioConverter(from: input, to: output) else { return nil }
        converter = c
        outFormat = output
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return nil }
        return out.frameLength > 0 ? out : nil
    }
}
