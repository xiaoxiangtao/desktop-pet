import Foundation

/// 所有路径的唯一来源。
///
/// **一个分发版绝不能把构建机的路径烧进二进制**——上一代 Electron 版就是那样
/// （构建时注入 `__PET_ROOT__` 绝对路径），换台机器直接失效。这里的做法是：
/// 从源码树跑（`swift run` / `swift test`）时用仓库目录，装好的 .app 一律走
/// Application Support，两条路径在同一个地方分叉，别处不需要知道自己在哪种模式下。
public enum Paths: Sendable {
    /// 从源码树跑时的仓库根；装好的 .app 为 nil。
    ///
    /// 靠 `#filePath` 反推，再用仓库根标志文件确认——**不能只看目录存在**：
    /// `#filePath` 在分发的二进制里仍然是构建机上的那串路径，不确认的话
    /// .app 会以为自己在源码树里、把数据写到一个别人机器上不存在的地方。
    public static var developmentRoot: URL? {
        let url = URL(fileURLWithPath: #filePath)          // …/DesktopPet/Sources/PetCore/Paths.swift
            .deletingLastPathComponent()                    // PetCore
            .deletingLastPathComponent()                    // Sources
            .deletingLastPathComponent()                    // DesktopPet
            .deletingLastPathComponent()                    // 仓库根
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(".desktop-pet-repo").path)
            ? url : nil
    }

    public static let bundleID = "app.desktoppet.DesktopPet"

    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    /// ECDICT 英汉词典（只读，向导里下载安装，约 100 MB）。
    public static var dictionary: URL {
        applicationSupport.appendingPathComponent("ecdict.sqlite3")
    }

    /// 生词本。用户查过的词就存在这里，几十 KB。
    public static var vocabularyDB: URL {
        applicationSupport.appendingPathComponent("vocabulary.sqlite3")
    }

    public static var logs: URL {
        developmentRoot?.appendingPathComponent("log")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/\(bundleID)")
    }

    public static var chatHistory: URL {
        (developmentRoot?.appendingPathComponent("data") ?? applicationSupport)
            .appendingPathComponent("chat_history", isDirectory: true)
    }

    /// 首次运行向导有没有走完。走完之前每次启动都会把向导摆到用户面前。
    public static var onboardingMarker: URL {
        applicationSupport.appendingPathComponent("onboarded")
    }
}
