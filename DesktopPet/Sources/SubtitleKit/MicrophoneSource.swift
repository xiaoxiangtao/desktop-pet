import Foundation
import AVFoundation
import PetCore

/// 麦克风采集。**用 `AVAudioEngine.inputNode.installTap`，不经 ffmpeg 管道。**
///
/// 旧版用 ffmpeg avfoundation 采集，实测**只拿到 85.9% 的音频**
/// （墙钟 334.4s / 音频时间轴 287.2s），而 `t_start` 是按收到的帧数算的，
/// 于是 **SRT 时间戳每分钟漂移约 8.4 秒**，一小时课差 8 分钟，存档因此不可用。
/// 走 AVAudioEngine 没有中间管道，也就没有丢样问题；时间戳用主机时钟锚定。
public final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    public let format: AVAudioFormat

    public init() {
        format = engine.inputNode.outputFormat(forBus: 0)
    }

    public func start(_ sink: @escaping @Sendable (AudioChunk) -> Void) throws {
        let node = engine.inputNode
        node.installTap(onBus: 0, bufferSize: 4096, format: node.outputFormat(forBus: 0)) { buffer, _ in
            sink(AudioChunk(buffer))
        }
        engine.prepare()
        try engine.start()
        Log.info("麦克风开始采集：\(Int(format.sampleRate))Hz / \(format.channelCount)ch")
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.info("麦克风停止采集")
    }
}
