import AppKit
import PetAnimation
import PetCore
import Providers
import VocabKit
import SubtitleKit
import SelectionKit

/// 面板编排：生命周期、菜单栏、面板之间的联动。
///
/// 多面板架构的代价就在这里——"面板集合的显示/隐藏/跟随/跨屏"要自己管。
/// 换来的是不用再写任何 `setIgnoreMouseEvents` 编排。
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private var pet: PetPanel?
    private var bubble: BubblePanel?
    /// 对话后端。**不写死**：用户在设置里可以换（OpenAI 兼容端点 / Hermes CLI），
    /// 换完要当场生效，所以这里是个 var，由 `rebuildProvider()` 重建。
    private var chat: any ChatProvider = ProviderRegistry.make()
    /// 查词与生词本。词典没装时 `lookup` 会返回 `.unavailable`，生词本照常可用——
    /// 两者互不依赖，所以这个对象永远存在，不需要可选。
    private let vocab = VocabStore()
    /// 首次运行向导，同时也是设置页。
    private let setup = SetupWindow()
    private let subtitles = SubtitleService()
    private var subtitlePump: Task<Void, Never>?
    private let selectionWatcher = SelectionWatcher()
    private let selectionPopover = SelectionPopover()
    /// 当前这一轮的任务。新一轮开始前先取消上一轮——取消会真正杀掉 hermes 子进程，
    /// 不会出现"答案被丢弃但 token 照烧"。
    private var turn: Task<Void, Never>?
    /// 本地对话 id，决定映射到哪个 Hermes 会话（两边 1:1）。
    private var historyUID = AppCoordinator.newHistoryUID()

    private static func newHistoryUID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(f.string(from: Date()))_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }
    private var statusItem: NSStatusItem?
    /// 菜单栏的「字幕设置」子菜单（存放位置 / 自动做笔记的开关与门槛）。
    private let subtitleSettings = SubtitleSettingsMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory：不进 Dock、不抢焦点，桌宠该有的样子。
        NSApp.setActivationPolicy(.accessory)
        do {
            let manifest = try SpriteManifest.load()
            let panel = try PetPanel(manifest: manifest)
            panel.sprite.onClick = { [weak self] outcome in self?.handleClick(outcome) }
            panel.moveToDefaultSpot()
            panel.orderFrontRegardless()        // 不激活 app 也要显示
            panel.sprite.start()
            panel.onMoved = { [weak self] frame in
                guard let self, self.bubbleOpen else { return }
                self.bubble?.position(nextTo: frame)     // 拖猫时气泡跟着走
            }
            pet = panel

            let bubblePanel = BubblePanel()
            // Stage 1 是回声模式：不接后端，先把交互本身验收掉。
            bubblePanel.onSubmit = { [weak self] text in self?.send(text) }
            bubblePanel.petFrameProvider = { [weak self] in self?.pet?.frame ?? .zero }
            bubblePanel.setVocabAvailable(true)   // 生词本不依赖词典，永远可用
            bubblePanel.onToggleSubtitle = { [weak self] turningOn, done in
                self?.toggleSubtitles(turningOn, done: done)
            }
            bubblePanel.onOpenNotebook = { [weak self] done in
                guard let vocab = self?.vocab else { done(nil); return }
                Task {
                    Log.info("生词本：开始拉取")
                    let entries = await vocab.list()
                    Log.info("生词本：拉到 \(entries?.count ?? -1) 条")
                    await MainActor.run { done(entries) }
                    Log.info("生词本：已交给面板")
                }
            }
            bubblePanel.notebook.onDelete = { [weak self] word, done in
                guard let vocab = self?.vocab else { return }
                Task {
                    let r = await vocab.delete(word)
                    Log.info("删除 \(word)：\(r.success ? "成功" : "失败")")
                    await MainActor.run { done(r) }
                }
            }
            bubblePanel.onDismiss = { [weak self] in
                // 失焦收起是气泡自己发起的，协调器要同步状态，否则下一次点猫
                // 会以为它还开着、变成要点两下才出来。
                guard let self, self.bubbleOpen else { return }
                self.bubbleOpen = false
            }
            bubblePanel.onNewConversation = { [weak self] in
                guard let self else { return }
                self.turn?.cancel()
                self.historyUID = AppCoordinator.newHistoryUID()   // 新对话 = 新的 Hermes 会话
                Log.info("新对话 \(self.historyUID)")
            }
            bubblePanel.onResized = { [weak self] in
                guard let self, let pet = self.pet else { return }
                self.bubble?.position(nextTo: pet.frame)
            }

            bubble = bubblePanel
            NSLog("[pet] panel frame=%@ screen0=%@",
                  NSStringFromRect(panel.frame), NSStringFromRect(NSScreen.screens.first?.frame ?? .zero))
        } catch {
            fatalError("精灵素材加载失败: \(error)")
        }
        setupStatusItem()
        startSelectionWatchIfPermitted()
        setup.onFinish = { [weak self] in self?.rebuildProvider() }
        // 设置在别处（菜单栏「字幕设置」）改动时也要重建后端，否则换了模型还得重开 app。
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildProvider() }
        }
        showOnboardingIfFirstRun()
        // 心跳：判断主线程是不是被卡住了。留着不删——2026-09-14 正是靠它定位到
        // 生词本用 NSStackView 堆 76 行把 Auto Layout 打爆、主线程卡死。
        if ProcessInfo.processInfo.environment["PET_HEARTBEAT"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                NSLog("[pet] heartbeat")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pet?.sprite.stop()
    }

    /// 气泡是否开着。**这个状态必须喂回状态机**（setBusy）——否则猫以为没人理它，
    /// 醒来 5 秒打哈欠、8 秒就趴下睡了，用户看到的是"点一下猫，动作一闪而过"。
    /// Stage 1 的气泡面板还没做，但这个状态现在就要正确，否则没法验收动画节奏。
    private var bubbleOpen = false {
        didSet {
            guard bubbleOpen != oldValue else { return }
            pet?.sprite.setBusy(bubbleOpen)
            guard let pet, let bubble else { return }
            if bubbleOpen {
                // 点猫开气泡时状态机已经先醒了，这里是空操作；划词查词、字幕这类
                // 不经过点击的入口，靠这一句把睡着的猫叫醒。
                pet.sprite.bubbleOpened()
                bubble.present(nextTo: pet.frame)
                // 开了生词本调试时晚点拍，好让列表先加载出来
                let env = ProcessInfo.processInfo.environment
                let slow = env["PET_DEBUG_OPEN_NOTEBOOK"] == "1" || env["PET_DEBUG_FAKE_SUBTITLE"] == "1"
                let delay = slow ? 4.0 : 0.5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { bubble.dumpIfAsked() }
                autoSendIfAsked()
                // PET_DEBUG_THINKING=1：不发真消息，直接把气泡摆成"等回复"的样子，
                // 用来自查状态行的排版（不消耗 Hermes 额度）。
                if env["PET_DEBUG_THINKING"] == "1" {
                    bubble.append(role: .user, text: "hi")   // 走真实路径：问候语要让位
                    bubble.setThinking(true)
                }
                // PET_DEBUG_STATUS=<文案>：直接摆一条字幕阶段文案，用来自查状态行
                // （两个开关一起开就能验证"字幕进度压过思考中"这条优先级）。
                if let stage = env["PET_DEBUG_STATUS"] { bubble.setStatus(stage) }
                // PET_DEBUG_CARD=1：灌一张多段的假查词卡片，自查消息区高度是否跟着内容长。
                // 不查真词、不写生词本。
                if let n = env["PET_DEBUG_CARD"].flatMap(Int.init), n >= 1 {
                    bubble.append(role: .cat, text: """
                    📚 distribution /ˌdɪstrɪˈbjuːʃn/

                    n. 分布；分配；配送

                    • The distribution of wealth is uneven.
                      财富的分布并不均匀。

                    • We handle distribution across Asia.
                      我们负责亚洲区的配送。

                    近义：allocation, dispersal
                    """ + String(repeating: "\n\n补充释义段落，用来把卡片撑过 340px 的上限。", count: n - 1))
                }
                openNotebookIfAsked()
                fakeSubtitleIfAsked()
                realSubtitleIfAsked()
            } else { bubble.orderOut(nil) }
        }
    }

    private func handleClick(_ outcome: AnimationStateMachine.ClickOutcome) {
        switch outcome {
        case .wakeAndOpenBubble: bubbleOpen = true
        case .toggleBubble:      bubbleOpen.toggle()
        case .ignored:           break          // 迎接动作播放中，忽略
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 菜单栏用旧版那张 44px 的猫头特写，不是 emoji。
        // **44px 下整只猫是不可读的**，所以旧版特意裁的是 sit 帧的头部
        // （见 code/调试脚本/build_cat_sprite_sheets.py 的 write_tray_icon）。
        if let url = SpriteManifest.resourceBundle.url(forResource: "tray-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            // 菜单栏按高度 18pt 显示；不设 isTemplate——这只猫是彩色的，
            // 当模板图会被整个染成单色，就剩一个黑色剪影了。
            image.size = NSSize(width: 18 * image.size.width / image.size.height, height: 18)
            item.button?.image = image
            NSLog("[pet] 菜单栏用猫头图标 %.0fx%.0f", image.size.width, image.size.height)
        } else {
            item.button?.title = "🐱"      // 资源缺失时的兜底，不至于没有入口
            NSLog("[pet] 菜单栏回退到 emoji——tray-icon.png 没在 bundle 里")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "回到默认位置", action: #selector(recentre), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(subtitleSettings.menuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSetup), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "检查环境…", action: #selector(showDependencies), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关于桌宠", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        subtitleSettings.dumpIfAsked()
        NSLog("[pet] PET_TRACE_FRAMES=%@", ProcessInfo.processInfo.environment["PET_TRACE_FRAMES"] ?? "(unset)")
        NSLog("[pet] statusItem button=%@ visible=%@",
              item.button == nil ? "nil" : "ok", item.isVisible ? "true" : "false")
    }

    @objc private func recentre() { pet?.moveToDefaultSpot() }

    // MARK: - 设置与环境

    @objc private func openSetup() { setup.show() }

    /// 第一次运行（或还没走完向导）就把设置页摆到用户面前。
    /// **不强制走完**：每一项缺失都有降级路径，用户可以直接关掉先用着。
    private func showOnboardingIfFirstRun() {
        guard !FileManager.default.fileExists(atPath: Paths.onboardingMarker.path) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.setup.show() }
    }

    /// 设置改了就换一个对话后端。旧的那个连同它没跑完的请求一起丢掉——
    /// 用户刚把模型换掉，没理由还等上一个模型的回答。
    private func rebuildProvider() {
        turn?.cancel()
        chat = ProviderRegistry.make()
        Log.info("对话后端已重建：\(chat.displayName)")
    }

    /// 让 app 自己说清楚这台机器上什么齐了、缺的那些会影响什么。
    /// **没有"缺了就不能用"的项**——真出现了那是架构缺陷，见 `DependencyReport.hasFatalGap`。
    @objc private func showDependencies() {
        let report = DependencyReport.probe()
        let alert = NSAlert()
        alert.messageText = "运行环境"
        alert.informativeText = report.summary + "\n\n每一项缺失都有降级路径，主功能不会整个不可用。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "去设置…")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { setup.show() }
    }

    /// ECDICT 是 MIT 协议且**要求署名**，所以这一条是法律义务不是客套。
    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let alert = NSAlert()
        alert.messageText = "桌宠 \(version)"
        alert.informativeText = """
        住在 macOS 桌面上的猫：对话、英文查词记生词、实时字幕、划词查词。

        词典数据来自 ECDICT（MIT License）
        https://github.com/skywind3000/ECDICT

        语音识别由 macOS 的 SpeechAnalyzer 在本机完成，音频不上传。
        对话内容会发送到你自己配置的 API 服务，除此之外没有任何数据离开这台电脑。
        """
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }


    // MARK: - 对话

    /// PET_DEBUG_AUTOSEND=<文本> 时自动发一条消息，用于在无法程序化输入的环境里
    /// 验证整条对话链。**会真的调用 Hermes、消耗订阅额度**，只在手动排查时开。
    private func autoSendIfAsked() {
        guard let text = ProcessInfo.processInfo.environment["PET_DEBUG_AUTOSEND"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Log.info("注入调试消息：\(text)")
            self?.bubble?.append(role: .user, text: text)
            self?.send(text)
        }
    }

    /// 能力链：查词优先，弃权了再交给 LLM。
    ///
    /// **每一环必须能弃权并交给下一环**，而不是用一条错误消息终结整条链——
    /// 早先的查词分支是个死胡同：形状判定只认"长得像不像英文单词"，任何这样的串
    /// （实测 `zzyzxqwe`）都被路由进去，词典查不到时回一句「请稍后再试」——
    /// 用户既没卡片也没 LLM 回答，而"稍后"永远不会成功，因为词本来就不在词典里。
    /// PET_DEBUG_OPEN_NOTEBOOK=1 时自动打开生词本，用于自查面板渲染。
    /// PET_DEBUG_FAKE_SUBTITLE=1：不开麦克风，直接灌几条假字幕进去，用于自查字幕区样式。
    private func fakeSubtitleIfAsked() {
        guard ProcessInfo.processInfo.environment["PET_DEBUG_FAKE_SUBTITLE"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.bubble?.debugForceSubtitleOn()
            let lines = [
                SubtitleLine(stage: .final, text: "So today we will look at cross entropy loss", start: 0, end: 3),
                SubtitleLine(stage: .final, text: "and how it relates to maximum likelihood", start: 3, end: 6),
                SubtitleLine(stage: .volatile, text: "estimation in a classification", start: 6, end: 8),
            ]
            for l in lines { self?.bubble?.appendSubtitle(l) }
        }
    }

    /// PET_DEBUG_REAL_SUBTITLE=<秒>：真开麦克风跑一段字幕再停，用于验证
    /// 「麦克风授权 → SpeechAnalyzer → 落盘」整条链。单元测试只覆盖了落盘那一段，
    /// 而旧版恰恰是**只有真实麦克风路径**下落盘 100% 失败（7/7 次 0 字节）。
    private var debugHooksFired = false

    private func realSubtitleIfAsked() {
        guard let s = ProcessInfo.processInfo.environment["PET_DEBUG_REAL_SUBTITLE"],
              let seconds = Double(s), !debugHooksFired else { return }
        // 这些钩子挂在 bubbleOpen 的 didSet 上，气泡每开一次就会再触发一遍——
        // 实测导致一段话被切成三段字幕、三个目录。只放行第一次。
        debugHooksFired = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Log.info("调试：真开麦克风跑 \(seconds) 秒字幕")
            self?.toggleSubtitles(true) { error in
                if let error { Log.error("字幕启动失败：\(error)"); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    self?.toggleSubtitles(false) { _ in Log.info("调试：字幕已停止") }
                }
            }
        }
    }

    private func openNotebookIfAsked() {
        guard ProcessInfo.processInfo.environment["PET_DEBUG_OPEN_NOTEBOOK"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.bubble?.openNotebookForDebug()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            self?.bubble?.dumpIfAsked()
        }
    }

    // MARK: - 划词查词

    /// 划词需要辅助功能授权。**没授权就安静降级**，不弹窗骚扰——桌宠的主功能
    /// （对话、查词、字幕）都不依赖它。菜单栏里有个入口让用户想开的时候再开。
    private func startSelectionWatchIfPermitted() {
        let ok = selectionWatcher.start(onSelected: { [weak self] text, point in
            self?.selectionPopover.present(text: text, at: point) { picked in
                self?.lookUpSelection(picked)
            }
        }, onDismiss: { [weak self] in
            self?.selectionPopover.dismiss()
        })
        if !ok { Log.info("划词查词未启用（缺辅助功能授权）") }
    }

    /// 划选表达了**明确的查词意图**，所以走 forceLookup 强制查词，不经过
    /// 「单个合法英文单词才自动触发」那道形状判定——那道判定是给聊天消息用的。
    private func lookUpSelection(_ text: String) {
        bubbleOpen = true
        bubble?.append(role: .user, text: text)
        bubble?.setThinking(true)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.vocab.forceLookup(text)
            await MainActor.run {
                self.bubble?.setThinking(false)
                switch outcome {
                case .card(let card):
                    self.bubble?.append(role: .cat, text: card.reply)
                case .declined:
                    // 词典里没有就交给 LLM——划词也走同一条能力链
                    self.send(text)
                case .unavailable(let why):
                    self.bubble?.append(role: .cat, text: why)
                }
            }
        }
    }

    // MARK: - 字幕

    private func toggleSubtitles(_ on: Bool, done: @escaping (String?) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            guard on else {
                // 停止也不是一瞬间：收尾要把积压的定稿写完、改目录名，实测能跑好几秒。
                // 没有提示的话按钮按下去像是卡住了。
                await MainActor.run { self.bubble?.setStatus("正在收尾字幕…") }
                await self.subtitles.stop()
                self.subtitlePump?.cancel()
                self.subtitlePump = nil
                await MainActor.run {
                    self.bubble?.setStatus(nil)
                    done(nil)
                }
                return
            }
            // 落盘目录按开始时间分：<字幕根目录>/<时间戳>/。
            // 根目录可在菜单栏「字幕设置」里改，没改过就是默认位置。
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let dir = Settings.load().subtitleDirectory
                .appendingPathComponent(stamp.string(from: Date()))
            do {
                // 启动分几个阶段（加载识别模型、开音源），每阶段都往状态行上报：
                // 说清楚现在卡在哪一步，比一个转圈有用得多。
                // 音源在菜单「字幕设置」里二选一。系统音频走 ScreenCaptureKit，要屏幕录制权限：
                // **先检查再起**——SCK 没授权时不抛错，只是一个字都不出，用户会以为坏了。
                let useSystem = Settings.load().usesSystemAudio
                if useSystem && !CGPreflightScreenCaptureAccess() {
                    CGRequestScreenCaptureAccess()
                    await MainActor.run {
                        self.bubble?.setStatus(nil)
                        done("系统音频需要「屏幕与系统录音」权限：在 系统设置 → 隐私与安全性 里允许「桌宠」，然后重开桌宠再试。")
                    }
                    return
                }
                let source: AudioSource = useSystem ? SystemAudioSource() : MicrophoneSource()
                Log.info("字幕音源：\(useSystem ? "系统音频" : "麦克风")")
                let stream = try await self.subtitles.start(
                    source: source, outputDirectory: dir,
                    onProgress: { [weak self] stage in
                        Task { @MainActor in self?.bubble?.setStatus(stage) }
                    })
                self.subtitlePump = Task { [weak self] in
                    for await line in stream {
                        await MainActor.run { self?.bubble?.appendSubtitle(line) }
                    }
                }
                await MainActor.run {
                    // 起来了就收起状态行——字幕带本身就是"开启成功"的证据，
                    // 再补一条"字幕已开启"是多余的。
                    self.bubble?.setStatus(nil)
                    done(nil)
                }
            } catch {
                // 失败要说人话：麦克风没授权、模型资产没装，都是用户能处理的事。
                let why = (error as? LocalizedError)?.errorDescription ?? "字幕启动失败"
                Log.error("字幕启动失败：\(error)")
                await MainActor.run {
                    self.bubble?.setStatus(nil)
                    done(why)
                }
            }
        }
    }

    private func send(_ text: String) {
        turn?.cancel()                       // 新一轮取消上一轮，连同它的子进程
        bubble?.setThinking(true)
        let uid = historyUID
        turn = Task { [weak self] in
            guard let self else { return }

            // 第一环：查词。命中就直接出卡片，完全跳过 LLM（实测 0.08 秒 vs 数秒）。
            let outcome = await vocab.lookup(text)
            if case .card(let card) = outcome {
                guard !Task.isCancelled else { return }
                Log.info("查词命中 \(card.word)")
                await MainActor.run {
                    self.bubble?.setThinking(false)
                    self.bubble?.append(role: .cat, text: card.reply)
                    self.bubble?.dumpIfAsked()
                }
                return
            }
            if case .unavailable(let why) = outcome { Log.warn("查词不可用：\(why)") }
            // .declined → 落到下一环（LLM）

            // 还没配对话 API 时别发一轮注定失败的请求，直接把用户引到设置页。
            guard Settings.load().chatConfigured else {
                await MainActor.run {
                    self.bubble?.setThinking(false)
                    self.bubble?.append(role: .cat, text: "我还不会说话——点菜单栏里的猫 →「设置…」填上对话 API 就行了。")
                }
                return
            }

            var reply: String?
            var failure: String?
            do {
                for try await event in chat.respond(to: ChatTurn(text: text, historyUID: uid)) {
                    if case .message(let m) = event { reply = m }
                }
            } catch {
                // 错误要显示在气泡里，不能静默——否则用户只看到猫发呆。
                failure = (error as? LocalizedError)?.errorDescription ?? "出了点问题，请稍后再试。"
            }
            guard !Task.isCancelled else { Log.info("回合被取消"); return }
            Log.info(reply.map { "回复(\($0.count)字)：\($0.prefix(80))" } ?? "失败：\(failure ?? "?")")
            await MainActor.run {
                self.bubble?.setThinking(false)
                if let reply { self.bubble?.append(role: .cat, text: reply) }
                else if let failure { self.bubble?.append(role: .cat, text: failure) }
                self.bubble?.dumpIfAsked()
            }
        }
    }
}
