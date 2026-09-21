import AppKit
import PetAnimation

/// 猫的渲染层：一张雪碧图当 `CALayer.contents`，用 `contentsRect` 切出当前帧——
/// 这与前端的 CSS `background-position` 是 1:1 对应，素材和 `cat-anim.json` 零改动。
///
/// **两张 sheet 始终挂载、用 isHidden 切换**，不是用时才建 layer。前端踩过这个坑：
/// 按需切换会在"睡醒那一帧"现场解码 1MB 的 webp，卡一下。这里同理，两个 layer 一直在。
///
/// 命中测试读当前帧的像素 alpha：猫身上的透明边角要穿透到下层应用。
/// 这比 Electron 的"整窗二选一穿透"精细一个量级，也是本次重构 UI 层最大的收益之一。
final class SpriteView: NSView {
    private let manifest: SpriteManifest
    private let posesLayer = CALayer()
    private let breathLayer = CALayer()

    /// 每张 sheet 的 CGImage 用于渲染；alpha 采样走 PetAnimation 里的共享实现，
    /// 那边有测试覆盖（这里是 AppKit 层，测不到）。
    private let posesImage: CGImage
    private let breathImage: CGImage
    private let posesAlpha: SpriteAlpha
    private let breathAlpha: SpriteAlpha

    private var machine: AnimationStateMachine
    private var displayLink: CADisplayLink?

    /// 点到猫身上（而非透明边角）时回调。
    var onClick: ((AnimationStateMachine.ClickOutcome) -> Void)?
    /// 拖拽回调，传窗口原点**应该在的**屏幕坐标（绝对值，不是位移）。
    var onDragTo: ((CGPoint) -> Void)?

    init(manifest: SpriteManifest) throws {
        self.manifest = manifest
        self.posesAlpha = try SpriteAlpha(bundleResource: manifest.sheets.poses.imageName)
        self.breathAlpha = try SpriteAlpha(bundleResource: manifest.sheets.sleepBreath.imageName)
        self.posesImage = posesAlpha.image
        self.breathImage = breathAlpha.image
        self.machine = AnimationStateMachine(breathFrameCount: manifest.sheets.sleepBreath.frames.count)
        super.init(frame: NSRect(x: 0, y: 0, width: manifest.displayWidth, height: manifest.displayHeight))
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = false
        let scale = SpriteManifest.scale

        // poses 铺满整个画布盒；breath 是裁过的一条带，按 manifest 的 offset 贴回去，
        // 否则睡着的猫会浮在半空。
        let poses = manifest.sheets.poses
        posesLayer.frame = CGRect(x: poses.offsetX * scale,
                                  y: (manifest.petBox.height - poses.offsetY - poses.frameHeight) * scale,
                                  width: poses.frameWidth * scale,
                                  height: poses.frameHeight * scale)
        posesLayer.contents = posesImage

        let breath = manifest.sheets.sleepBreath
        breathLayer.frame = CGRect(x: breath.offsetX * scale,
                                   y: (manifest.petBox.height - breath.offsetY - breath.frameHeight) * scale,
                                   width: breath.frameWidth * scale,
                                   height: breath.frameHeight * scale)
        breathLayer.contents = breathImage

        for l in [posesLayer, breathLayer] {
            // 逐帧切图，不要任何隐式动画——否则每次换帧 Core Animation 会补间，猫会糊。
            l.actions = ["contentsRect": NSNull(), "contents": NSNull(), "hidden": NSNull()]
            l.magnificationFilter = .trilinear
            layer?.addSublayer(l)
        }
        applyCurrentStep()
    }

    // MARK: - 驱动

    /// PET_DEBUG_AUTOCLICK=<秒> 时在启动后自动点一下，用于在无法程序化点击的环境里
    /// 量取点击后的帧序列。只在调试构建里通过环境变量启用。
    private func scheduleDebugClickIfAsked() {
        guard let s = ProcessInfo.processInfo.environment["PET_DEBUG_AUTOCLICK"],
              let delay = Double(s) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            NSLog("[pet] 注入调试点击")
            self?.performClick()
        }
    }

    func start() {
        scheduleDebugClickIfAsked()
        // CADisplayLink 对齐显示器刷新，时序比 setTimeout 准；
        // 但它只决定"何时检查"，每帧停留多久仍由状态机的毫秒表说了算。
        let link = displayLink(target: self, selector: #selector(onFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func onFrame() {
        if machine.tick(now: CACurrentMediaTime()) { applyCurrentStep() }
    }

    /// PET_TRACE_FRAMES=1 时把每次换帧的实际停留时间打出来，用于核对时序。
    private static let traceFrames = ProcessInfo.processInfo.environment["PET_TRACE_FRAMES"] == "1"
    private var lastFrameAt: Double = CACurrentMediaTime()

    private func applyCurrentStep() {
        let step = machine.step
        if Self.traceFrames {
            let now = CACurrentMediaTime()
            NSLog("[frame] %@/%@ 实际停留 %.0fms（表定 %.0fms）",
                  machine.state.rawValue, step.frame, (now - lastFrameAt) * 1000, step.ms)
            lastFrameAt = now
        }
        let onBreath = step.sheet == .sleepBreath
        breathLayer.isHidden = !onBreath
        posesLayer.isHidden = onBreath

        let sheet = onBreath ? manifest.sheets.sleepBreath : manifest.sheets.poses
        guard let index = sheet.index(of: step.frame) else { return }
        (onBreath ? breathLayer : posesLayer).contentsRect = sheet.unitRect(of: index)
    }

    // MARK: - 逐像素 alpha 命中测试

    /// 猫身上不透明的地方才算命中；透明边角返回 nil，事件穿透到下层应用。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return alpha(at: local) >= SpriteAlpha.hitThreshold ? self : nil
    }

    private func alpha(at point: NSPoint) -> CGFloat {
        let step = machine.step
        let onBreath = step.sheet == .sleepBreath
        let sheet = onBreath ? manifest.sheets.sleepBreath : manifest.sheets.poses
        let layer = onBreath ? breathLayer : posesLayer
        guard let index = sheet.index(of: step.frame), layer.frame.contains(point) else { return 0 }

        // 视图坐标（左下原点）→ 该帧内的像素坐标（左上原点）
        let inLayer = CGPoint(x: point.x - layer.frame.minX, y: point.y - layer.frame.minY)
        let px = inLayer.x / SpriteManifest.scale
        let py = sheet.frameHeight - inLayer.y / SpriteManifest.scale
        return (onBreath ? breathAlpha : posesAlpha)
            .alpha(inFrame: index, of: sheet, fx: px, fy: py)
    }

    // MARK: - 交互

    /// 按下后自己把鼠标事件**从队列里拉出来**，直到松手，不依赖 AppKit 把
    /// `mouseDragged` 派回本视图。
    ///
    /// 为什么不能靠派发：这个窗口**只有猫那么大**，还是个 `canBecomeKey == false` 的
    /// nonactivating panel，命中测试又是逐像素 alpha 的。快速拖动时猫的窗口总比光标慢一帧，
    /// 光标会瞬间甩到窗口之外——那一下的 drag 事件就不再落到这个视图上。**链子一断就再也接不回来**：
    /// 猫停在原地不动，而光标已经拉出去很远，松手后猫还在半路。用户报的"拖到很远猫只移动了一点"
    /// 就是它，且因为取决于甩手快慢，表现为"有时候"。
    ///
    /// `trackEvents` 在这里开一个嵌套事件循环，按下到松手之间的事件全部归我们，与光标在哪无关。
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let press = NSEvent.mouseLocation
        // 按下那一刻，光标相对窗口原点的偏移。拖动全程不变——猫就不会从光标下跑掉。
        let grabOffset = CGPoint(x: press.x - window.frame.origin.x,
                                 y: press.y - window.frame.origin.y)
        var didDrag = false

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { tracked, stop in
            guard let tracked else { stop.pointee = true; return }
            switch tracked.type {
            case .leftMouseDragged:
                let mouse = NSEvent.mouseLocation
                // 几像素的抖动不算拖拽，否则点一下猫经常被当成拖，气泡开不出来。
                if !didDrag, abs(mouse.x - press.x) <= 3, abs(mouse.y - press.y) <= 3 { return }
                didDrag = true
                // **绝对定位**：窗口原点 = 光标 − 按下时的偏移。
                // 不能用"每次加一个增量"——只要有一次被 clamp 修正过（拖到屏幕边缘就会），
                // 增量法会把那次的差额永久留下，猫从此落后光标一截。
                self.onDragTo?(CGPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y))
            case .leftMouseUp:
                stop.pointee = true
                if !didDrag { self.performClick() }
            default:
                break
            }
        }
    }

    /// 点击（真实的或调试注入的）。
    ///
    /// **改完状态必须立刻 applyCurrentStep()**：`click()` 把状态切到 waking、
    /// stepIndex 归零，但下一次 tick 要等第一帧到期（160ms）才返回 true。少了这一句，
    /// 那 160ms 里屏幕还停在睡觉那一帧，然后直接跳到起身的**第二个**姿势——
    /// 起身的第一个姿势 head-near-paws 永远不显示。用户报的"点击动画不对"就是它。
    func performClick() {
        let outcome = machine.click(now: CACurrentMediaTime())
        if outcome != .ignored { applyCurrentStep() }
        onClick?(outcome)
    }

    // MARK: - 外部状态

    func setBusy(_ busy: Bool) { machine.setBusy(busy, now: CACurrentMediaTime()) }
    func bubbleOpened() {
        machine.bubbleOpened(now: CACurrentMediaTime())
        applyCurrentStep()
    }
    var isAsleep: Bool { machine.state.isAsleep }
}
