import Foundation
import CoreGraphics

/// 气泡相对猫的摆放。纯函数——放这里是因为「猫在屏幕边缘时气泡该翻到另一侧」
/// 这类规则只能靠把猫拖到角落一个个试，正是最该被测试覆盖的地方。
public enum BubbleLayout {
    /// 气泡的窗口原点。
    ///
    /// **默认在猫的左下方**，这是从旧版运行中的界面上量出来的：气泡右边缘距猫左边缘
    /// 6px、气泡顶边距猫底边 6px（实测 cat.x=675.8 / bubble 右边缘 669.8；
    /// cat 底 539.2 / bubble 顶 545.3）。我第一版凭感觉放在猫**上方**，位置整个不对。
    ///
    /// 规则，按优先级：
    /// 1. 默认贴猫的左下角（气泡右上角 ≈ 猫左下角，各留 gap）；
    /// 2. 左边放不下就翻到猫右侧；
    /// 3. 下边放不下就翻到猫上方；
    /// 4. 最后整体夹进猫所在的那块屏，保证不会有一半在屏外。
    public static func origin(petFrame: CGRect, bubbleSize: CGSize,
                              screens: [CGRect], gap: CGFloat) -> CGPoint {
        let host = hostScreen(of: petFrame, in: screens)

        // 1/2：横向——气泡右边缘贴在猫左边缘外侧
        var x = petFrame.minX - gap - bubbleSize.width
        if let h = host, x < h.minX {
            x = petFrame.maxX + gap                // 左边放不下，翻到猫右侧
        }

        // 3：纵向——气泡顶边贴在猫底边下方（AppKit y 向上，所以是 minY 往下减）
        var y = petFrame.minY - gap - bubbleSize.height
        if let h = host, y < h.minY {
            y = petFrame.maxY + gap                // 下边放不下，翻到猫上方
        }

        // 4：兜底夹进屏内
        if let h = host {
            x = min(max(x, h.minX), h.maxX - bubbleSize.width)
            y = min(max(y, h.minY), h.maxY - bubbleSize.height)
        }
        return CGPoint(x: x, y: y)
    }

    /// 猫（按中心点）所在的那块屏；不在任何屏内时取最近的一块。
    public static func hostScreen(of petFrame: CGRect, in screens: [CGRect]) -> CGRect? {
        guard !screens.isEmpty else { return nil }
        let centre = CGPoint(x: petFrame.midX, y: petFrame.midY)
        return screens.first { $0.contains(centre) }
            ?? screens.min { DesktopGeometry.squaredDistance(centre, $0) < DesktopGeometry.squaredDistance(centre, $1) }
    }
}
