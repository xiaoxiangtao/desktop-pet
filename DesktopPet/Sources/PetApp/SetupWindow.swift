import AppKit
import PetCore
import Providers
import VocabKit

/// 首次运行向导，同时也是常驻的设置页（菜单栏「设置…」打开的是同一个窗口）。
///
/// 三件事，按用户真正需要的顺序排：
/// 1. **对话 API** —— 不配这个猫就不会说话，所以放第一个，且带「测试连接」当场验证。
/// 2. **系统权限** —— 逐项显示状态和"不给会怎样"，一项一个按钮。
/// 3. **词典** —— 可选的 100 MB 下载，查词才需要。
///
/// 两条设计约束：
/// - **向导里没有一步是必须完成的。** 每一项缺失都有明确的降级路径（见
///   `DependencyReport`），所以「先用着」永远是可选项，不做"不配完不让进"。
/// - **窗口要能抢到焦点。** app 是 `.accessory`（不进 Dock、不抢焦点），
///   而设置窗口需要键盘输入，所以打开时显式 `activate(ignoringOtherApps:)`，
///   否则用户点得到输入框却打不进字。
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    // 对话
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let testButton = NSButton()
    private let testResult = NSTextField(labelWithString: "")
    private let providerPopUp = NSPopUpButton()
    private let hermesRow = NSStackView()
    private let hermesField = NSTextField()

    // 权限
    private var permissionRows: [Permission: PermissionRow] = [:]

    // 词典
    private let dictStatus = NSTextField(labelWithString: "")
    private let dictButton = NSButton()
    private let dictProgress = NSProgressIndicator()
    private var installTask: Task<Void, Never>?

    /// 向导走完（或用户点了「先用着」）时回调，协调器据此重建对话后端。
    var onFinish: (() -> Void)?

    // MARK: - 打开

    func show() {
        if let window {
            refresh()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 尺寸是按内容量定的：640×780 刚好让三节加「完成」按钮都在首屏里。
        // 更矮的话第 3 节和按钮会被挤到滚动区外，用户以为向导只有两步（踩过）。
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "桌宠设置"
        w.delegate = self
        w.isReleasedWhenClosed = false       // 关了还要能再打开，不能连同对象一起释放
        w.contentView = buildContent()
        w.center()
        window = w
        refresh()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        dumpIfAsked()
    }

    /// `PET_DUMP_SETUP=<路径>`：把设置页渲染成 PNG。
    ///
    /// 这是本项目的一条工作方式——**先让程序自己把结果导出成可看的东西**，
    /// 而不是改完让用户去看。设置页尤其需要：它是别人装上之后见到的第一屏，
    /// 而 accessory 应用的窗口在自动化里既截不到也列不出来。
    func dumpIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["PET_DUMP_SETUP"],
              let root = window?.contentView else { return }
        // 布局要先跑完，否则拍到的是所有控件都堆在左上角的那一帧。
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        Log.info("设置页已导出：\(path)")
    }

    func windowWillClose(_ notification: Notification) {
        installTask?.cancel()
        save()
        onFinish?()
    }

    // MARK: - 布局

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionTitle("1　对话"))
        stack.addArrangedSubview(hint("猫要说话得有个模型。填一个 OpenAI 兼容的服务地址即可——官方 API、\n中转站、本机跑的 Ollama / LM Studio 都认这个协议。"))
        stack.addArrangedSubview(providerRow())
        stack.addArrangedSubview(field("服务地址", baseURLField, placeholder: "https://api.openai.com/v1"))
        stack.addArrangedSubview(field("模型名", modelField, placeholder: "gpt-4o-mini"))
        stack.addArrangedSubview(field("API 密钥", apiKeyField, placeholder: "本机模型可留空"))
        stack.addArrangedSubview(hermesRowView())
        stack.addArrangedSubview(testRow())

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("2　系统权限"))
        stack.addArrangedSubview(hint("一项都不给也能用，只是对应功能不可用。授权面板不能由程序代勾，\n点按钮会把你送到系统设置的那一页。"))
        for permission in Permission.allCases {
            let row = PermissionRow(permission: permission) { [weak self] in
                self?.grant(permission)
            }
            permissionRows[permission] = row
            stack.addArrangedSubview(row.view)
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("3　词典（可选）"))
        stack.addArrangedSubview(hint("下载 ECDICT 英汉词典后，聊天里发一个英文单词、或在任意 app 里划选一个词，\n猫会直接给出释义并记进生词本。约 66 MB 下载、100 MB 落盘，全部离线。"))
        stack.addArrangedSubview(dictRow())

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(footer())

        // **文档视图必须是翻转的。** AppKit 的坐标原点在左下，内容比视口矮时
        // NSStackView 会贴着底边排，顶上空出一大块——看起来像是界面坏了。
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        // 宽度钉死在 clipView 上，否则内容会自由撑宽、多出一条横向滚动条。
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        return scroll
    }

    private func sectionTitle(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    private func hint(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    /// 「右对齐标签 + 控件」这一种行。三段宽度写死是有意的：
    /// 所有行的控件左缘必须对齐，让 NSStackView 各自算会参差不齐。
    private func labeled(_ title: String, _ control: NSView, into row: NSStackView = NSStackView()) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        control.widthAnchor.constraint(equalToConstant: 368).isActive = true
        row.orientation = .horizontal
        row.spacing = 10
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        return row
    }

    private func field(_ title: String, _ control: NSTextField, placeholder: String) -> NSView {
        control.placeholderString = placeholder
        control.font = .systemFont(ofSize: 12)
        return labeled(title, control)
    }

    private func providerRow() -> NSView {
        providerPopUp.addItems(withTitles: ["OpenAI 兼容 API", "Hermes Agent CLI（本机已装才选）"])
        providerPopUp.target = self
        providerPopUp.action = #selector(providerChanged)
        return labeled("后端", providerPopUp)
    }

    private func hermesRowView() -> NSView {
        hermesField.placeholderString = "~/.local/bin/hermes"
        hermesField.font = .systemFont(ofSize: 12)
        return labeled("hermes 路径", hermesField, into: hermesRow)
    }

    private func testRow() -> NSView {
        testButton.title = "测试连接"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testConnection)
        testResult.font = .systemFont(ofSize: 11)
        testResult.lineBreakMode = .byTruncatingTail
        testResult.widthAnchor.constraint(equalToConstant: 400).isActive = true
        let row = NSStackView(views: [spacer(94), testButton, testResult])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    private func dictRow() -> NSView {
        dictButton.bezelStyle = .rounded
        dictButton.target = self
        dictButton.action = #selector(toggleDictionaryInstall)
        dictStatus.font = .systemFont(ofSize: 11)
        dictProgress.style = .bar
        dictProgress.isIndeterminate = false
        dictProgress.minValue = 0
        dictProgress.maxValue = 1
        dictProgress.isHidden = true
        dictProgress.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let row = NSStackView(views: [spacer(94), dictButton, dictProgress, dictStatus])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    private func footer() -> NSView {
        let done = NSButton(title: "完成", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let note = NSTextField(labelWithString: "设置随时可以从菜单栏的猫 →「设置…」再打开。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let row = NSStackView(views: [note, done])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func spacer(_ width: CGFloat) -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    // MARK: - 状态

    private func refresh() {
        let settings = Settings.load()
        providerPopUp.selectItem(at: settings.chatProvider == ProviderRegistry.hermesCLI ? 1 : 0)
        baseURLField.stringValue = settings.openAIBaseURL
        modelField.stringValue = settings.openAIModel
        // 密钥从钥匙串读回来填进去，用户才能看出"已经配过了"。
        apiKeyField.stringValue = Keychain.chatAPIKey ?? ""
        hermesField.stringValue = settings.hermesBinary
        updateProviderVisibility()
        for (permission, row) in permissionRows { row.update(status: permission.status) }
        updateDictionaryRow()
    }

    private func updateProviderVisibility() {
        let usesHermes = providerPopUp.indexOfSelectedItem == 1
        hermesRow.isHidden = !usesHermes
        for view in [baseURLField, modelField, apiKeyField] {
            view.isEnabled = !usesHermes
        }
    }

    private func updateDictionaryRow() {
        let store = VocabStore()
        if store.dictionaryAvailable {
            dictButton.title = "重新下载"
            dictStatus.stringValue = "已安装（\(DependencyReport.sizeText(store.dictionaryPath))）"
            dictStatus.textColor = .secondaryLabelColor
        } else {
            dictButton.title = "下载词典"
            dictStatus.stringValue = "未安装，查词不可用"
            dictStatus.textColor = .secondaryLabelColor
        }
    }

    // MARK: - 动作

    @objc private func providerChanged() {
        updateProviderVisibility()
        testResult.stringValue = ""
    }

    private func currentSettings() -> Settings {
        var s = Settings.load()
        s.chatProvider = providerPopUp.indexOfSelectedItem == 1 ? ProviderRegistry.hermesCLI : ProviderRegistry.openAI
        s.openAIBaseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        s.openAIModel = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        s.hermesBinary = NSString(string: hermesField.stringValue.trimmingCharacters(in: .whitespaces))
            .expandingTildeInPath
        return s
    }

    private func save() {
        currentSettings().save()
        // 密钥单独进钥匙串。清空输入框 = 删掉存着的那把。
        Keychain.chatAPIKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func testConnection() {
        save()
        testButton.isEnabled = false
        testResult.textColor = .secondaryLabelColor
        testResult.stringValue = "正在连接…"
        let settings = currentSettings()
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        Task {
            let health = await ProviderRegistry.test(settings: settings, apiKey: key.isEmpty ? nil : key)
            await MainActor.run {
                self.testButton.isEnabled = true
                switch health {
                case .ready:
                    self.testResult.textColor = .systemGreen
                    self.testResult.stringValue = "✓ 连上了，可以聊天了"
                case .unavailable(let why):
                    self.testResult.textColor = .systemRed
                    self.testResult.stringValue = "✗ \(why)"
                }
            }
        }
    }

    private func grant(_ permission: Permission) {
        permission.request { [weak self] status in
            guard let self else { return }
            // 屏幕录制和辅助功能只能由用户自己在设置里勾，请求完还要把人送过去。
            if permission.mustOpenSettingsToGrant, !status.isUsable {
                NSWorkspace.shared.open(permission.settingsURL)
            }
            self.permissionRows[permission]?.update(status: permission.status)
            if permission.needsRestartAfterGranting, permission.status.isUsable {
                self.permissionRows[permission]?.note("授权后需要重开桌宠才生效")
            }
        }
    }

    @objc private func toggleDictionaryInstall() {
        if let task = installTask {
            task.cancel()
            installTask = nil
            dictButton.title = "下载词典"
            dictProgress.isHidden = true
            dictStatus.stringValue = "已取消"
            return
        }
        dictButton.title = "取消"
        dictProgress.isHidden = false
        dictProgress.doubleValue = 0
        dictStatus.stringValue = "准备下载…"
        installTask = Task {
            do {
                try await DictionaryInstaller().install { progress in
                    Task { @MainActor in
                        self.dictStatus.stringValue = progress.stage
                        if let fraction = progress.fraction {
                            self.dictProgress.isIndeterminate = false
                            self.dictProgress.doubleValue = fraction
                        } else if !self.dictProgress.isIndeterminate {
                            // 导入阶段不知道总行数，换成走马灯比一个卡住的进度条诚实。
                            self.dictProgress.isIndeterminate = true
                            self.dictProgress.startAnimation(nil)
                        }
                    }
                }
                await MainActor.run {
                    self.dictProgress.stopAnimation(nil)
                    self.dictProgress.isHidden = true
                    self.installTask = nil
                    self.updateDictionaryRow()
                }
            } catch {
                await MainActor.run {
                    self.dictProgress.stopAnimation(nil)
                    self.dictProgress.isHidden = true
                    self.installTask = nil
                    self.dictButton.title = "重试"
                    self.dictStatus.textColor = .systemRed
                    self.dictStatus.stringValue = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    @objc private func finish() {
        save()
        try? Data().write(to: Paths.onboardingMarker)
        window?.close()
    }
}

/// 原点在左上的容器。滚动视图的文档视图要用它，理由见 `buildContent()`。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 权限列表里的一行：名字 + 状态 + 一个按钮 + 一句"不给会怎样"。
@MainActor
private final class PermissionRow {
    let view = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let button = NSButton()
    private let noteLabel = NSTextField(labelWithString: "")
    private let onGrant: () -> Void

    init(permission: Permission, onGrant: @escaping () -> Void) {
        self.onGrant = onGrant

        let name = NSTextField(labelWithString: permission.title)
        name.font = .systemFont(ofSize: 12)
        name.widthAnchor.constraint(equalToConstant: 120).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true

        button.bezelStyle = .rounded
        button.title = "去授权"
        button.target = self
        button.action = #selector(tapped)

        // 用途和降级后果写在同一行的尾巴上，用户不必去 README 里找。
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.stringValue = permission.purpose
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.toolTip = permission.purpose
        noteLabel.widthAnchor.constraint(equalToConstant: 300).isActive = true

        view.orientation = .horizontal
        view.spacing = 8
        view.addArrangedSubview(name)
        view.addArrangedSubview(statusLabel)
        view.addArrangedSubview(button)
        view.addArrangedSubview(noteLabel)
    }

    @objc private func tapped() { onGrant() }

    func update(status: Permission.Status) {
        switch status {
        case .granted:
            statusLabel.stringValue = "✓ 已授权"
            statusLabel.textColor = .systemGreen
            button.isHidden = true
        case .denied:
            statusLabel.stringValue = "✗ 被拒绝"
            statusLabel.textColor = .systemRed
            button.title = "去设置"
            button.isHidden = false
        case .notDetermined:
            statusLabel.stringValue = "未授权"
            statusLabel.textColor = .secondaryLabelColor
            button.title = "去授权"
            button.isHidden = false
        }
    }

    func note(_ text: String) {
        noteLabel.stringValue = text
        noteLabel.textColor = .systemOrange
    }
}

