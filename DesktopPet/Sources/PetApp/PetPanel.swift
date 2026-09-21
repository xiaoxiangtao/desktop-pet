import AppKit
import PetAnimation
import PetCore

/// 猫的窗口。**只有猫那么大**——这是本次重构 UI 层收益最大的一处。
///
/// 旧版把窗口拉成所有显示器 bounds 的并集、铺满整个虚拟屏幕，再用
/// `setIgnoreMouseEvents(true, {forward:true})` 整体穿透、需要交互时动态关掉。那带来三个问题：
///   1. 悬浮按钮的点击必须由主进程按光标矩形驱动穿透开关，不能靠渲染层 hover；
///   2. 输入法候选框会跑到全屏透明覆盖层**下面**；
///   3. 一张全屏透明层始终参与窗口合成。
/// 而且在 macOS 上它根本走不通——不加 `enableLargerThanScreen` 窗口会被砍成一块屏；
/// 加了之后，用户开着默认的「显示器各自使用单独的空间」时跨屏窗口压根不渲染
/// （见 [[修复桌宠跨屏落位与拖动边界]]）。
///
/// 窗口只有猫那么大之后，这些问题**整类消失**：猫以外的屏幕区域根本不是这个 app 的窗口，
/// 不存在"要不要穿透"的问题；猫自身透明边角的穿透由 `SpriteView.hitTest` 读像素 alpha 决定。
final class PetPanel: NSPanel {
    let sprite: SpriteView
    /// 猫挪窝时通知外部（气泡要跟着走）。
    var onMoved: ((CGRect) -> Void)?

    init(manifest: SpriteManifest) throws {
        let size = NSSize(width: manifest.displayWidth, height: manifest.displayHeight)
        sprite = try SpriteView(manifest: manifest)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver                     // 全屏应用之上
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false      // 拖拽自己实现，避免与点击判定打架
        ignoresMouseEvents = false
        contentView = sprite
        sprite.onDragTo = { [weak self] origin in self?.moveOrigin(to: origin) }
    }

    /// 点猫不该抢焦点——正在打字的应用不能因为逗猫而失去输入焦点。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 猫中心点所在的屏幕坐标，是位置的唯一真相。
    var centre: CGPoint {
        get { CGPoint(x: frame.midX, y: frame.midY) }
        set { setFrameOrigin(NSPoint(x: newValue.x - frame.width / 2, y: newValue.y - frame.height / 2)) }
    }

    /// 拖动时直接把窗口放到它该在的位置（绝对定位，见 `SpriteView.mouseDragged`）。
    private func moveOrigin(to origin: CGPoint) {
        centre = clamp(CGPoint(x: origin.x + frame.width / 2, y: origin.y + frame.height / 2))
        onMoved?(frame)
    }

    /// 按**整个桌面**（所有屏幕的并集）夹取。
    ///
    /// **不能按"猫当前所在的那块屏"夹取**——那样猫永远出不了它现在这块屏，
    /// 表现就是"无法拖动切换屏幕"（2026-09-14 实测踩到）。
    /// 正确做法：落在任何一块屏内就放行，只有掉进屏幕之间的空隙或整个桌面之外时，
    /// 才投影回最近那块屏，并留出边距保证还抓得回来。
    /// 对应 [[修复桌宠跨屏落位与拖动边界]] 定下的三条期望：开局在笔记本屏、
    /// 能拖到外接屏、不能拖出这两块区域。
    func clamp(_ point: CGPoint) -> CGPoint {
        DesktopGeometry.clamp(centre: point,
                              screens: NSScreen.screens.map(\.frame),
                              margin: min(frame.width, frame.height) / 3)
    }

    /// 猫开局待的地方：**笔记本屏**右下角一带，避开 Dock。
    ///
    /// 这里必须用 `NSScreen.screens.first`（带菜单栏、原点在 (0,0) 的那块，即用户说的
    /// "笔记本屏"），**不能用 `NSScreen.main`**——后者跟随光标或 key window，
    /// 启动时光标恰好在外接屏上，猫就会出现在外接屏。实测踩到过：两块屏（笔记本
    /// 0,0,1512,982 + 外接屏在其上方）时 `NSScreen.main` 返回的是外接屏，猫被放到了
    /// 那上面。[[修复桌宠跨屏落位与拖动边界]] 里用户明确要求过"启动时猫出现在笔记本屏"。
    func moveToDefaultSpot() {
        guard let screen = NSScreen.screens.first else { return }
        centre = clamp(DesktopGeometry.defaultSpot(inVisibleFrame: screen.visibleFrame, petSize: frame.size))
    }
}
