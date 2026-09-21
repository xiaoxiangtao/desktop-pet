import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation
import Speech

/// 四项 TCC 权限的状态与跳转。
///
/// **每一项都必须是可降级的**：麦克风没给就不能开字幕，但对话和查词照常；
/// 辅助功能没给就没有划词，其余不受影响。桌宠不做"不授权就不给用"这种事。
///
/// 两个反复踩到的事实：
/// 1. **裸二进制拿不到任何权限。** TCC 认的是 bundle 和它 Info.plist 里的用途说明，
///    没有 plist 时 macOS 直接拒绝而**不弹授权框**——表现是功能静默失灵、零报错。
///    所以必须打成 .app 跑，见 scripts/make_app.sh。
/// 2. **授权面板没法用代码勾选**，只能把用户送到那一页。所以每一项都带一个跳转 URL。
public enum Permission: String, CaseIterable, Sendable {
    case microphone
    case speechRecognition
    case screenRecording
    case accessibility

    public enum Status: Sendable, Equatable {
        case granted
        case denied
        case notDetermined      // 还没问过，第一次用到时系统会弹框

        public var isUsable: Bool { self == .granted }
    }

    public var title: String {
        switch self {
        case .microphone:        "麦克风"
        case .speechRecognition: "语音识别"
        case .screenRecording:   "屏幕与系统录音"
        case .accessibility:     "辅助功能"
        }
    }

    /// 给这项权限用来干什么，以及**不给会怎样**。第二句才是用户真正需要的信息。
    public var purpose: String {
        switch self {
        case .microphone:
            "把你正在听的英文转成实时字幕。不给：字幕功能不可用，对话和查词不受影响。"
        case .speechRecognition:
            "由 macOS 在本机把语音转成文字，音频不上传。不给：字幕功能不可用。"
        case .screenRecording:
            "采集电脑正在播放的声音（用来给视频、会议做字幕）。只取声音，不截画面。不给：字幕只能用麦克风。"
        case .accessibility:
            "读取你在任意 app 里划选的文字，用来划词查词。不给：划词查词不可用，在气泡里手动输入照样能查。"
        }
    }

    public var isRequired: Bool { false }   // 恒为 false：缺任何一项都不该让 app 整个不可用

    public var status: Status {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:    return .granted
            case .notDetermined: return .notDetermined
            default:             return .denied
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:    return .granted
            case .notDetermined: return .notDetermined
            default:             return .denied
            }
        case .screenRecording:
            // 这个 API 只回 Bool，问不出"还没问过"。没授权时统一当 notDetermined 处理，
            // 因为 CGRequestScreenCaptureAccess 在两种情况下都是对的下一步。
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        }
    }

    /// 发起授权。能弹系统框的就弹；只能去设置里勾的就打开那一页。
    /// 回调在主线程，带上请求后的新状态。
    @MainActor
    public func request(completion: @escaping @MainActor (Status) -> Void) {
        switch self {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in completion(self.status) }
            }
        case .speechRecognition:
            SFSpeechRecognizer.requestAuthorization { _ in
                Task { @MainActor in completion(self.status) }
            }
        case .screenRecording:
            // 这个请求会弹一次系统框，但**授权后必须重启 app 才生效**——
            // ScreenCaptureKit 的权限是进程启动时快照的。界面上要说清楚。
            _ = CGRequestScreenCaptureAccess()
            completion(status)
        case .accessibility:
            // 带 prompt 能弹一次引导框，但真正的勾选仍要用户去设置里做。
            // 常量名直接写字面量：`kAXTrustedCheckOptionPrompt` 是个可变全局，
            // 在 Swift 6 的并发检查下引用不了。它的值是稳定的公开约定。
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            completion(status)
        }
    }

    /// 系统设置里对应的那一页。
    public var settingsURL: URL {
        let anchor = switch self {
        case .microphone:        "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .screenRecording:   "Privacy_ScreenCapture"
        case .accessibility:     "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// 光发请求不够：屏幕录制和辅助功能都只能由用户在设置里手动勾选，
    /// 所以这两项发完请求还要把用户送到那一页（由 UI 层用 NSWorkspace 打开）。
    public var mustOpenSettingsToGrant: Bool {
        self == .screenRecording || self == .accessibility
    }

    /// 授权后是否必须重启 app 才生效。屏幕录制是唯一一个——ScreenCaptureKit
    /// 在进程启动时就把权限快照下来了，当场勾选不会让正在跑的进程看见。
    public var needsRestartAfterGranting: Bool { self == .screenRecording }
}

