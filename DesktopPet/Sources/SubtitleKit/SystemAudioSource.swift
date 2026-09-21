import Foundation
import AVFoundation
import ScreenCaptureKit
import PetCore

/// 系统音频采集：录**电脑自己在放的声音**（看视频、开会），而不是麦克风。
///
/// **为什么不用 BlackHole**（旧方案的路线）：那是个虚拟声卡驱动，pkg 安装要管理员密码、
/// caveats 明写必须重启电脑、还要手动配多输出设备，装完**菜单栏音量键失效**、
/// 蓝牙偶发不同步。用系统 API 就不需要用户装任何东西。
///
/// **为什么先做 ScreenCaptureKit 而不是 CoreAudio 进程 Tap**：方案里进程 Tap 是首选
/// （权限更窄、能按进程选音源），但它的权限模型和稳定性**尚未实测**（方案风险 R5）。
/// SCK 的音频采集文档完善、行为稳定，先用它把功能打通；进程 Tap 留作后续优化，
/// 换掉它只需要再实现一次这个协议，上层不用动——这正是 `AudioSource` 抽象的用处。
///
/// 代价：SCK 要屏幕录制权限，而且会让系统出现"正在录制"指示器。
@available(macOS 13.0, *)
public final class SystemAudioSource: NSObject, AudioSource, @unchecked Sendable {
    /// SCK 固定按这个格式给音频；分析器那边再统一转换。
    public let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private var stream: SCStream?
    private var sink: (@Sendable (AudioChunk) -> Void)?
    private let queue = DispatchQueue(label: "pet.system-audio")

    public func start(_ sink: @escaping @Sendable (AudioChunk) -> Void) throws {
        self.sink = sink
        // SCStream 的装配是异步的，但协议是同步的：失败通过日志 + 没有音频体现出来。
        // 上层的"开始字幕"按钮会因为收不到任何字幕而让用户察觉，这比在这里抛一个
        // 用户看不懂的错误好——真正的失败原因（没授权屏幕录制）写在日志里。
        Task { [weak self] in
            do { try await self?.configureAndStart() }
            catch { Log.error("系统音频采集启动失败（多半是没授予屏幕录制权限）：\(error)") }
        }
    }

    private func configureAndStart() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            Log.error("找不到可采集的显示器")
            return
        }
        // 只要音频。filter 必须给一个 display，但内容我们不取。
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true    // 别把桌宠自己的声音录进去
        config.sampleRate = Int(format.sampleRate)
        config.channelCount = Int(format.channelCount)
        // 视频那路开到最小：SCK 要求有视频轨，但我们一帧都不要。
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("系统音频采集已启动（ScreenCaptureKit）")
    }

    public func stop() {
        let s = stream
        stream = nil
        sink = nil
        Task { try? await s?.stopCapture(); Log.info("系统音频采集已停止") }
    }
}

@available(macOS 13.0, *)
extension SystemAudioSource: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, let sink, sampleBuffer.isValid,
              let buffer = Self.pcmBuffer(from: sampleBuffer, format: format) else { return }
        sink(AudioChunk(buffer))
    }

    /// CMSampleBuffer → AVAudioPCMBuffer。
    static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription?.audioStreamBasicDescription,
              let sourceFormat = AVAudioFormat(streamDescription: [description].withUnsafeBufferPointer { $0.baseAddress! })
        else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames
        do {
            try sample.copyPCMData(fromRange: 0..<Int(frames), into: buffer.mutableAudioBufferList)
        } catch {
            return nil
        }
        return buffer
    }
}
