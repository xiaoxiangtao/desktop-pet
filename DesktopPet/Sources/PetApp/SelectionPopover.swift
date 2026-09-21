import AppKit
import SelectionKit
import PetCore

/// 划词浮标：在光标旁冒出一个小按钮，点它就把选中的词送去查。
///
/// **这是多面板架构最直接的收益之一**。旧版是一张铺满虚拟屏幕的透明穿透窗，
/// 所以浮标的点击"必须由主进程按光标矩形驱动 setIgnoreMouseEvents，不能依赖渲染层
/// hover"（[[评估系统级划词查词可行性]] 的原话）。现在浮标就是一个巴掌大的独立面板，
/// 点它就是点它，不需要任何穿透编排。
final class SelectionPopover: NSPanel {
    private static let chipSize = NSSize(width: 74, height: 30)
    /// 离光标的间距。放在右下方，**不要盖住刚选中的那段文字**。
    private static let gap = NSSize(width: 12, height: 10)
    /// 窗口比胶囊大出来的一圈，给自绘阴影留扩散空间。这圈完全透明且不接事件。
    private static let shadowPad: CGFloat = 10

    private let chip = ChipView(title: "查词", symbol: "text.magnifyingglass")
    private lazy var host = ShadowHost(chip: chip, inset: Self.shadowPad)
    private var onPick: ((String) -> Void)?
    private var text = ""
    private var hideTimer: Timer?

    init() {
        let panelSize = NSSize(width: Self.chipSize.width + Self.shadowPad * 2,
                               height: Self.chipSize.height + Self.shadowPad * 2)
        super.init(contentRect: NSRect(origin: .zero, size: panelSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // 系统给小面板画的窗口阴影又深又硬，还**没有任何参数可调**——
        // 它在胶囊底下压出的暗环看着就像边框变粗了。关掉，自己画一层淡的。
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true      // hover 高亮要用，非激活面板默认不收
        chip.onTap = { [weak self] in self?.tapped() }
        contentView = host
    }

    override var canBecomeKey: Bool { false }   // 浮标不该抢走用户正在编辑的焦点

    func present(text: String, at point: NSPoint, onPick: @escaping (String) -> Void) {
        self.text = text
        self.onPick = onPick
        let reappearing = !isVisible
        setFrameOrigin(Self.origin(near: point))
        if reappearing { alphaValue = 0 }
        orderFrontRegardless()
        if reappearing {
            // 直接"啪"地出现太生硬；淡入一下，但要短到不耽误点击。
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                animator().alphaValue = 1
            }
        }
        // 自己会消失，否则用户不点它就永远挂在屏幕上
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    /// 贴着屏幕边缘时翻到光标另一侧，否则浮标会被切掉一半——选屏幕右下角的词时必然遇到。
    ///
    /// 全程按**胶囊**算位置，最后再减掉 `shadowPad` 换成窗口原点——
    /// 拿窗口尺寸去算的话，那圈透明边会被当成浮标的一部分，位置整体偏掉。
    private static func origin(near point: NSPoint) -> NSPoint {
        var x = point.x + gap.width
        var y = point.y - gap.height - chipSize.height
        if let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame {
            if x + chipSize.width > visible.maxX { x = point.x - gap.width - chipSize.width }
            if y < visible.minY { y = point.y + gap.height }
            x = min(max(x, visible.minX), visible.maxX - chipSize.width)
            y = min(max(y, visible.minY), visible.maxY - chipSize.height)
        }
        return NSPoint(x: x - shadowPad, y: y - shadowPad)
    }

    func dismiss() {
        hideTimer?.invalidate()
        hideTimer = nil
        orderOut(nil)
    }

    private func tapped() {
        let picked = text
        dismiss()
        onPick?(picked)
    }
}

/// 药丸形的毛玻璃小按钮：连续圆角 + 一道随明暗模式走的细边 + hover 微高亮。
///
/// 不用 NSButton 的任何内建 bezel——`.rounded` 那种飘在任意应用之上时又厚又灰，
/// 跟 macOS 现在的浮层语言（毛玻璃胶囊）对不上。
/// 尺寸是固定的，所以直接摆 frame，不上 Auto Layout。
private final class ChipView: NSVisualEffectView {
    var onTap: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// 图标和文字挂在这一层，**不是直接挂在毛玻璃上**——见 `CrispContainer`。
    private let content = CrispContainer()
    private var hovering = false { didSet { refreshColours() } }

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        // `.menu` 比 `.popover` 透得多。`.popover` 压在浅色背景上会糊成一块灰饼，
        // 看不出后面有东西，也就没有"毛玻璃"可言。
        material = .menu
        blendingMode = .behindWindow        // 糊的是**背后那个应用**，不是自己
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous    // 苹果那种连续圆角，不是正圆弧
        // 0.5pt 在 Retina 上正好是一条物理像素的发丝线；1pt 会变成两像素的黑框，显得又厚又脏。
        layer?.borderWidth = 0.5

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.contentTintColor = .labelColor
        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        content.addSubview(icon)
        content.addSubview(label)
        addSubview(content)
        refreshColours()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2     // 半高 = 正胶囊
        content.frame = bounds

        // 用 sizeToFit 量、并把坐标取整：拿 intrinsicContentSize 摆出来的 frame 会差半像素，
        // 文字落在非整数位上就会被渲染成发虚、边上像缺一道的样子。
        let spacing: CGFloat = 5
        icon.sizeToFit()
        label.sizeToFit()
        let iconSize = icon.frame.size
        let textSize = label.frame.size
        var x = ((bounds.width - iconSize.width - spacing - textSize.width) / 2).rounded()
        icon.frame = NSRect(x: x, y: ((bounds.height - iconSize.height) / 2).rounded(),
                            width: iconSize.width, height: iconSize.height)
        x += iconSize.width + spacing
        label.frame = NSRect(x: x, y: ((bounds.height - textSize.height) / 2).rounded(),
                             width: textSize.width, height: textSize.height)
    }

    /// CGColor **不会**自己跟着明暗模式走，每次外观变了都要在当前绘制外观下重取。
    private func refreshColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            // 边缘的分离感交给阴影，这道线只负责**收一下口**，不能被看成一个框。
            // 0.5pt 已经是物理极限（再细就不是一条像素了），所以只能继续压对比度。
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
                                              : NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColours()
    }

    // MARK: - 交互

    /// 桌宠从不激活自己，所以**必须**收第一次点击，否则用户得点两下才有反应。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}     // 吃掉，不然会漏到下面的应用

    override func mouseUp(with event: NSEvent) {
        hovering = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
    }
}

/// 托着胶囊的透明壳，唯一职责是画一层**可调**的软阴影。
///
/// 阴影必须画在胶囊的**外面**，所以窗口得比胶囊大一圈（`shadowPad`），
/// 否则阴影会被窗口边界直接裁掉，看起来就是没有阴影。
/// 那一圈是透明的，`hitTest` 里让它不接事件——不然用户想点胶囊旁边的文字会点了个空。
private final class ShadowHost: NSView {
    private let chip: ChipView
    private let inset: CGFloat

    init(chip: ChipView, inset: CGFloat) {
        self.chip = chip
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        // 很淡、铺得开、只往下偏一点：让胶囊像浮着，而不是像被描了一圈黑边。
        layer?.shadowOpacity = 0.10
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(chip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        chip.frame = bounds.insetBy(dx: inset, dy: inset)
        // 给出明确的 shadowPath，省掉 Core Animation 每帧去反推 alpha 形状。
        layer?.shadowPath = CGPath(roundedRect: chip.frame,
                                   cornerWidth: chip.frame.height / 2,
                                   cornerHeight: chip.frame.height / 2,
                                   transform: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        chip.frame.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }
}

/// 图标和文字的容器，唯一职责是**关掉 vibrancy**。
///
/// 直接挂在 `NSVisualEffectView` 上的子视图会参与 vibrancy 混合，AppKit 把文字
/// 往背景里揉——看起来就是"文字发虚、像被蒙了一层"。关掉之后 label 按
/// `labelColor` 原样画，压在毛玻璃上才是清楚的。
private final class CrispContainer: NSView {
    override var allowsVibrancy: Bool { false }
}

/// 划词手势监听：鼠标左键松开时，看看是不是刚划选了一段文字。
///
/// 用 `CGEventTap`（listenOnly）只读事件流、不注入，比 uiohook 那类钩全部键盘的方案窄得多。
/// **需要辅助功能授权**——没授权时 tap 创建失败，这里只记日志并降级（划词不可用，
/// 其余功能照常），不弹窗骚扰用户。
/// `@unchecked Sendable` + 全程只在主线程动状态：CGEventTap 的回调来自事件线程，
/// 但它只读 `pressedAt` 并把真正的工作 dispatch 回主队列，没有跨线程写。
final class SelectionWatcher: @unchecked Sendable {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let reader = SelectionReader()
    private var onSelected: ((String, NSPoint) -> Void)?
    /// 用户在别处按下鼠标 = 之前那个选区多半没了，浮标该立刻收。
    private var onDismiss: (() -> Void)?
    /// 按下的位置。没拖动过就不是划词，是普通点击——不加这个判断，
    /// 用户每次点一下任何地方都会触发一次 ⌘C 兜底，剪贴板被反复冲刷。
    private var pressedAt: NSPoint?

    var isRunning: Bool { tap != nil }

    func start(onSelected: @escaping (String, NSPoint) -> Void,
               onDismiss: @escaping () -> Void = {}) -> Bool {
        guard tap == nil else { return true }
        self.onSelected = onSelected
        self.onDismiss = onDismiss

        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<SelectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            watcher.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.warn("划词监听启动失败——需要在系统设置里给「桌宠」勾上辅助功能")
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("划词监听已启动")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// 这个点是不是落在桌宠自己的某个面板上（猫、气泡、字幕、浮标）。
    @MainActor
    private static func isInsideOwnWindow(_ point: NSPoint) -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.frame.contains(point) }
    }

    /// 这个点是不是落在查词浮标上。只认浮标——点气泡、点猫都该把浮标收掉。
    @MainActor
    private static func isInsidePopover(_ point: NSPoint) -> Bool {
        NSApp.windows.contains { $0 is SelectionPopover && $0.isVisible && $0.frame.contains(point) }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let location = NSPoint(x: event.location.x,
                               y: (NSScreen.screens.first?.frame.height ?? 0) - event.location.y)
        switch type {
        case .leftMouseDown:
            pressedAt = location
            // **点了别处就立刻收浮标**。在这里做而不是另开一个全局监听：这个 tap
            // 本来就在收全局的左键按下事件。原先浮标只有两条消失路径——点它，或者
            // 4 秒定时器到期——所以取消选中之后它还会挂在屏幕上到计时结束（用户报的问题）。
            // 松手那一步的 `moved > 8 || clicks >= 2` 闸门会把"单击取消选中"整个挡掉，
            // 浮标根本等不到任何通知，所以只能在按下这一刻处理。
            //
            // 点在浮标自己身上不能收：`.listenOnly` 的 tap 先于应用拿到事件，
            // 收掉了这一下点击就送不到胶囊上，查词等于点不动。
            let dismiss = self.onDismiss
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !Self.isInsidePopover(location) else { return }
                    dismiss?()
                }
            }
        case .leftMouseUp:
            defer { pressedAt = nil }
            guard let from = pressedAt else { return }
            // 两种选词姿势都要认：
            //   - 拖过一段距离 = 划选；
            //   - 双击选词 / 三击选整行，位移接近 0，靠点击计数认。
            // 单击**一定不能**触发：否则每点一下任何地方都走一遍 ⌘C 兜底，
            // 把用户的剪贴板反复冲掉。
            let moved = abs(location.x - from.x) + abs(location.y - from.y)
            let clicks = event.getIntegerValueField(.mouseEventClickState)
            guard moved > 8 || clicks >= 2 else { return }
            // 读取要等一下：松开鼠标的瞬间，被点的应用还没把选区更新完。
            let reader = self.reader
            let handler = self.onSelected
            DispatchQueue.main.asyncAfter(deadline: .now() + SelectionReader.pasteboardSettleDelay) {
                MainActor.assumeIsolated {
                    // 起点在桌宠自己的窗口上 = 在拖猫（或在气泡里操作），不是划词。
                    // **必须拦在 reader.read() 之前**：拖猫也是一次超过 8px 的左键拖动，
                    // 不拦的话每拖一次猫都会朝当前聚焦的应用合成一次 ⌘C，把用户剪贴板冲掉，
                    // 还会在猫旁边弹出「查词」浮标。而且此时 AX 读到的是**别的应用**的选区
                    // ——我们的面板都是 canBecomeKey == false，拿不到焦点——读出来也是错的。
                    guard !Self.isInsideOwnWindow(from) else { return }
                    guard let selection = reader.read() else { return }
                    Log.info("划词（\(selection.source.rawValue)）：\(selection.text.prefix(40))")
                    handler?(selection.text, location)
                }
            }
        default:
            break
        }
    }
}
