import AppKit
import PetCore

/// 菜单栏里的「字幕设置」子菜单：存放位置 + 自动做笔记的开关与时长门槛。
///
/// **每次打开都重建**（`menuNeedsUpdate`），不缓存菜单项状态。设置存在磁盘上，
/// 可能被别的地方（或用户手改 JSON）改掉；缓存一份就会显示成过期的勾。
///
/// 单独成文件是因为 `AppCoordinator` 已经很长了，而这里的东西自成一块：
/// 读设置 → 画菜单 → 写设置，跟宠物、气泡、字幕都不耦合。
@MainActor
final class SubtitleSettingsMenu: NSObject, NSMenuDelegate {
    /// 门槛的备选值（分钟）。0 = 每次都做。给固定档位而不是让用户输数字——
    /// 菜单里没有输入框，而这个值也不需要精确到分钟。
    private static let thresholds: [Double] = [0, 10, 20, 30, 60]
    private static let sources = [("microphone", "麦克风"), ("system", "系统音频（视频、网课、会议里对方的声音）")]
    private static let fontSizes = [("small", "小（14）"), ("medium", "中（16）"), ("large", "大（18）")]

    let menuItem = NSMenuItem(title: "字幕设置", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        let sub = NSMenu()
        sub.delegate = self
        menuItem.submenu = sub
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = Settings.load()
        menu.removeAllItems()

        // —— 存放位置
        menu.addItem(header("字幕存放位置"))
        let path = settings.subtitleDirectory.path
        let where_ = NSMenuItem(title: abbreviate(path), action: nil, keyEquivalent: "")
        where_.isEnabled = false
        where_.toolTip = path                       // 悬停能看到完整路径
        menu.addItem(where_)
        menu.addItem(item("更改…", #selector(chooseDirectory)))
        if !settings.subtitleRoot.isEmpty {
            menu.addItem(item("恢复默认位置", #selector(resetDirectory)))
        }
        menu.addItem(item("在访达中打开", #selector(revealDirectory)))

        // —— 音源：二选一。**正在跑的那场不切**——换源要重建整条采集链，下次开字幕时生效。
        menu.addItem(.separator())
        menu.addItem(header("字幕音源（下次开字幕时生效）"))
        for (key, title) in Self.sources {
            let row = item(title, #selector(pickSource(_:)))
            row.representedObject = key
            row.state = settings.subtitleSource == key ? .on : .off
            menu.addItem(row)
        }

        // —— 字号：当场生效
        menu.addItem(.separator())
        menu.addItem(header("字幕字号"))
        for (key, title) in Self.fontSizes {
            let row = item(title, #selector(pickFontSize(_:)))
            row.representedObject = key
            row.state = settings.subtitleFontSize == key ? .on : .off
            menu.addItem(row)
        }

        // —— 自动做笔记
        menu.addItem(.separator())
        menu.addItem(header("字幕结束后自动做笔记"))
        let toggle = item("自动做笔记", #selector(toggleAutoRun))
        toggle.state = settings.notesAutoRun ? .on : .off
        menu.addItem(toggle)

        for minutes in Self.thresholds {
            let title = minutes == 0 ? "每次都做" : "只有超过 \(Int(minutes)) 分钟才做"
            let row = item(title, #selector(pickThreshold(_:)))
            row.representedObject = minutes
            row.state = settings.notesMinMinutes == minutes ? .on : .off
            row.isEnabled = settings.notesAutoRun   // 关掉自动时这几档没有意义
            menu.addItem(row)
        }
    }

    /// PET_DUMP_MENU=1 时把子菜单的内容打进日志。
    /// **菜单没法截图自查**（要真人点开），所以留一条能在无人值守下验证的路径：
    /// 它走的是 `menuNeedsUpdate` 本身，不是另写一份逻辑。
    func dumpIfAsked() {
        guard ProcessInfo.processInfo.environment["PET_DUMP_MENU"] == "1",
              let sub = menuItem.submenu else { return }
        menuNeedsUpdate(sub)
        Log.info("字幕设置菜单：")
        for i in sub.items {
            let mark = i.state == .on ? "✓" : (i.isSeparatorItem ? "—" : " ")
            Log.info("  \(mark) \(i.isSeparatorItem ? "――――" : i.title)\(i.isEnabled || i.isSeparatorItem ? "" : "（灰）")")
        }
    }

    // MARK: - 动作

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选这里"
        panel.message = "以后每场字幕会在这个文件夹下新建一个会话目录"
        panel.directoryURL = Settings.load().subtitleDirectory
        // 这是个 LSUIElement 应用（不进 Dock），不先激活的话面板会开在别人后面。
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var settings = Settings.load()
        settings.subtitleRoot = url.path
        settings.save()
        Log.info("字幕存放位置改为 \(url.path)")
        notifyNextSession("字幕存放位置已改为\n\(url.path)")
    }

    @objc private func resetDirectory() {
        var settings = Settings.load()
        settings.subtitleRoot = ""
        settings.save()
        Log.info("字幕存放位置恢复默认：\(settings.subtitleDirectory.path)")
        notifyNextSession("已恢复默认位置\n\(settings.subtitleDirectory.path)")
    }

    @objc private func revealDirectory() {
        let dir = Settings.load().subtitleDirectory
        // 目录可能还没建（一次字幕都没开过），先建出来，否则访达会弹"找不到"。
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    @objc private func toggleAutoRun() {
        var settings = Settings.load()
        settings.notesAutoRun.toggle()
        settings.save()
        Log.info("字幕结束后自动做笔记：\(settings.notesAutoRun ? "开" : "关")")
    }

    @objc private func pickSource(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var settings = Settings.load()
        settings.subtitleSource = key
        settings.save()
        Log.info("字幕音源改为 \(key)")
    }

    @objc private func pickFontSize(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var settings = Settings.load()
        settings.subtitleFontSize = key
        settings.save()
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
        Log.info("字幕字号改为 \(key)")
    }

    @objc private func pickThreshold(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Double else { return }
        var settings = Settings.load()
        settings.notesMinMinutes = minutes
        settings.save()
        Log.info("做笔记的时长门槛改为 \(Int(minutes)) 分钟")
    }

    // MARK: - 小工具

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    /// 长路径在菜单里会把菜单撑得很宽，中间省略掉。完整路径留在 toolTip 里。
    private func abbreviate(_ path: String, keep: Int = 46) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        guard short.count > keep else { return short }
        return short.prefix(keep / 2) + "…" + short.suffix(keep / 2)
    }

    /// **改了位置不影响正在跑的那场**——它的目录在开始时就定了。
    /// 这件事不说清楚，用户会以为改完当场就生效。
    private func notifyNextSession(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "下次开字幕时生效"
        alert.informativeText = text + "\n\n正在进行的字幕仍然写在原来的目录里。"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
