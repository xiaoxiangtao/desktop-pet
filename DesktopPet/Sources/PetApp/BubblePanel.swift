import AppKit
import PetCore
import VocabKit
import SubtitleKit

/// 气泡：回复展示 + 输入框 + 动作按钮行。独立的一个 NSPanel，位置跟着猫走。
///
/// 与猫面板分开的好处（方案 §2.6）：气泡需要键盘焦点（`canBecomeKey = true`），
/// 猫不需要（点猫不该抢焦点）。旧版两者共用一张全屏透明窗，只能整窗二选一，
/// 于是输入法候选框会被压到透明覆盖层下面——拆成两个面板后这个问题不存在了。
///
/// **所有尺寸都是用 CDP 从旧版运行中的界面上量出来的**，不是照截图目测、也不是从
/// Chakra 的间距刻度反推的。那两条路我都走过，都差一截：按钮高度差 5px（20 vs 25）、
/// 卡片内边距差 1px（12 vs 13，CSS 的 padding 不含 border）、阴影更是完全两回事。
/// CDP 是本项目排查前端问题的标准手段（`open -a 桌宠.app --args --remote-debugging-port=9222`）。
final class BubblePanel: NSPanel, NSWindowDelegate {
    // MARK: - 旧版实测值（CDP 读的 computed style / getBoundingClientRect）

    static let cardWidth: CGFloat = 400
    /// 卡片边缘到内容块的距离。CSS 是 padding 12 + border 1，实测子元素 left/top 都是 13。
    private static let cardInset: CGFloat = 13
    /// 块与块之间，实测 input.top −(msg.top + msg.h) = 8。
    private static let blockGap: CGFloat = 8
    /// 每块自身还有 px:'1' 的内缩，所以文字实际从卡片边缘 13+4 = 17 开始。
    private static let innerInset: CGFloat = 4
    private static let cornerRadius: CGFloat = 20
    private static let inputHeight: CGFloat = 34
    private static let pillHeight: CGFloat = 25       // 实测 25，我上一版写的 20 太小
    private static let actionRowHeight: CGFloat = 29  // 25 + pt:'1'
    private static let messageMinHeight: CGFloat = 32
    private static let messageMaxHeight: CGFloat = 340
    /// 消息区要滚动时给滚动条让出的槽宽。overlay 滚动条展开后实测约 15pt，取 16 留 1pt 余量。
    private static let scrollerGutter: CGFloat = 16
    /// 状态行（"思考中…"）：旧版 `fontSize: xs` = 12px，行高 1.2 → 15，取 16。
    private static let statusHeight: CGFloat = 16
    private static let statusDotSize: CGFloat = 6
    /// 窗口要比卡片大一圈，给**自绘阴影**留地方。macOS 的 `hasShadow` 是一整套系统窗口
    /// 阴影，比 CSS 那两层淡阴影重得多，必须关掉自己画。
    private static let shadowMargin: CGFloat = 24
    private static let gapToPet: CGFloat = 6   // 实测旧版就是 6px，不是 8

    /// 白色覆盖层的不透明度。旧版是 0.92；用户要求"透明度调高一点"，
    /// 配合下面那层毛玻璃降到 0.72——低于这个值时，背后是深色窗口的情况下
    /// 正文对比度就不够了（气泡里的字是近黑的 rgb(24,24,27)，靠的是白底）。
    /// 想再调，改这一个数就够。
    private static let cardOpacity: CGFloat = 0.72

    private static let textColour = NSColor(red: 24/255, green: 24/255, blue: 27/255, alpha: 1)
    private static let pillColour = NSColor(red: 82/255, green: 82/255, blue: 91/255, alpha: 1)

    // MARK: - 视图

    /// 卡片底层是毛玻璃，上面再盖一层半透明白。
    ///
    /// 旧版是 `bg: rgba(255,255,255,0.92)` + `backdropFilter: blur(8px)`，我当时判断
    /// "白色占 92%，模糊只是很淡的一层底"就只做了半透明白。**那个省略在 0.92 下看不出来，
    /// 一旦调透就致命**——没有模糊，背后的窗口内容会清晰地透上来，字直接没法读。
    /// 所以要调透明度必须先把这层补上。
    private let blur = NSVisualEffectView()
    private let card = NSView()
    private let scroll = NSScrollView()
    private let transcript = NSTextView()
    private let input = CapsuleTextField()
    private let actionRow = NSStackView()
    /// 状态行：小圆点 + 灰字，夹在消息区和输入框之间。
    /// 旧版把"等回复"和"字幕启动进度"都放在这里——气泡里没有第二个能报状态的地方
    /// （窗口模式那盏连接指示灯随窗口模式一起没了）。
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// 生词本与对话共用消息区，互斥显示——旧版就是这么做的，气泡只有 400px，
    /// 再分一栏谁都放不下。
    let notebook = VocabNotebookView(frame: .zero)
    private var notebookOpen = false
    /// 字幕**自成一条带**，在气泡顶部，不跟回复挤在同一个区域。
    /// 旧版的结论：字幕每几秒来一行，跟 Hermes 的回复交错会互相把对方擦掉。
    private let subtitleBand = NSTextView()
    private let subtitleScroll = NSScrollView()
    private let subtitleDivider = NSView()
    private let subtitleHeader = NSTextField(labelWithString: "")
    private let notebookDivider = NSView()
    private let notebookHeader = NSTextField(labelWithString: "")
    private var subtitleOn = false
    private var subtitleCollapsed = false
    /// 最近三条定稿 + 当前草稿。草稿灰、定稿正常——**双态文本**是"突发变流动"的关键，
    /// 主观差异是数量级的（[[分析音频识别卡顿与流式方案差距]] 的结论之一）。
    private var subtitleFinals: [String] = []
    private var subtitleDraft = ""
    /// 字幕带高度。旧版 `subtitleBox.maxH = 150px`——我第一版给了 54px，太矮，
    /// 三行字幕根本放不下（用户报"字幕区域高度太低"）。
    private static let subtitleBandHeight: CGFloat = 150
    /// 收起对话后字幕带的高度：腾出来的地方全给字幕，与生词本带同高。
    private static let subtitleBandTallHeight: CGFloat = 260
    private var currentSubtitleBandHeight: CGFloat { chatCollapsed ? Self.subtitleBandTallHeight : Self.subtitleBandHeight }
    /// 对话区收起：只藏消息区，**输入框和按钮行保留**——收起后还要能查词、能说话。
    private var chatCollapsed = Settings.load().chatCollapsed
    /// 字幕字号（菜单「字幕设置」三档）。缓存在这里而不是每次渲染读盘：草稿一秒刷好几次。
    private var subtitleFontPoints = CGFloat(Settings.load().subtitleFontPoints)
    private var settingsObserver: NSObjectProtocol?
    /// 生词本带比字幕带高——旧版注释的原话："字幕那条只显示 3 行，这个是要扫读的列表"。
    /// 实测 `vocabBox.maxH = 260px`。
    private static let notebookBandHeight: CGFloat = 260
    /// 两条带的头部：小号大写灰字（`fontSize 2xs / gray.500 / letterSpacing .04em`）。
    private static let bandHeaderHeight: CGFloat = 14

    /// 每次打开轮换一条。**每条都必须带"回车"**——气泡没有发送按钮，
    /// 占位语是这个操作唯一被写下来的地方。压在 12 字内，再长会被截断。
    private static let placeholders = [
        "跟猫说点什么，回车发送",
        "说吧，它假装没在等，回车",
        "猫耳朵动了一下，回车发送",
        "它在等，但不会承认，回车",
        "喵？说点什么，回车发送",
        "有事说事，回车发送",
    ]
    private var placeholderIndex = Int.random(in: 0..<placeholders.count)

    /// 猫自己先开口，气泡就不会以一个空输入框的样子出现。
    /// **刻意不是一个真实轮次**：不发后端、不写聊天记录，所以不花延迟、不花 token。
    private static let greeting = "喵～"

    enum Role { case cat, user }

    var onSubmit: ((String) -> Void)?
    var onNewConversation: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onResized: (() -> Void)?

    private var isEmptyConversation = true
    /// 消息区里现在摆的是不是那句问候语——它不是一个真实轮次，用户一开口就该让位。
    private var showingGreeting = false
    /// 字幕启动/收尾的阶段文案，空串表示没有这回事。与 `isThinking` 共用状态行。
    private var subtitleStatus = ""
    /// 等回复期间不收起——否则点一下别处，正在跑的那一轮就看不到结果了。
    private var isThinking = false
    /// 点到别处收起，靠全局鼠标监听而不是只靠 `windowDidResignKey`：
    /// 这是个 `.nonactivatingPanel`，点其它 app 时不一定可靠地失去 key
    /// （点一个同样不抢焦点的窗口就完全不触发）。鼠标事件的全局监听**不需要**
    /// 辅助功能授权（只有键盘事件需要），所以这条兜底没有权限成本。
    private var clickOutsideMonitor: Any?
    /// 猫的位置，用来判断"点的是不是猫"——点猫要交给猫自己的 toggle 处理，
    /// 不能在这里先收起，否则一次点击被处理两遍，气泡关了又开。
    var petFrameProvider: (() -> CGRect)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0,
                                       width: Self.cardWidth + Self.shadowMargin * 2, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // 系统阴影太重，自己画
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate = self
        // **卡片是硬编码的白底，所以整个面板必须锁成浅色外观。**
        // 否则系统处于深色模式时，凡是没被我显式上色的东西都会取深色下的语义色——
        // 占位文字用的 placeholderTextColor 在深色下接近白色，落在白卡片上就是看不见
        // （用户报的"沉底字是白色"）。滚动条、选中高亮同理。
        appearance = NSAppearance(named: .aqua)
        buildContent()
        resizeToFitContent()
        // 菜单里改字号要当场生效，不用等下次开字幕。
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    private func applySettings() {
        let s = Settings.load()
        subtitleFontPoints = CGFloat(s.subtitleFontPoints)
        if subtitleOn { subtitleHeader.stringValue = Self.subtitleHeaderText() }
        renderSubtitles()
        resizeToFitContent()
    }

    private static func subtitleHeaderText() -> String {
        "字幕 · \(Settings.load().usesSystemAudio ? "系统音频" : "麦克风") · 自动识别语言"
    }

    /// 气泡要能拿到键盘焦点（输入框要打字），但**不能激活整个 app**——
    /// `.nonactivatingPanel` + `canBecomeKey` 这对组合就是为这个场景准备的。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - 构建

    private func buildContent() {
        let root = NSView()
        contentView = root

        // 毛玻璃底。`.behindWindow` 才会去模糊**窗口背后**的东西；
        // `.withinWindow` 只模糊同窗口内的内容，在这里等于什么都不做。
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Self.cornerRadius
        blur.layer?.masksToBounds = true
        root.addSubview(blur)

        card.wantsLayer = true
        if let layer = card.layer {
            // 旧版 radius 20、border 1px rgba(0,0,0,0.06)；白底透明度见 cardOpacity
            layer.backgroundColor = NSColor.white.withAlphaComponent(Self.cardOpacity).cgColor
            layer.cornerRadius = Self.cornerRadius
            layer.borderWidth = 1
            layer.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
            // CSS: 0 4px 12px -2px rgba(0,0,0,.10), 0 1px 3px rgba(0,0,0,.05)
            // CALayer 只有一层阴影，取主的那层：12px 模糊 ≈ radius 6，向下偏 4。
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.10
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: -4)   // AppKit y 轴向上，CSS 的下偏是负
            layer.masksToBounds = false
        }
        root.addSubview(card)

        buildTranscript()
        buildInput()
        buildActionRow()
        buildSubtitleBand()
        notebook.isHidden = true
        subtitleScroll.isHidden = true
        for d in [subtitleDivider, notebookDivider] {
            d.wantsLayer = true
            d.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
            d.isHidden = true
        }
        for h in [subtitleHeader, notebookHeader] {
            h.font = .systemFont(ofSize: 10, weight: .regular)
            h.textColor = NSColor(white: 0.44, alpha: 1)      // gray.500
            h.isHidden = true
        }
        buildStatusRow()
        for v in [subtitleScroll, subtitleHeader, subtitleDivider,
                  notebook, notebookHeader, notebookDivider,
                  scroll, statusDot, statusLabel, input, actionRow] { card.addSubview(v) }
    }

    private func buildStatusRow() {
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = Self.statusDotSize / 2
        // 气泡是浅色卡片，圆点必须是深色调——旧版注释记着这条：
        // 这里用 whiteAlpha 的那一版在白底上等于没画。
        statusDot.layer?.backgroundColor = Self.placeholderColour.cgColor   // gray.400
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Self.pillColour                             // gray.600
        statusDot.isHidden = true
        statusLabel.isHidden = true
    }

    private func buildSubtitleBand() {
        subtitleBand.isEditable = false
        subtitleBand.isSelectable = true
        subtitleBand.drawsBackground = false
        subtitleBand.textContainerInset = .zero
        subtitleScroll.documentView = subtitleBand
        subtitleScroll.drawsBackground = false
        subtitleScroll.hasVerticalScroller = false
        subtitleScroll.autohidesScrollers = true
    }

    /// 收到一条字幕。草稿只替换当前那条，定稿才推进历史。
    func appendSubtitle(_ line: SubtitleLine) {
        switch line.stage {
        case .final:
            subtitleDraft = ""
            subtitleFinals.append(line.text)
            // 平时只留最近三行；收起对话后字幕带更高，多留几行免得上半截空着
            let keep = chatCollapsed ? 8 : 3
            if subtitleFinals.count > keep { subtitleFinals.removeFirst(subtitleFinals.count - keep) }
        case .volatile:
            subtitleDraft = line.text
        }
        renderSubtitles()
    }

    /// 字幕行距。**小字号裸排会糊成一块**（用户报"排版太密"）：字幕是扫读的，
    /// 行与行之间要有能落眼的空隙。字号改成三档（14/16/18）后行高取 1.5，再加 2px 段间距
    /// 把"上一句/这一句"分开。改这两个数就够。
    private static let subtitleLineHeight: CGFloat = 1.5
    private static let subtitleParagraphGap: CGFloat = 2

    private func renderSubtitles() {
        let body = NSMutableAttributedString()
        let layout: NSParagraphStyle = {
            let s = NSMutableParagraphStyle()
            s.lineHeightMultiple = Self.subtitleLineHeight
            s.paragraphSpacing = Self.subtitleParagraphGap
            return s
        }()
        let settled: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: subtitleFontPoints),
            .foregroundColor: Self.textColour,
            .paragraphStyle: layout,
        ]
        let draft: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: subtitleFontPoints),
            // 未确认的用灰色：用户一眼能看出哪些还会被改写
            .foregroundColor: NSColor(white: 0.62, alpha: 1),
            .paragraphStyle: layout,
        ]
        for (i, line) in subtitleFinals.enumerated() {
            body.append(NSAttributedString(string: i == 0 ? line : "\n" + line, attributes: settled))
        }
        if !subtitleDraft.isEmpty {
            let prefix = body.length == 0 ? "" : "\n"
            body.append(NSAttributedString(string: prefix + subtitleDraft, attributes: draft))
        }
        subtitleBand.textStorage?.setAttributedString(body)
        subtitleBand.scrollToEndOfDocument(nil)
    }

    /// 消息区的段落样式。**对齐方式必须显式写死为 `.natural`**：
    /// 查词卡片是多段中英混排，一旦这块文字被两端对齐，AppKit 会把每行不足的宽度
    /// 摊到空格上——用户看到的就是"字间距好大"（一行只放得下 35 个字符，
    /// 剩下 100px 全变成了词与词之间的空隙）。
    private static let messageParagraphStyle: NSParagraphStyle = {
        let s = NSMutableParagraphStyle()
        s.lineHeightMultiple = 1.6          // 实测 line-height 22.4px = 14 × 1.6
        s.alignment = .natural
        s.lineBreakMode = .byWordWrapping
        return s
    }()

    /// 消息区的完整文字属性。**不要再用 `transcript.string =` 走 typingAttributes**——
    /// 那条路上字体、字距、对齐都可能被运行环境改掉（同一份文本在不同机器上
    /// 排版不一致就是这么来的），显式属性串才能保证两处渲染一模一样。
    private static func messageAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 14),
         .foregroundColor: textColour,
         .kern: 0,                          // 归零，挡掉任何继承来的字距
         .paragraphStyle: messageParagraphStyle]
    }

    /// 制表符在卡片里从来不是有意的（查词卡片全是空格分隔），但一旦混进来，
    /// AppKit 会按 28pt 一档的默认制表位排，看上去就是"空格被撑开了"。
    private func setTranscript(_ text: String) {
        let clean = text.replacingOccurrences(of: "\t", with: " ")
        transcript.textStorage?.setAttributedString(
            NSAttributedString(string: clean, attributes: Self.messageAttributes()))
    }

    private func buildTranscript() {
        transcript.isEditable = false
        transcript.isSelectable = true          // 回复要可复制
        transcript.drawsBackground = false
        transcript.textContainerInset = .zero
        transcript.font = .systemFont(ofSize: 14)
        transcript.textColor = Self.textColour
        transcript.defaultParagraphStyle = Self.messageParagraphStyle
        scroll.documentView = transcript
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
    }

    /// 占位文字色。**这个值是从旧版渲染结果上量出来的，不是从 CSS 反推的。**
    ///
    /// 踩过的坑：CDP 读 `::placeholder` 返回的是正文色（Chrome 不通过那个伪元素暴露
    /// 真实占位色），我只好从源码里的 `gray.400` 反推，用了 **Chakra v2** 的
    /// `#A0AEC0` = rgb(160,174,192)——那是个**蓝调**灰。而旧版跑的是 **v3**，
    /// 它的 gray 是中性的（zinc 系）。实测旧版笔画 rgb(157,157,166)、
    /// 我那版 rgb(159,173,192)，蓝通道高了 33，用户一眼看出"颜色发蓝"。
    /// 教训：**颜色要从渲染结果上采样，不要从设计令牌名反推**——同名令牌跨大版本会变。
    private static let placeholderColour = NSColor(red: 161/255, green: 161/255, blue: 170/255, alpha: 1)

    /// 占位文字**必须显式上色**：`placeholderString` 走系统的 placeholderTextColor，
    /// 那是个随外观变化的语义色，深色模式下接近白色，落在白卡片上就看不见了。
    private func setPlaceholder(_ text: String) {
        input.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: Self.placeholderColour,
        ])
    }

    private func buildInput() {
        setPlaceholder(Self.placeholders[placeholderIndex])
        input.font = .systemFont(ofSize: 14)
        input.textColor = Self.textColour
        input.isBordered = false
        input.drawsBackground = false           // 背景由 layer 画，否则方形底盖住圆角
        input.focusRingType = .none             // 一打开就自动聚焦，蓝框只是噪音
        input.wantsLayer = true
        input.layer?.cornerRadius = Self.inputHeight / 2
        input.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
        input.layer?.borderWidth = 1
        input.layer?.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
        (input.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        input.delegate = self
    }

    /// 输入框下面那排小胶囊。旧版注释：用文字不用图标，因为气泡没有别的地方挂含义。
    private func buildActionRow() {
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.alignment = .centerY
        // 按功能分组排：字幕（开始/收起）｜对话（新对话/收起）｜生词本。
        // 组内 8pt、组间 16pt——光靠顺序分不出组，间距要比组内大一档才看得出来。
        subtitlePill = pill("开始字幕", enabled: true, action: #selector(toggleSubtitle)) as? PillButton
        collapsePill = pill("收起字幕", enabled: false, action: #selector(toggleCollapse)) as? PillButton
        let newChat = pill("新对话", enabled: true, action: #selector(newConversation))
        chatPill = pill(chatCollapsed ? "展开对话" : "收起对话", enabled: true, action: #selector(toggleChat)) as? PillButton
        notebookPill = pill("生词本", enabled: false, action: #selector(toggleNotebook)) as? PillButton
        let groups: [[NSView?]] = [[subtitlePill, collapsePill], [newChat, chatPill], [notebookPill]]
        for group in groups {
            let views = group.compactMap { $0 }
            views.forEach { actionRow.addArrangedSubview($0) }
            if let last = views.last { actionRow.setCustomSpacing(16, after: last) }
        }
    }

    private var notebookPill: PillButton?
    private var subtitlePill: PillButton?
    private var collapsePill: PillButton?
    private var chatPill: PillButton?

    @objc private func toggleChat() { setChatCollapsed(!chatCollapsed) }

    private func setChatCollapsed(_ collapsed: Bool) {
        guard collapsed != chatCollapsed else { return }
        chatCollapsed = collapsed
        chatPill?.title = collapsed ? "展开对话" : "收起对话"
        var s = Settings.load(); s.chatCollapsed = collapsed; s.save()
        resizeToFitContent()
        onResized?()
    }

    /// 开始/停止字幕。外部回调回报是否真的起来了（权限、模型资产都可能失败）。
    var onToggleSubtitle: ((Bool, @escaping (String?) -> Void) -> Void)?

    @objc private func toggleSubtitle() {
        let turningOn = !subtitleOn
        subtitlePill?.isEnabled = false
        onToggleSubtitle?(turningOn) { [weak self] error in
            guard let self else { return }
            self.subtitlePill?.isEnabled = true
            if let error {
                self.append(role: .cat, text: error)   // 失败要说人话，不能静默
                return
            }
            self.subtitleOn = turningOn
            self.subtitleCollapsed = false
            self.subtitlePill?.title = turningOn ? "停止字幕" : "开始字幕"
            self.subtitlePill?.isActive = turningOn
            self.subtitleHeader.stringValue = turningOn ? Self.subtitleHeaderText() : "字幕 · 已停止"
            self.collapsePill?.isEnabled = turningOn
            if !turningOn { self.subtitleFinals = []; self.subtitleDraft = "" }
            self.renderSubtitles()
            self.resizeToFitContent()
            self.onResized?()
        }
    }

    /// 收起是**粘性**的：原本每来一条新字幕都会把它顶开，而讲课时约 5 秒一条，
    /// 等于根本收不掉（旧版的教训）。
    @objc private func toggleCollapse() {
        subtitleCollapsed.toggle()
        collapsePill?.title = subtitleCollapsed ? "展开字幕" : "收起字幕"
        resizeToFitContent()
        onResized?()
    }

    /// 查词工具可用才点亮生词本按钮。
    func setVocabAvailable(_ available: Bool) {
        notebookPill?.isEnabled = available
        notebookPill?.toolTip = available ? nil : "本机未安装 english-vocab 工具"
    }

    var onOpenNotebook: ((@escaping ([VocabStore.Entry]?) -> Void) -> Void)?

    /// 只给调试用：不启麦克风，直接把字幕区打开，好导出样式自查。
    func debugForceSubtitleOn() {
        subtitleOn = true
        subtitleCollapsed = false
        subtitlePill?.title = "停止字幕"
        subtitlePill?.isActive = true
        subtitleHeader.stringValue = Self.subtitleHeaderText()
        collapsePill?.isEnabled = true
        resizeToFitContent()
        onResized?()
    }

    func openNotebookForDebug() { if !notebookOpen { toggleNotebook() } }

    @objc private func toggleNotebook() {
        notebookOpen.toggle()
        notebookPill?.title = notebookOpen ? "关闭生词本" : "生词本"
        notebookPill?.isActive = notebookOpen
        notebookHeader.stringValue = "生词本 · 读取中…"
        resizeToFitContent()            // 展开/收起都要重新算高度
        onResized?()
        NSLog("[pet] 生词本 %@，卡片高 %.0f", notebookOpen ? "打开" : "关闭", frame.height)
        guard notebookOpen else { return }
        // 每次打开重新拉，不缓存——词也会从 Telegram 和 CLI 那边进来。
        onOpenNotebook? { [weak self] entries in
            guard let self else { return }
            self.notebook.show(entries)
            self.notebookHeader.stringValue = entries.map { "生词本 · \($0.count) 词" } ?? "生词本 · 读不到"
        }
    }

    private func pill(_ title: String, enabled: Bool, tip: String? = nil,
                      action: Selector? = nil) -> NSView {
        let b = PillButton(title: title, target: self, action: action)
        b.isEnabled = enabled
        b.toolTip = tip
        return b
    }

    @objc private func newConversation() {
        transcript.string = ""
        isEmptyConversation = true
        append(role: .cat, text: Self.greeting)
        onNewConversation?()
    }

    // MARK: - 布局

    /// 手工布局而不是 Auto Layout：这些数值是逐个量出来的，写成坐标最直白，
    /// 也免得约束求解跟"窗口高度随内容变化"互相打架。
    private func layoutCard(height: CGFloat) {
        let m = Self.shadowMargin, i = Self.cardInset, inner = Self.innerInset
        card.frame = NSRect(x: m, y: m, width: Self.cardWidth, height: height)
        blur.frame = card.frame

        let w = Self.cardWidth - (i + inner) * 2
        let x = i + inner
        // AppKit 原点在左下，所以从下往上排：按钮行 → 输入框 → 消息区
        actionRow.frame = NSRect(x: x, y: i, width: w, height: Self.pillHeight)
        input.frame = NSRect(x: x, y: i + Self.actionRowHeight + Self.blockGap,
                             width: w, height: Self.inputHeight)

        // 状态行：只在有文案时占位。旧版是 flex 列里的一个条件块，
        // 不显示时连它那份 gap 一起消失，卡片就矮回去。
        statusDot.isHidden = !statusVisible
        statusLabel.isHidden = !statusVisible
        var msgBottom = input.frame.maxY + Self.blockGap
        if statusVisible {
            let rowY = msgBottom
            statusDot.frame = NSRect(x: x, y: rowY + (Self.statusHeight - Self.statusDotSize) / 2,
                                     width: Self.statusDotSize, height: Self.statusDotSize)
            // 圆点和文字之间 8px：旧版 `<Flex align="center" gap="2">`。
            let labelX = x + Self.statusDotSize + Self.blockGap
            statusLabel.frame = NSRect(x: labelX, y: rowY,
                                       width: max(0, x + w - labelX), height: Self.statusHeight)
            msgBottom = rowY + Self.statusHeight + Self.blockGap
        }

        scroll.isHidden = !messageVisible

        // 从卡片顶部往下依次排：字幕带 → 生词本带 → 对话区。
        // **两条带都是「带」，不是「替换对话区」**——旧版 vocabBox 与 subtitleBox 同构
        // （同样的分隔线、同样的滚动上限），对话区始终保留在下面。
        // 我第一版把生词本和对话区做成互斥的，打开生词本就把对话整个盖掉了。
        var top = height - i
        top = layoutBand(scroll: subtitleScroll, header: subtitleHeader, divider: subtitleDivider,
                         visible: subtitleBandVisible, bandHeight: currentSubtitleBandHeight,
                         x: x, width: w, top: top)
        top = layoutBand(scroll: nil, header: notebookHeader, divider: notebookDivider,
                         visible: notebookOpen, bandHeight: Self.notebookBandHeight,
                         x: x, width: w, top: top, content: notebook)

        scroll.frame = NSRect(x: x, y: msgBottom, width: w, height: max(0, top - msgBottom))
    }

    var statusVisible: Bool { !statusLabel.stringValue.isEmpty }

    var subtitleBandVisible: Bool { subtitleOn && !subtitleCollapsed }

    /// 排一条带（头部 + 内容 + 底部分隔线），返回下一块内容可用的顶边。
    @discardableResult
    private func layoutBand(scroll band: NSScrollView?, header: NSTextField, divider: NSView,
                            visible: Bool, bandHeight: CGFloat,
                            x: CGFloat, width: CGFloat, top: CGFloat,
                            content: NSView? = nil) -> CGFloat {
        let view = band ?? content
        header.isHidden = !visible
        divider.isHidden = !visible
        view?.isHidden = !visible
        guard visible else { return top }

        header.frame = NSRect(x: x, y: top - Self.bandHeaderHeight, width: width, height: Self.bandHeaderHeight)
        let contentTop = header.frame.minY - 4
        view?.frame = NSRect(x: x, y: contentTop - bandHeight, width: width, height: bandHeight)
        divider.frame = NSRect(x: x, y: contentTop - bandHeight - 5, width: width, height: 1)
        return divider.frame.minY - Self.blockGap
    }

    /// 卡片高度跟着内容走。上限对应旧版 `messageStack.maxH = 340`——
    /// 查词卡片是多段的，没有上限会把输入框顶出屏幕。
    private func resizeToFitContent() {
        let contentWidth = Self.cardWidth - (Self.cardInset + Self.innerInset) * 2
        var textHeight = Self.messageMinHeight
        if let container = transcript.textContainer, let lm = transcript.layoutManager {
            // 宽度不能让它跟着 textView 走：textView 此刻还是上一轮的尺寸，而且
            // 垂直滚动条会从中吃掉 17pt（实测容器宽变成 349），量出来的行数就不对。
            container.widthTracksTextView = false
            container.heightTracksTextView = false

            /// **必须用 glyphRange(for:) 强制布局**，`ensureLayout(for:)` 不够：
            /// 实测一张 177 字的查词卡片 usedRect 仍返回高度 0，于是整块被兜底成
            /// 一行（用户报"查词只显示一行"）。旧版能对，是因为那时紧挨着一句
            /// `scrollToEndOfDocument`——滚到末尾必须先知道末尾在哪，顺手把全量布局
            /// 逼出来了。**那是副作用，不是契约**：我把那句换成滚到开头之后就塌了。
            func layOut(width: CGFloat) -> CGFloat {
                container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
                _ = lm.glyphRange(for: container)
                return ceil(lm.usedRect(for: container).height)
            }
            textHeight = layOut(width: contentWidth)
            // 卡片超过上限就要出滚动条，而 overlay 滚动条是**盖在文字上**的，
            // 不像旧式滚动条那样从宽度里扣——不主动让出这道槽，最后几个字母就被
            // 滚动条压住（用户报"有内容跑到了行外"）。所以一旦要滚，按窄一点重排。
            if textHeight > Self.messageMaxHeight {
                textHeight = layOut(width: contentWidth - Self.scrollerGutter)
            }
        }
        // 消息区为空 → 整块不占位（连同它那份 blockGap），不是留一个 32px 的空条。
        let messageHeight = messageVisible
            ? min(max(textHeight, Self.messageMinHeight), Self.messageMaxHeight)
            : 0
        // 每条带 = 头部 + 内容 + 分隔线 + 间隔
        func bandTotal(_ h: CGFloat) -> CGFloat { Self.bandHeaderHeight + 4 + h + 5 + 1 + Self.blockGap }
        let bands = (subtitleBandVisible ? bandTotal(currentSubtitleBandHeight) : 0)
            + (notebookOpen ? bandTotal(Self.notebookBandHeight) : 0)
        let cardHeight = Self.cardInset * 2 + bands
            + (messageVisible ? messageHeight + Self.blockGap : 0)
            + (statusVisible ? Self.statusHeight + Self.blockGap : 0)
            + Self.inputHeight + Self.blockGap + Self.actionRowHeight
        let windowHeight = cardHeight + Self.shadowMargin * 2

        if abs(windowHeight - frame.height) > 0.5 {
            let top = frame.maxY
            setFrame(NSRect(x: frame.minX, y: top - windowHeight,
                            width: Self.cardWidth + Self.shadowMargin * 2, height: windowHeight),
                     display: true)
            onResized?()
        }
        layoutCard(height: cardHeight)
    }

    /// 气泡贴在猫的哪一侧由 `BubbleLayout` 算（纯函数，可测）。
    /// 传进去的是**卡片**尺寸而不是窗口——窗口比卡片大一圈阴影边距，
    /// 拿窗口尺寸去算会让气泡离猫多出 24px，看着就是飘着。
    func position(nextTo petFrame: CGRect) {
        let cardSize = NSSize(width: Self.cardWidth, height: frame.height - Self.shadowMargin * 2)
        let origin = BubbleLayout.origin(petFrame: petFrame, bubbleSize: cardSize,
                                         screens: NSScreen.screens.map(\.frame), gap: Self.gapToPet)
        setFrameOrigin(NSPoint(x: origin.x - Self.shadowMargin, y: origin.y - Self.shadowMargin))
    }

    // MARK: - 显示

    func present(nextTo petFrame: CGRect) {
        if isEmptyConversation && transcript.string.isEmpty { append(role: .cat, text: Self.greeting) }
        rotatePlaceholder()
        resizeToFitContent()
        position(nextTo: petFrame)
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(input)
        startWatchingClicksOutside()
    }

    private func rotatePlaceholder() {
        placeholderIndex = (placeholderIndex + 1) % Self.placeholders.count
        if !isThinking { setPlaceholder(Self.placeholders[placeholderIndex]) }
    }

    /// 点到别处就收起。
    ///
    /// 三个例外：
    /// - **字幕开着且展开时不收**：看视频时点一下播放器就把字幕关掉，功能等于没法用
    ///   （用户实测报的 bug）。字幕是个持续输出的东西，它在的时候气泡就该钉住。
    ///   收起了字幕带（subtitleCollapsed）则不在此列——那说明用户不想看了。
    /// - **输入法组词中不收**：候选框是另一个窗口，它一弹出来气泡就失去 key，
    ///   这时收起等于"一开始打中文气泡就消失"。
    /// - **等回复期间不收**：那一轮结果还没出来，收了就白等了。
    var shouldStayOpen: Bool {
        if isThinking { return true }
        // 字幕正在起（或正在收尾）：这几秒里点一下别处就把气泡收了，
        // 用户看不到它到底起没起来，和"等回复期间不收"是同一个道理。
        if !subtitleStatus.isEmpty { return true }
        if subtitleOn && !subtitleCollapsed { return true }
        if let editor = fieldEditor(false, for: input) as? NSTextView, editor.hasMarkedText() { return true }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, !shouldStayOpen else { return }
        dismiss()
    }

    func dismiss() {
        stopWatchingClicksOutside()
        orderOut(nil)
        onDismiss?()
    }

    private func startWatchingClicksOutside() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self, self.isVisible, !self.shouldStayOpen else { return }
            let p = NSEvent.mouseLocation
            // 点在气泡自己身上 → 不收（虽然那种情况通常走 local 事件，这里防御性再判一次）
            if self.frame.contains(p) { return }
            // 点在猫身上 → 交给猫的 toggle，这里不插手
            if let pet = self.petFrameProvider?(), pet.contains(p) { return }
            self.dismiss()
        }
    }

    private func stopWatchingClicksOutside() {
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m) }
        clickOutsideMonitor = nil
    }

    // MARK: - 内容

    /// 消息区**只显示一条**：猫最后说的那句。这是旧版的显示逻辑
    /// （`displayMessage = lastAIMessage ?? 对话为空时的问候`），不是对话列表。
    ///
    /// 我上一版做成了追加式的对话流（两条之间空一行、用户的话用全角空格缩进），
    /// 用户一眼就看出跟旧版不是一回事：旧版气泡从来不回显用户自己刚打的字，
    /// 也不往下堆历史——400px 宽的气泡装不下一段对话，堆起来只会把输入框顶走。
    /// 历史归历史文件，气泡只负责"猫现在说了什么"。
    func append(role: Role, text: String) {
        // 收起对话时用户开口/查词、或冒出一条真回复（含字幕启动失败的说明）就自动展开——
        // 否则回复写进了一个看不见的区域。问候语不算，它每次打开气泡都会来一条。
        if chatCollapsed && (role == .user || text != Self.greeting) { setChatCollapsed(false) }
        isEmptyConversation = false
        // 用户的话不进消息区，只是**让问候语失效**——旧版的 `displayMessage` 里
        // "喵～"那一支的条件是 `isConversationEmpty`，用户一开口它就不成立了，
        // 于是问候语让位给状态行。注意只清问候语：真实的上一条回复要一直留到
        // 新回复到达为止（`lastAIMessage` 不受用户发言影响）。
        if role == .user {
            if showingGreeting { setTranscript(""); showingGreeting = false }
            resizeToFitContent()
            return
        }
        showingGreeting = text == Self.greeting
        setTranscript(text)
        resizeToFitContent()
    }

    /// 消息区是否有东西要显示。空了就整块不占位——旧版是 `{displayMessage && ...}`，
    /// 条件不成立时那个块根本不渲染，卡片跟着缩回去。
    private var hasMessage: Bool { !transcript.string.isEmpty }
    private var messageVisible: Bool { hasMessage && !chatCollapsed }

    /// 回复要等几秒（实测约 8 秒），期间必须有提示，否则用户看到的是猫发呆。
    ///
    /// **提示走状态行，不走占位语**：旧版输入框在等回复期间既不禁用、占位语也不变
    /// （占位语只在每次打开气泡时轮换一条），等待是由消息区和输入框之间那条
    /// 带小圆点的灰字承担的。我上一版把它塞进 placeholder 并顺手禁用了输入框，
    /// 结果是提示一打字就看不见，而且还打断了"想说就能说"。
    func setThinking(_ thinking: Bool) {
        isThinking = thinking
        refreshStatus()
    }

    /// 字幕启动/收尾的阶段文案。`nil` 表示这件事结束了。
    /// 字幕要跑好几个阶段（加载模型、探测校正模型、开麦克风），每段都是几秒，
    /// 报出来比一个转圈有用——所以是开放文本而不是布尔。
    func setStatus(_ text: String?) {
        subtitleStatus = text ?? ""
        refreshStatus()
    }

    /// 状态行只有一行，两个来源要定优先级。**字幕进度压过"思考中…"**，
    /// 和旧版一致（`subtitlePending && subtitleMessage ? subtitleMessage : isThinking ? '思考中…' : ''`）：
    /// 字幕那条带具体阶段，信息量大；而且两件事能同时发生——字幕在起的时候照样能发消息。
    private func refreshStatus() {
        statusLabel.stringValue = !subtitleStatus.isEmpty ? subtitleStatus
            : isThinking ? "思考中…" : ""
        animateStatusDot()
        resizeToFitContent()
    }

    /// 思考时圆点呼吸。旧版 `animation: pulse 1.2s ease-in-out infinite`。
    private func animateStatusDot() {
        statusDot.layer?.removeAnimation(forKey: "pulse")
        guard isThinking || !subtitleStatus.isEmpty else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0; a.toValue = 0.3; a.duration = 0.6
        a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        statusDot.layer?.add(a, forKey: "pulse")
    }
}

extension BubblePanel: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        // **中文输入法组词中不能发送**：`hasMarkedText()` 为真说明候选框还开着，
        // 这一下回车是在选词，不是在发消息。
        if textView.hasMarkedText() { return false }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        input.stringValue = ""
        append(role: .user, text: text)
        onSubmit?(text)
        return true
    }
}

// MARK: - 调试

extension BubblePanel {
    /// PET_DUMP_BUBBLE=<路径> 时把气泡渲染成 PNG，用于在无截图权限的环境里自查样式。
    /// 不靠用户当验证器——目测截图猜样式已经错过两轮。
    func dumpIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["PET_DUMP_BUBBLE"],
              let root = contentView,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        let size = root.bounds.size
        let img = NSImage(size: size)
        img.lockFocus()
        // 注意：**这张图证明不了透明度**。cacheDisplay 只抓视图自己画的内容，
        // 而毛玻璃模糊的是「窗口背后」的东西，根本不在视图的绘制里。
        // 垫花纹只是让白底的深浅看得出来；真实观感必须在屏幕上看。
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.75, alpha: 1).setFill()
        var y: CGFloat = 0
        while y < size.height {
            NSRect(x: 0, y: y, width: size.width, height: 6).fill()
            y += 22
        }
        rep.draw(in: NSRect(origin: .zero, size: size))
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        NSLog("[pet] 气泡已导出到 %@（%.0fx%.0f）", path, size.width, size.height)
    }
}

// MARK: - 控件

/// 胶囊输入框。`NSTextField` 没有内边距，文字和光标会贴死在左边缘被裁掉，
/// 所以自定义 cell 把文字矩形缩进。实测旧版 `padding: 0px 16px`。
private final class CapsuleTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { PaddedTextFieldCell.self }
        set { super.cellClass = newValue }
    }
    override func drawFocusRingMask() {}
}

private final class PaddedTextFieldCell: NSTextFieldCell {
    private static let hInset: CGFloat = 16

    private func inset(_ rect: NSRect) -> NSRect {
        let h = (font?.boundingRectForFont.height ?? 17).rounded(.up)
        return NSRect(x: rect.minX + Self.hInset,
                      y: rect.minY + (rect.height - h) / 2,     // 单行文字要自己垂直居中
                      width: max(0, rect.width - Self.hInset * 2),
                      height: h)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { inset(rect) }

    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: view, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText,
                         delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: inset(rect), in: view, editor: editor,
                     delegate: delegate, start: start, length: length)
    }
}

/// 动作胶囊。**实测值**：字号 10 / 字重 500 / 颜色 rgb(82,82,91) / 高 25 /
/// 内边距 4×10 / 全圆角 / 1px rgba(0,0,0,0.1) 边框 / 透明底 / 禁用态 opacity 0.45。
///
/// **自绘而不是用 NSButton**：NSButton 的标题颜色不受 `contentTintColor` 控制，
/// 设了 `attributedTitle` 也会被 bezel 的系统样式盖掉——一排按钮里启用的那个会渲染成
/// 黑色粗体，跟禁用的对不齐。
private final class PillButton: NSControl {
    /// 标题要能改——「生词本」点开后变「关闭生词本」。
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var label: String { title }
    private static let colour = NSColor(red: 82/255, green: 82/255, blue: 91/255, alpha: 1)
    private static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let hPadding: CGFloat = 10
    private static let height: CGFloat = 25
    private static let disabledOpacity: CGFloat = 0.45

    init(title: String, target: AnyObject?, action: Selector?) {
        self.title = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let w = (label as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(w) + Self.hPadding * 2, height: Self.height)
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    /// 激活态（字幕开着 / 生词本开着）。**颜色是从旧版渲染结果上量的**，
    /// 不是从 `green.300` 这类令牌名反推——同名令牌跨 Chakra 大版本会变，
    /// 我已经在 gray.400 上栽过一次（用了 v2 的蓝调灰，实际是 v3 的中性灰）。
    var isActive = false { didSet { needsDisplay = true } }
    private static let activeBorder = NSColor(red: 134/255, green: 239/255, blue: 172/255, alpha: 1)
    private static let activeText = NSColor(red: 17/255, green: 105/255, blue: 50/255, alpha: 1)
    private static let activeFill = NSColor(red: 240/255, green: 253/255, blue: 244/255, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let a: CGFloat = isEnabled ? 1 : Self.disabledOpacity
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        if isActive {
            Self.activeFill.setFill()
            pill.fill()
        }
        (isActive ? Self.activeBorder : NSColor.black.withAlphaComponent(0.1 * a)).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: (isActive ? Self.activeText : Self.colour).withAlphaComponent(a),
        ]
        let s = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2,
                                             y: (bounds.height - s.height) / 2),
                                 withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}
