import Foundation
import AVFoundation
import PetCore

/// 字幕服务：把音源、转写引擎、落盘串起来，对外只有 start/stop 和一条字幕流。
///
/// 设计上是**进程级单例**（旧版的教训：挂在每个会话上会导致多窗口起多份模型）。
@available(macOS 26.0, *)
public actor SubtitleService {
    public private(set) var isRunning = false
    /// 只收定稿，用于收尾时写 SRT。草稿会被后续结果改写，留着没意义。
    private var finalLines: [SubtitleLine] = []
    private var source: AudioSource?
    private var engine: SpeechAnalyzerEngine?
    private var writer: SubtitleWriter?
    private var recorder: AudioRecorder?
    private var pump: Task<Void, Never>?
    private var startedAt = Date()

    public init() {}

    /// 字幕流给 UI 用。每次 start 会换一条新的。
    public private(set) var lines: AsyncStream<SubtitleLine>?

    /// 本次会话的产物目录，供后续加工（主题归纳、术语校正）定位文件。
    public private(set) var sessionDirectory: URL?

    public enum StartError: LocalizedError {
        case engineUnavailable
        case audioFailed(String)

        public var errorDescription: String? {
            switch self {
            case .engineUnavailable:
                return "系统语音识别不可用——可能是该语种的模型资产没装"
            case .audioFailed(let why):
                return "麦克风打不开：\(why)"
            }
        }
    }

    /// `onProgress` 报启动进度。**启动不是一瞬间的事**：模型资产冷启要几秒，
    /// 中间没有任何反馈的话按钮按下去就像没反应。
    /// 旧版把后端分阶段上报的这些消息显示在气泡的状态行上，这里保留同样的形态——
    /// 所以是开放文本而不是一个进度百分比。
    public func start(source newSource: AudioSource, locale: String = "en-US",
                      outputDirectory: URL,
                      saveAudio: Bool = true,
                      onProgress: (@Sendable (String) -> Void)? = nil)
        async throws -> AsyncStream<SubtitleLine> {
        if isRunning { await stop() }

        onProgress?("正在加载语音模型…")
        guard let engine = await SpeechAnalyzerEngine.make(locale: locale) else {
            throw StartError.engineUnavailable
        }
        await engine.start()

        // 格式不匹配 SpeechAnalyzer 会**静默不出文本**，所以必须转。
        guard let converter = FormatConverter(from: newSource.format, to: engine.analyzerFormat) else {
            throw StartError.audioFailed("建不了格式转换器")
        }

        let writer = SubtitleWriter(directory: outputDirectory)
        try? writer.prepare()

        // 音频与字幕写同一个目录。录的是**转换后**的分析器格式（16k 单声道），
        // 正好是 whisper 想要的输入，以后做二次转译不用再转一遍。
        let recorder = saveAudio ? AudioRecorder(directory: outputDirectory) : nil
        recorder?.start(format: engine.analyzerFormat)

        onProgress?(newSource is MicrophoneSource ? "正在打开麦克风…" : "正在连接系统音频…")
        do {
            try newSource.start { chunk in
                guard let converted = converter.convert(chunk.buffer) else { return }
                let out = AudioChunk(converted)
                recorder?.write(out)          // 同一份转换结果，喂识别和落盘共用
                Task { await engine.feed(out) }
            }
        } catch {
            throw StartError.audioFailed(error.localizedDescription)
        }

        self.source = newSource
        self.engine = engine
        self.writer = writer
        self.recorder = recorder
        self.sessionDirectory = outputDirectory
        self.startedAt = Date()
        self.finalLines = []
        self.isRunning = true

        let (out, cont) = AsyncStream<SubtitleLine>.makeStream()
        pump = Task { [weak self] in
            for await line in engine.lines {
                cont.yield(line)
                await self?.record(line)
            }
            cont.finish()
        }
        lines = out
        Log.info("字幕已启动：\(locale)，落盘 \(outputDirectory.path)")
        return out
    }

    private func record(_ line: SubtitleLine) {
        guard line.stage == .final else { return }
        finalLines.append(line)
        writer?.append(line, wallClock: Date().timeIntervalSince(startedAt))
        // **SRT 每来一条就重写一次，不能只在 stop() 时写。**
        // 实测：进程被杀（睡眠 / 崩溃 / 忘了点停止）时整节课的 SRT 全部丢失，
        // 而 jsonl 因为是追加写的反而完好。SRT 全量重写的代价对一节课的量级
        // （几百条）可以忽略，换来的是任何时刻断电都有一份完整文件。
        try? writer?.writeSRT(finalLines)
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        source?.stop()
        source = nil
        recorder?.stop()
        recorder = nil
        await engine?.finish()
        engine = nil
        pump?.cancel()
        pump = nil
        if let writer { try? writer.writeSRT(finalLines) }

        // 收尾：把整场字幕整理成中文笔记。**不在这里等**——这一步要几分钟，
        // 而这条路径是用户点「停止字幕」走的，卡住就是界面假死。
        let minutes = Date().timeIntervalSince(startedAt) / 60
        let settings = Settings.load()
        if let dir = sessionDirectory {
            if !settings.notesAutoRun {
                Log.info("自动做笔记已关（菜单栏「字幕设置」），只存档")
            } else if minutes < settings.notesMinMinutes {
                Log.info("字幕只有 \(Int(minutes)) 分钟，不到 \(Int(settings.notesMinMinutes)) 分钟的门槛，只存档")
            } else {
                NotesWriter.launch(directory: dir, settings: settings)
            }
        }
        Log.info("字幕已停止，共 \(finalLines.count) 条定稿")
        writer = nil
    }
}
