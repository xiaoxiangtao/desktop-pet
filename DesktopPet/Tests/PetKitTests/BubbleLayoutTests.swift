import Testing
import CoreGraphics
@testable import PetCore

private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let external = CGRect(x: -581, y: 982, width: 1920, height: 1080)
private let screens = [laptop, external]
private let bubble = CGSize(width: 400, height: 160)
private let petSize = CGSize(width: 161, height: 163)
private let gap: CGFloat = 6   // 实测旧版值

private func pet(at centre: CGPoint) -> CGRect {
    CGRect(x: centre.x - petSize.width / 2, y: centre.y - petSize.height / 2,
           width: petSize.width, height: petSize.height)
}

@Test func 气泡默认在猫的左下方() {
    // 从旧版运行中的界面上量出来的：气泡右边缘距猫左边缘 6px、顶边距猫底边 6px。
    // 我第一版凭感觉放在猫上方，用户一眼看出位置不对。
    let p = pet(at: CGPoint(x: 700, y: 500))          // 屏幕中间，四周都有地方
    let o = BubbleLayout.origin(petFrame: p, bubbleSize: bubble, screens: screens, gap: gap)
    let r = CGRect(origin: o, size: bubble)
    #expect(r.maxX == p.minX - gap, "气泡右边缘应在猫左边缘外侧 \(gap)px")
    #expect(r.maxY == p.minY - gap, "气泡顶边应在猫底边下方 \(gap)px")
}

@Test func 猫贴左边缘时气泡翻到右边() {
    // "猫在屏幕边缘时气泡翻转"这条规则，靠人肉把猫拖到角落才能发现，所以必须有测试
    let p = pet(at: CGPoint(x: 90, y: 300))
    let o = BubbleLayout.origin(petFrame: p, bubbleSize: bubble, screens: screens, gap: gap)
    #expect(o.x == p.maxX + gap, "左边放不下时应翻到猫的右侧")
    #expect(o.x >= laptop.minX)
}

@Test func 猫贴底部时气泡翻到上方() {
    let p = pet(at: CGPoint(x: 700, y: 90))
    let o = BubbleLayout.origin(petFrame: p, bubbleSize: bubble, screens: screens, gap: gap)
    #expect(o.y == p.maxY + gap, "下方放不下时应翻到猫上方")
}

@Test func 气泡永远不会有一半在屏外() {
    // 把猫放遍笔记本屏的每个角落，气泡必须始终完整落在某块屏内
    for x in stride(from: 90.0, through: 1420.0, by: 70.0) {
        for y in stride(from: 90.0, through: 900.0, by: 70.0) {
            let p = pet(at: CGPoint(x: x, y: y))
            let o = BubbleLayout.origin(petFrame: p, bubbleSize: bubble, screens: screens, gap: gap)
            let r = CGRect(origin: o, size: bubble)
            #expect(laptop.insetBy(dx: -1, dy: -1).contains(r),
                    "猫在 (\(x),\(y)) 时气泡跑出屏幕：\(r)")
        }
    }
}

@Test func 猫在外接屏时气泡也在外接屏() {
    let p = pet(at: CGPoint(x: 400, y: 1500))
    let o = BubbleLayout.origin(petFrame: p, bubbleSize: bubble, screens: screens, gap: gap)
    #expect(external.contains(CGRect(origin: o, size: bubble)), "气泡应跟着猫留在外接屏，实际 \(o)")
}

@Test func 找得到猫所在的那块屏() {
    #expect(BubbleLayout.hostScreen(of: pet(at: CGPoint(x: 700, y: 500)), in: screens) == laptop)
    #expect(BubbleLayout.hostScreen(of: pet(at: CGPoint(x: 400, y: 1500)), in: screens) == external)
}
