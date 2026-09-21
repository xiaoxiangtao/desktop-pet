import Testing
import Foundation
@testable import PetAnimation

/// 方案 Stage 1 的验收标准之一是「动画时序与旧版逐帧比对」。这一组测试就是那条标准的
/// 可执行版本：时序来自素材，改了就该在这里挂掉，而不是等肉眼发现猫的节奏不对。

/// 把 jitter 固定成 0，时序才可断言；真机上 idle 长驻要靠 jitter 避免眨眼像节拍器。
private func machine(now: Double = 0) -> AnimationStateMachine {
    AnimationStateMachine(breathFrameCount: 72, now: now, jitter: { _ in 0 })
}

/// 从 `now` 起推进到 `until`，每 1/60 秒 tick 一次（模拟 CADisplayLink），
/// 返回途中经过的状态序列。
@discardableResult
private func run(_ m: inout AnimationStateMachine, from now: Double, to until: Double) -> [PetState] {
    var seen: [PetState] = [m.state]
    var t = now
    while t < until {
        t += 1.0 / 60
        m.tick(now: t)
        if seen.last != m.state { seen.append(m.state) }
    }
    return seen
}

@Test func 初始状态是睡着的() {
    let m = machine()
    #expect(m.state == .sleeping)
    #expect(m.step.sheet == .sleepBreath)
    #expect(m.step.frame == "breath-00")
}

@Test func 呼吸循环是72帧40毫秒且不会自己退出() {
    var m = machine()
    #expect(Clips.sleepBreath(frameCount: 72).count == 72)
    #expect(Clips.sleepBreath(frameCount: 72).allSatisfy { $0.ms == 40 })
    // 2.88 秒跑完一轮后应当回到第 0 帧，而不是切去别的状态
    run(&m, from: 0, to: 3.0)
    #expect(m.state == .sleeping, "没人叫醒它就该一直睡")
}

@Test func 点击睡着的猫会唤醒并开气泡而不是切换气泡() {
    var m = machine()
    #expect(m.click(now: 1.0) == .wakeAndOpenBubble)
    #expect(m.state == .waking)
}

@Test func 点击醒着的猫是切换气泡() {
    var m = machine()
    _ = m.click(now: 0)                       // → waking
    run(&m, from: 0, to: 3.0)                 // waking → winking → sitting
    #expect(m.state == .sitting)
    #expect(m.click(now: 3.0) == .toggleBubble)
}

@Test func 唤醒链路是wake然后wink最后坐定() {
    var m = machine()
    #expect(m.state == .sleeping)
    _ = m.click(now: 0)                       // click 当场就切到 waking，所以起点不再是 sleeping
    let seen = run(&m, from: 0, to: 3.0)
    #expect(seen == [.waking, .winking, .sitting])
}

@Test func 起身是趴下的倒放且每个姿势停得更久() {
    // "climbing up out of sleep should look like effort" —— 前端注释里的刻意设计，
    // 移植时容易被当成随手写的数字改掉。
    //
    // 不能比总时长：sitToSleep 结尾多一个 `sleep` 200ms 长驻，那是睡着状态的姿势、
    // 不属于过渡动作。要比的是每个过渡姿势的停留时间。
    let down = Array(Clips.sitToSleep.dropLast())
    #expect(down.map(\.frame).reversed() == Clips.wake.map(\.frame), "起身应当是趴下的逐帧倒放")

    let upAvg = Clips.wake.reduce(0) { $0 + $1.ms } / Double(Clips.wake.count)
    let downAvg = down.reduce(0) { $0 + $1.ms } / Double(down.count)
    #expect(upAvg > downAvg, "每个过渡姿势：起身 \(upAvg)ms 应当慢于趴下 \(downAvg)ms")
}

@Test func 空闲5秒打哈欠8秒趴下且哈欠不推迟睡觉() {
    var m = machine()
    // 真实流程：点猫 → 猫醒 + 气泡打开（busy），倒计时此时是停的
    #expect(m.click(now: 0) == .wakeAndOpenBubble)
    m.setBusy(true, now: 0)
    run(&m, from: 0, to: 3.0)
    #expect(m.state == .sitting)

    run(&m, from: 3.0, to: 20.0)
    #expect(m.state == .sitting, "气泡开着期间不该犯困")

    // 气泡收起，倒计时从这一刻开始
    let idleStart = 20.0
    m.setBusy(false, now: idleStart)

    run(&m, from: idleStart, to: idleStart + 5.2)
    #expect(m.state == .yawning, "空闲 5 秒该打哈欠，实际 \(m.state)")

    // 关键断言：哈欠(2.0s)播完会回到 sitting，但**不能**把睡觉时刻往后推。
    // 移植时如果照搬成"每次状态切换都重置 idle 锚点"，这里就会一直是 sitting。
    run(&m, from: idleStart + 5.2, to: idleStart + 8.2)
    #expect(m.state == .fallingAsleep, "空闲 8 秒该趴下（哈欠不应推迟它），实际 \(m.state)")
}

@Test func 有事的时候不犯困() {
    var m = machine()
    _ = m.click(now: 0)
    run(&m, from: 0, to: 3.0)
    m.setBusy(true, now: 3.0)                 // 气泡开着 / AI 正在回复
    run(&m, from: 3.0, to: 20.0)
    #expect(m.state == .sitting, "有事时不该睡，实际 \(m.state)")
}

@Test func 趴下之后进入睡眠循环() {
    var m = machine()
    _ = m.click(now: 0)
    m.setBusy(true, now: 0)
    run(&m, from: 0, to: 3.0)
    m.setBusy(false, now: 3.0)                // 气泡收起，倒计时开始
    run(&m, from: 3.0, to: 3.0 + 8.0 + 1.5)   // 8s 趴下 + sitToSleep 全程 0.99s
    #expect(m.state == .sleeping)
    #expect(m.step.sheet == .sleepBreath)
}

@Test func 气泡被字幕顶开时猫会醒() {
    var m = machine()
    m.bubbleOpened(now: 1.0)
    #expect(m.state == .waking)
}

// MARK: - 雪碧图清单

@Test func 清单能加载且几何与前端一致() throws {
    let manifest = try SpriteManifest.load()
    #expect(manifest.petBox.width == 382)
    #expect(manifest.petBox.height == 387)
    #expect(SpriteManifest.scale == 0.42)
    // 前端导出的 PET_DISPLAY_WIDTH/HEIGHT，气泡锚点与拖拽夹取都依赖它
    #expect(abs(manifest.displayWidth - 160.44) < 0.01)
    #expect(abs(manifest.displayHeight - 162.54) < 0.01)
}

@Test func 呼吸图带偏移要贴回画布盒() throws {
    let breath = try SpriteManifest.load().sheets.sleepBreath
    // 睡姿只占画布下半，图被裁过，所以渲染时必须按 offset 贴回去，否则猫会浮在半空
    #expect(breath.offsetX == 1)
    #expect(breath.offsetY == 163)
    #expect(breath.frameWidth == 379)
    #expect(breath.frameHeight == 222)
    #expect(breath.frames.count == 72)
}

@Test func 每个动画步骤引用的帧名都真实存在() throws {
    // 渲染端按帧名索引而不是下标，所以帧名写错在运行期才会暴露——这条把它提前到测试期。
    let sheets = try SpriteManifest.load().sheets
    let clips: [String: [Step]] = [
        "blink": Clips.blink, "wink": Clips.wink, "yawn": Clips.yawn,
        "sitToSleep": Clips.sitToSleep, "wake": Clips.wake,
        "sleepBreath": Clips.sleepBreath(frameCount: sheets.sleepBreath.frames.count),
    ]
    for (name, steps) in clips {
        for step in steps {
            let sheet = step.sheet == .poses ? sheets.poses : sheets.sleepBreath
            #expect(sheet.index(of: step.frame) != nil,
                    "clip \(name) 引用了不存在的帧 \(step.frame)")
        }
    }
}

@Test func 雪碧图切帧坐标算得对() throws {
    let poses = try SpriteManifest.load().sheets.poses
    #expect(poses.columns == 4)
    #expect(poses.origin(of: 0) == (0, 0))
    #expect(poses.origin(of: 3) == (1146, 0))      // 第一行最后一格
    #expect(poses.origin(of: 4) == (0, 387))       // 换行
    #expect(poses.imageName == "cat-poses.webp")   // manifest 里带 sprites/ 前缀，bundle 是扁平的
}

// MARK: - 逐像素命中测试（透明边角必须穿透）

@Test func 猫的四角透明而身体不透明() throws {
    // 旧版 Electron 只能"整窗二选一"穿透，多面板架构换来的是逐像素精度。
    // 视觉效果没法自动验收，但"边角是不是真透明"可以。
    let sheets = try SpriteManifest.load().sheets
    let alpha = try SpriteAlpha(bundleResource: sheets.poses.imageName)
    let sit = try #require(sheets.poses.index(of: "sit"))
    let w = sheets.poses.frameWidth, h = sheets.poses.frameHeight

    for (name, fx, fy) in [("左上", 3.0, 3.0), ("右上", w - 3, 3.0),
                           ("左下", 3.0, h - 3), ("右下", w - 3, h - 3)] {
        #expect(!alpha.isHit(inFrame: sit, of: sheets.poses, fx: fx, fy: fy),
                "sit 帧的\(name)角应当是透明的，点击要穿透下去")
    }
}

@Test func 猫身体中心是实心的() throws {
    let sheets = try SpriteManifest.load().sheets
    let alpha = try SpriteAlpha(bundleResource: sheets.poses.imageName)
    let sit = try #require(sheets.poses.index(of: "sit"))
    // 坐姿的猫身体占据画布中下部；取中心偏下一点，避开耳朵之间的空隙
    let value = alpha.alpha(inFrame: sit, of: sheets.poses,
                            fx: sheets.poses.frameWidth / 2, fy: sheets.poses.frameHeight * 0.65)
    #expect(value >= SpriteAlpha.hitThreshold, "猫身体中心应当吃点击，实测 alpha=\(value)")
}

@Test func 睡姿帧的上半部是空的() throws {
    // sleepBreath 是裁过的一条下半带，其自身画布内上方仍有空白；
    // 渲染时按 offsetY=163 贴回画布盒，所以睡着时猫上方那片区域必须穿透。
    let sheets = try SpriteManifest.load().sheets
    let alpha = try SpriteAlpha(bundleResource: sheets.sleepBreath.imageName)
    let f0 = try #require(sheets.sleepBreath.index(of: "breath-00"))
    #expect(!alpha.isHit(inFrame: f0, of: sheets.sleepBreath,
                         fx: sheets.sleepBreath.frameWidth / 2, fy: 3),
            "睡姿帧顶端应当是透明的")
    let body = alpha.alpha(inFrame: f0, of: sheets.sleepBreath,
                           fx: sheets.sleepBreath.frameWidth / 2, fy: sheets.sleepBreath.frameHeight * 0.7)
    #expect(body >= SpriteAlpha.hitThreshold, "睡着的猫身体应当吃点击，实测 alpha=\(body)")
}

@Test func 起身过程中的点击被忽略() {
    // 唤醒那一下已经开了气泡；起身动画还在播时再点一下若按"切换"处理，
    // 就会立刻把刚开的气泡关掉——用户报的"重复点击重复响应"。
    var m = machine()
    #expect(m.click(now: 0) == .wakeAndOpenBubble)
    #expect(m.state == .waking)
    #expect(m.click(now: 0.3) == .ignored, "起身中不该响应")
    #expect(m.click(now: 0.8) == .ignored)
    #expect(m.state == .waking, "被忽略的点击不能改状态")

    run(&m, from: 0, to: 3.0)                 // 起身播完
    #expect(m.state == .sitting)
    #expect(m.click(now: 3.0) == .toggleBubble, "坐定之后点击恢复正常")
}

@Test func 气泡开着时猫一直醒着不会自己睡回去() {
    // 用户报的"点击后猫的动作太快"：真因是气泡状态没喂回状态机，
    // 猫以为没人理它，醒来 5 秒打哈欠 8 秒就趴下了。
    var m = machine()
    _ = m.click(now: 0)
    m.setBusy(true, now: 0)                   // 气泡打开
    run(&m, from: 0, to: 60.0)
    #expect(m.state == .sitting, "气泡开着 60 秒后猫仍该醒着，实际 \(m.state)")
}

@Test func contentsRect的y轴是下原点必须翻行() throws {
    // 这条搞反会让整张雪碧图上下镜像：sit(第0行) 画成 lying-head-up(第3行)，
    // 每个动作看起来都不对，而状态机日志毫无异常。2026-09-14 真实踩过。
    let poses = try SpriteManifest.load().sheets.poses
    #expect(poses.rows == 4)

    let sit = try #require(poses.index(of: "sit"))          // 索引 0，第 0 行（最上面）
    let r0 = poses.unitRect(of: sit)
    #expect(r0.minY == 0.75, "第 0 行（顶行）在下原点系里 y 应为 (4-1-0)/4 = 0.75，实际 \(r0.minY)")
    #expect(r0.minX == 0)

    let sleep = try #require(poses.index(of: "sleep"))      // 索引 15，第 3 行（最下面）
    let r3 = poses.unitRect(of: sleep)
    #expect(r3.minY == 0, "第 3 行（底行）y 应为 0，实际 \(r3.minY)")
    #expect(r3.minX == 0.75)

    // 顶行与底行必须落在相反的两端——写反了这两个值会互换
    #expect(r0.minY > r3.minY)
}

@Test func 呼吸图的行翻转同样成立() throws {
    let breath = try SpriteManifest.load().sheets.sleepBreath
    #expect(breath.rows == 12)                              // 72 帧 / 6 列
    #expect(breath.unitRect(of: 0).minY == 11.0 / 12)       // 第 0 帧在顶行
    #expect(breath.unitRect(of: 71).minY == 0)              // 最后一帧在底行
}

@Test func 一次空闲只打一个哈欠() {
    // 原版用 setTimeout 天然只触发一次；移植成每帧轮询后，哈欠播完回到 sitting
    // 会让「elapsed >= 5 && state == .sitting」再次成立，于是反复打哈欠。
    var m = machine()
    _ = m.click(now: 0)
    m.setBusy(true, now: 0)
    run(&m, from: 0, to: 3.0)
    #expect(m.state == .sitting)

    let idleStart = 20.0
    run(&m, from: 3.0, to: idleStart)
    m.setBusy(false, now: idleStart)

    // 从空闲开始一路推到趴下，数一数进了几次 yawning
    var yawns = 0
    var previous = m.state
    var t = idleStart
    while t < idleStart + 8.5 {
        t += 1.0 / 60
        m.tick(now: t)
        if m.state == .yawning && previous != .yawning { yawns += 1 }
        previous = m.state
    }
    #expect(yawns == 1, "空闲到趴下之间只该打一个哈欠，实际 \(yawns) 个")
    #expect(m.state == .fallingAsleep, "8 秒后仍该按时趴下")
}

@Test func 重新变忙再空闲会重新获得一次哈欠() {
    var m = machine()
    _ = m.click(now: 0)
    m.setBusy(true, now: 0)
    run(&m, from: 0, to: 3.0)

    // 第一轮空闲：打一次哈欠，然后被打断
    m.setBusy(false, now: 3.0)
    run(&m, from: 3.0, to: 3.0 + 5.5)
    #expect(m.state == .yawning)
    m.setBusy(true, now: 3.0 + 5.5)          // 用户又说话了
    run(&m, from: 3.0 + 5.5, to: 20.0)
    #expect(m.state == .sitting)

    // 第二轮空闲：哈欠额度应当重置
    m.setBusy(false, now: 20.0)
    run(&m, from: 20.0, to: 20.0 + 5.5)
    #expect(m.state == .yawning, "新一轮空闲该重新打哈欠，实际 \(m.state)")
}
