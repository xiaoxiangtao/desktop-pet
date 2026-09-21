import Foundation
import AVFoundation
import Speech
import PetCore

/// 实时转写轨：Apple 的 `SpeechAnalyzer` + `SpeechTranscriber`。
///
/// 为什么换掉旧版的 mlx-whisper（[[分析音频识别卡顿与流式方案差距]] 的实测）：
/// 旧的不是流式识别，是"离线整段模型 + 5 秒定时切块"，单词级延迟 3.5~9.3 秒、
/// 屏幕刷新间隔 5.85 秒，且 GPU 占空比只有 16.8%——瓶颈不是算力，换芯片也不会变快。
/// SpeechAnalyzer 实测 RTF 0.020（whisper 0.137）、**单词级延迟均 0.55 秒**、
/// 零下载零内存（模型由系统管理，不占应用内存，对比 whisper 的 3.1GB 权重 + 556MB venv）。
///
/// **`.fastResults` 这个选项值 3.8 倍**：屏幕刷新 3.80s → 1.00s，定稿落后中位
/// 2.12s → 0.93s，单词级延迟均 1.75s → 0.55s。**而且准确率不降反升**
/// （默认模式把 "attend" 认成 "attain"，fast 下反而对）。所以默认开。
///
/// **术语偏置实测完全无效**：注入 8 个术语后输出逐字不变。`AnalysisContext.contextualStrings`
/// 这个 API 存在、`setContext()` 也不报错，但 SpeechTranscriber 不吃（只对
/// DictationTranscriber 生效）。所以旧版 `/字幕` + Hermes 提示词改写那一整套
/// **在这条路径上无法迁移，是净损失**——这条单独就足以支持保留 whisper 存档轨。
@available(macOS 26.0, *)
public actor SpeechAnalyzerEngine: TranscriptionEngine {
    public nonisolated let lines: AsyncStream<SubtitleLine>
    private let continuation: AsyncStream<SubtitleLine>.Continuation

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    public nonisolated let analyzerFormat: AVAudioFormat

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<Void, Never>?
    private var analysis: Task<Void, Never>?
    /// 有没有真的喂进去过音频。**0 采样会让 results 流永不结束、整个进程挂死**
    /// （探针里实测过：切片越界切出 0 秒 wav 时就是这个现象），所以收尾前要挡一下。
    private var fedAnyAudio = false

    public static func make(locale identifier: String = "en-US",
                            fastResults: Bool = true) async -> SpeechAnalyzerEngine? {
        let wanted = Locale(identifier: identifier)
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? wanted
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if fastResults { reporting.insert(.fastResults) }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reporting,
            // audioTimeRange 才会给出每段的音频时间轴，SRT 和延迟统计都靠它
            attributeOptions: [.audioTimeRange])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            Log.error("取不到分析用音频格式——该语种的模型资产可能没装")
            return nil
        }
        return SpeechAnalyzerEngine(transcriber: transcriber, format: format)
    }

    private init(transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzerFormat = format
        (lines, continuation) = AsyncStream<SubtitleLine>.makeStream()
    }

    public func start() {
        guard analysis == nil else { return }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = cont

        // **收结果的任务必须先起来**，否则 analyzeSequence 返回后 results 可能已经结束，
        // 于是一条字幕都收不到（探针里踩过）。
        collector = Task { [transcriber, continuation] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    continuation.yield(SubtitleLine(
                        stage: result.isFinal ? .final : .volatile,
                        text: text,
                        start: result.range.start.seconds,
                        end: result.range.end.seconds))
                }
            } catch {
                Log.error("字幕结果流出错：\(error)")
            }
            continuation.finish()
        }

        analysis = Task { [analyzer] in
            do { _ = try await analyzer.analyzeSequence(stream) }
            catch { Log.error("字幕分析失败：\(error)") }
        }
    }

    public func feed(_ chunk: AudioChunk) {
        guard chunk.buffer.frameLength > 0 else { return }
        fedAnyAudio = true
        inputContinuation?.yield(AnalyzerInput(buffer: chunk.buffer))
    }

    public func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        // 一点音频都没喂过就调 finalize 会挂住（见 fedAnyAudio 的注释）。
        if fedAnyAudio {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await analysis?.value
        collector?.cancel()
        continuation.finish()
    }
}
