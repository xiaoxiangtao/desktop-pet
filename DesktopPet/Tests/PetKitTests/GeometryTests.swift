import Testing
import CoreGraphics
@testable import PetCore

/// 用户本机的真实布局：笔记本屏在原点，外接屏在它**上方**且左右都探出去一截。
/// 这个布局是真的（2026-09-14 实测 NSScreen），不是编的——外接屏 x 从 -581 开始，
/// 比笔记本屏宽，所以两块屏的并集不是矩形，正是 clamp 容易写错的形状。
private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let external = CGRect(x: -581, y: 982, width: 1920, height: 1080)
private let screens = [laptop, external]
private let margin: CGFloat = 53.67          // min(161,163)/3

@Test func 猫可以待在笔记本屏内() {
    let p = CGPoint(x: 1351, y: 163)
    #expect(DesktopGeometry.clamp(centre: p, screens: screens, margin: margin) == p)
}

@Test func 猫可以被拖到外接屏() {
    // 这条就是"无法拖动切换屏幕"那个 bug 的回归测试：
    // 旧实现按"当前所在那块屏"夹取，这个点会被拽回笔记本屏，猫永远过不去。
    let p = CGPoint(x: 500, y: 1500)         // 外接屏正中一带
    #expect(DesktopGeometry.clamp(centre: p, screens: screens, margin: margin) == p)
}

@Test func 跨越两屏交界处时不被弹回() {
    // 笔记本屏顶边 y=982 正好是外接屏底边。逐点扫过交界，中途不能有任何一点被改写。
    for y in stride(from: 900.0, through: 1100.0, by: 10.0) {
        let p = CGPoint(x: 700, y: y)
        #expect(DesktopGeometry.clamp(centre: p, screens: screens, margin: margin) == p,
                "y=\(y) 处被弹开了，猫过不了交界")
    }
}

@Test func 掉进屏幕之间的空隙会被拉回最近那块屏() {
    // 笔记本屏右上方那块区域：x=1450 超出外接屏右边界(1339)，y=1100 超出笔记本屏顶(982)，
    // 两块屏都不包含 → 必须投影回去，否则猫会消失在无人区。
    let p = CGPoint(x: 1450, y: 1100)
    let c = DesktopGeometry.clamp(centre: p, screens: screens, margin: margin)
    #expect(c != p)
    #expect(screens.contains { $0.insetBy(dx: -1, dy: -1).contains(c) }, "夹取后应落在某块屏内，实际 \(c)")
}

@Test func 拖出整个桌面之外会被拉回并留出边距() {
    let c = DesktopGeometry.clamp(centre: CGPoint(x: 9999, y: -9999), screens: screens, margin: margin)
    #expect(c.x <= laptop.maxX - margin)
    #expect(c.y >= laptop.minY + margin)
}

@Test func 单屏时也不会把猫卡死() {
    let only = [laptop]
    let inside = CGPoint(x: 700, y: 500)
    #expect(DesktopGeometry.clamp(centre: inside, screens: only, margin: margin) == inside)
}

@Test func 默认位置在笔记本屏右下角() {
    let spot = DesktopGeometry.defaultSpot(inVisibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
                                           petSize: CGSize(width: 161, height: 163))
    #expect(spot == CGPoint(x: 1351, y: 163))
    #expect(laptop.contains(spot), "默认位置必须落在笔记本屏内")
}
