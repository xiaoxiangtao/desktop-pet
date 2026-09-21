import Foundation
import AVFoundation
import PetCore

/// 把字幕会话的音频存下来。
///
/// **为什么要存**：实时轨（SpeechAnalyzer）听完即弃，一旦想回头用 whisper 重转一遍
/// 就没有源了。存下来之后，「二次转译 + 校正」这类离线加工才有可能。
///
/// **边采边写，不在内存里攒**：两小时的课约 230MB，攒在内存里会把这台 16GB 的机器
/// 直接压垮。`AVAudioFile` 每次 write 都落盘，进程被杀也只丢最后一个 buffer。
///
/// **存的是转换后的 16k 单声道**，不是麦克风原始的 48k：
/// - whisper 本来就要 16k，存原始格式等于存了一份还得再转的数据
/// - 体积差 3 倍（16bit 16k 单声道 ≈ 1.9MB/分钟，48k 立体声 ≈ 11MB/分钟）
public final class AudioRecorder: @unchecked Sendable {
    public let url: URL
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var failed = false
    /// 上次修补 WAV 头的时刻。
    private var lastHeaderPatch = Date.distantPast
    /// 每隔多久把头补一次。10 秒：崩溃最多丢 10 秒的"可播放性"（数据本身不丢）。
    private static let headerPatchInterval: TimeInterval = 10

    public init(directory: URL, name: String = "audio.wav") {
        self.url = directory.appendingPathComponent(name)
    }

    /// 按分析器的格式建文件。**以 16bit 整型落盘**而不是 Float32——
    /// 体积减半，而语音识别用不到 Float32 的动态范围。
    public func start(format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            // commonFormat 传分析器那个格式，AVAudioFile 会在写入时自动转成 16bit。
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: format.commonFormat, interleaved: false)
            Log.info("音频开始录制：\(url.lastPathComponent)（\(Int(format.sampleRate))Hz/\(format.channelCount)ch/16bit）")
        } catch {
            failed = true
            // 录音失败**不能拖垮字幕**——字幕是主功能，录音是为了以后加工。
            Log.error("音频文件创建失败，本次不录音：\(error)")
        }
    }

    public func write(_ chunk: AudioChunk) {
        lock.lock(); defer { lock.unlock() }
        guard let file, !failed else { return }
        do {
            try file.write(from: chunk.buffer)
        } catch {
            failed = true            // 只记一次，否则一秒几十条日志
            Log.error("音频写入失败，停止录音（字幕不受影响）：\(error)")
            return
        }
        if Date().timeIntervalSince(lastHeaderPatch) >= Self.headerPatchInterval {
            lastHeaderPatch = Date()
            Self.patchWAVHeader(at: url)
        }
    }

    /// 周期性把 WAV 头里的长度字段补成当前文件的真实大小。
    ///
    /// **为什么必须做**：`AVAudioFile` 只在**释放时**才回填 RIFF/data 的长度字段。
    /// 进程被杀（睡眠 / 崩溃 / 忘了点停止）时头里的 data 大小停在 0，
    /// 于是播放器和 whisper 都把它当成空文件——**数据其实完好，只是没人认**。
    /// 实测：546KB、17.1 秒、RMS 399 的真实录音，`afinfo` 报 duration 0.000000。
    ///
    /// 补头是幂等的：只改两个 4 字节整数，不碰音频数据；正常 stop() 时
    /// AVAudioFile 自己再写一遍也是同样的值。
    static func patchWAVHeader(at url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 44 else { return }

        // **必须扫描块结构，不能硬编码偏移。**
        // `AVAudioFile` 写的不是教科书里那个 44 字节头：它在偏移 12 处插了一个
        // 28 字节的 `JUNK` 块（给 RF64 升级预留的空间），于是 `data` 块被推到了
        // 偏移 48 之后。我第一版按 40 去补，结果补进了别的块里，
        // `afinfo` 照样报 duration 0.000000（实测踩到）。
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 4), head == Data("RIFF".utf8) else { return }

        func writeUInt32(_ value: UInt32, at offset: UInt64) {
            var v = value.littleEndian
            try? handle.seek(toOffset: offset)
            try? handle.write(contentsOf: Data(bytes: &v, count: 4))
        }
        func readUInt32(at offset: UInt64) -> UInt32? {
            try? handle.seek(toOffset: offset)
            guard let d = try? handle.read(upToCount: 4), d.count == 4 else { return nil }
            return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }

        writeUInt32(UInt32(size - 8), at: 4)          // RIFF 块大小，位置是固定的

        var offset: UInt64 = 12                        // 跳过 "RIFF" size "WAVE"
        while offset + 8 <= size {
            try? handle.seek(toOffset: offset)
            guard let id = try? handle.read(upToCount: 4), id.count == 4,
                  let chunkSize = readUInt32(at: offset + 4) else { return }
            if id == Data("data".utf8) {
                writeUInt32(UInt32(size - offset - 8), at: offset + 4)
                return
            }
            // 块要按偶数对齐
            offset += 8 + UInt64(chunkSize) + UInt64(chunkSize % 2)
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard file != nil else { return }
        file = nil                   // AVAudioFile 释放时收尾写 WAV 头
        Self.patchWAVHeader(at: url)  // 再补一次，确保任何路径下头都是对的
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        Log.info("音频已保存：\(url.lastPathComponent)（\(String(format: "%.1f", Double(size) / 1_048_576)) MB）")
    }

    /// 已写入的时长（秒）。给"攒够多少内容再归纳主题"那套逻辑用。
    public var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
