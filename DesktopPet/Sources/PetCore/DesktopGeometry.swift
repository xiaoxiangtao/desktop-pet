import Foundation
import CoreGraphics

/// 多显示器几何。纯函数，不碰 NSScreen——于是"猫能不能拖到另一块屏"这件事可以被测试。
///
/// 这层存在的理由就是 2026-09-14 踩的那个坑：clamp 原本写在 AppKit 层、按"猫当前所在的
/// 那块屏"夹取，结果猫永远出不了它现在这块屏。逻辑一旦长在 UI 层就只能靠人肉拖一遍才发现。
public enum DesktopGeometry {
    /// 把猫的中心点夹进「所有屏幕的并集」。
    ///
    /// - 落在**任何一块**屏内 → 原样放行。这是能跨屏拖动的前提。
    /// - 掉进屏幕之间的空隙、或整个桌面之外 → 投影回最近那块屏，并留 `margin` 边距，
    ///   保证猫还抓得回来（对应"不能拖出这两块区域"）。
    public static func clamp(centre: CGPoint, screens: [CGRect], margin: CGFloat) -> CGPoint {
        guard !screens.isEmpty else { return centre }
        if screens.contains(where: { $0.contains(centre) }) { return centre }
        guard let nearest = screens.min(by: { squaredDistance(centre, $0) < squaredDistance(centre, $1) })
        else { return centre }
        return CGPoint(x: min(max(centre.x, nearest.minX + margin), nearest.maxX - margin),
                       y: min(max(centre.y, nearest.minY + margin), nearest.maxY - margin))
    }

    /// 点到矩形的平方距离；点在矩形内时为 0。
    public static func squaredDistance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// 猫开局的位置：**带菜单栏那块屏**（原点在 (0,0)，用户说的"笔记本屏"）的右下角。
    /// 调用方要传 `screens.first` 的 visibleFrame，**不是 `NSScreen.main`**——
    /// 后者跟随光标，启动时光标在外接屏上猫就会生在外接屏。
    public static func defaultSpot(inVisibleFrame v: CGRect, petSize: CGSize) -> CGPoint {
        CGPoint(x: v.maxX - petSize.width, y: v.minY + petSize.height)
    }
}
