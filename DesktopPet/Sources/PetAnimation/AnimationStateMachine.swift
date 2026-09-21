import Foundation

/// 猫的六态动画状态机，从前端 `sprite-pet.tsx` 逐条移植。
///
/// **时序是素材的一部分，不是可调参数**——每段 clip 的毫秒数取自各素材目录自带的
/// `animation.json`，只去掉了那些文件为循环预览加的首尾 sit 长驻（这里由外层状态承担该姿势）。
/// 移植时逐帧对照过，任何改动都应视为动画效果的变更而不是重构。
///
/// 这里不 import AppKit，也不自己读时钟：时间从外部传进来。这样整段时序可以在
/// `swift test` 里被逐帧断言，而不是只能靠肉眼看猫。

public enum PetState: String, Sendable, CaseIterable {
    case sleeping, waking, winking, sitting, yawning, fallingAsleep

    public var isAsleep: Bool { self == .sleeping || self == .fallingAsleep }
}

public struct Step: Sendable, Equatable {
    public enum Sheet: String, Sendable { case poses, sleepBreath }
    public let sheet: Sheet
    public let frame: String
    public let ms: Double
    /// 随机附加的等待上限，每次播放现抽。只用在 idle 长驻上，否则眨眼会像节拍器。
    public let jitterMs: Double

    public init(sheet: Sheet, frame: String, ms: Double, jitterMs: Double = 0) {
        self.sheet = sheet
        self.frame = frame
        self.ms = ms
        self.jitterMs = jitterMs
    }
}

public enum Clips {
    static func pose(_ frame: String, _ ms: Double, _ jitter: Double = 0) -> Step {
        Step(sheet: .poses, frame: frame, ms: ms, jitterMs: jitter)
    }

    public static let blink: [Step] = [
        pose("sit", 2400, 1600),
        pose("blink-half", 90),
        pose("blink-closed", 160),
        pose("blink-half", 110),
    ]

    public static let wink: [Step] = [
        pose("sit", 100),
        pose("wink-half", 60),
        pose("wink-closed", 150),
        pose("wink-half", 70),
        pose("sit", 100),
    ]

    public static let yawn: [Step] = [
        pose("yawn-half-eyes", 90),
        pose("yawn-closed", 100),
        pose("yawn-small-mouth", 240),
        pose("yawn-full", 950),
        pose("yawn-small-mouth", 240),
        pose("yawn-closed", 200),
        pose("yawn-half-eyes", 180),
    ]

    public static let sitToSleep: [Step] = [
        pose("start-moving", 130),
        pose("lowering", 130),
        pose("crouch", 140),
        pose("lying-head-up", 130),
        pose("head-lowering", 130),
        pose("head-near-paws", 130),
        pose("sleep", 200),
    ]

    /// 起身是同一串关键姿势倒放，且刻意比趴下慢——从睡梦里爬起来该显得费劲。
    public static let wake: [Step] = [
        pose("head-near-paws", 160),
        pose("head-lowering", 150),
        pose("lying-head-up", 150),
        pose("crouch", 150),
        pose("lowering", 150),
        pose("start-moving", 150),
    ]

    /// 呼吸循环 72 帧 @40ms = 2.88 秒。注意 `BREATH_STRIDE` 曾被设成 2 把它砍到 12.5fps，
    /// 2026-09-07 已按用户要求回滚到全部 72 帧 25fps，不要再抽帧。
    public static func sleepBreath(frameCount: Int) -> [Step] {
        (0..<frameCount).map { Step(sheet: .sleepBreath, frame: String(format: "breath-%02d", $0), ms: 40) }
    }
}

/// 每个状态播哪段 clip、播完去哪。`next == nil` 表示循环。
public struct StateSpec: Sendable {
    public let steps: [Step]
    public let next: PetState?
}

public struct AnimationStateMachine: Sendable {
    /// 气泡收起后多久打哈欠 / 多久趴下睡。
    public static let yawnAfter: Double = 5.0
    public static let sleepAfter: Double = 8.0

    public enum ClickOutcome: Sendable, Equatable {
        /// 叫醒睡着的猫这一下，绝不能同时把气泡关掉。
        case wakeAndOpenBubble
        case toggleBubble
        /// 猫正在起身，这一下不算数。没有这条的话：唤醒点击开了气泡，
        /// 起身动画还没播完时再点一下就把它关了，表现为"重复点击重复响应"。
        case ignored
    }

    private let specs: [PetState: StateSpec]
    private let jitter: @Sendable (Double) -> Double

    public private(set) var state: PetState
    public private(set) var stepIndex: Int
    /// 当前这一步的到期时刻（含本次抽到的 jitter）。
    private var stepDeadline: Double
    /// 「没事干」是从哪一刻开始的。锚在这里而不是锚在 state 上，
    /// 否则中间那次哈欠会把睡觉时间往后推。
    private var idleSince: Double?
    private var busy: Bool = false
    /// 本次空闲里**哈欠已经打过了**。
    ///
    /// 原版前端用的是 `setTimeout`——一次性触发，天然只打一次。移植成"每帧检查
    /// `elapsed >= 5 && state == .sitting`"之后，哈欠播完（2 秒）回到 sitting 时
    /// 这个条件**再次成立**，于是 5~8 秒之间会反复打哈欠（用户实测报的）。
    /// 所以要显式记住打过了，随 idle 锚点一起重置。
    private var yawnedThisIdle = false

    public var step: Step { specs[state]!.steps[stepIndex] }

    public init(breathFrameCount: Int,
                now: Double = 0,
                jitter: @escaping @Sendable (Double) -> Double = { Double.random(in: 0...$0) }) {
        self.specs = [
            .sleeping:      StateSpec(steps: Clips.sleepBreath(frameCount: breathFrameCount), next: nil),
            .waking:        StateSpec(steps: Clips.wake, next: .winking),
            .winking:       StateSpec(steps: Clips.wink, next: .sitting),
            .sitting:       StateSpec(steps: Clips.blink, next: nil),
            .yawning:       StateSpec(steps: Clips.yawn, next: .sitting),
            .fallingAsleep: StateSpec(steps: Clips.sitToSleep, next: .sleeping),
        ]
        self.jitter = jitter
        self.state = .sleeping          // 没人搭理时猫是睡着的
        self.stepIndex = 0
        self.stepDeadline = now + Clips.sleepBreath(frameCount: breathFrameCount)[0].ms / 1000
        self.idleSince = nil
    }

    /// 由 CADisplayLink 每帧调用。返回 true 表示该重画了。
    @discardableResult
    public mutating func tick(now: Double) -> Bool {
        var changed = false
        if now >= stepDeadline {
            advanceStep(now: now)
            changed = true
        }
        if checkIdleTimers(now: now) { changed = true }
        return changed
    }

    private mutating func advanceStep(now: Double) {
        let spec = specs[state]!
        let nextIndex = stepIndex + 1
        if nextIndex >= spec.steps.count {
            if let next = spec.next {
                enter(next, now: now)
                return
            }
            stepIndex = 0                // 没有后继就循环
        } else {
            stepIndex = nextIndex
        }
        scheduleDeadline(from: now)
    }

    private mutating func enter(_ newState: PetState, now: Double) {
        let wasAwake = !state.isAsleep
        state = newState
        stepIndex = 0
        scheduleDeadline(from: now)
        // **只在「醒/睡」这个布尔翻转时重置 idle 锚点**，不是每次状态切换都重置。
        // 原版前端的 effect 依赖的是 `[busy, awake]` 两个布尔值，而 sitting ↔ yawning
        // 都是「醒着」，所以不会重置。移植时若照搬成"每次 enter 都刷新"，
        // yawning→sitting 会把 idle 计时清零，猫就永远睡不着了（本条有测试守着）。
        if wasAwake != !newState.isAsleep { refreshIdleAnchor(now: now) }
    }

    private mutating func scheduleDeadline(from now: Double) {
        let s = step
        stepDeadline = now + (s.ms + (s.jitterMs > 0 ? jitter(s.jitterMs) : 0)) / 1000
    }

    /// 只在 sitting 上计时；哈欠与趴下都从同一个 idle 锚点算起。
    private mutating func checkIdleTimers(now: Double) -> Bool {
        guard let since = idleSince else { return false }
        let elapsed = now - since
        if elapsed >= Self.sleepAfter, state == .sitting || state == .yawning {
            enter(.fallingAsleep, now: now)
            return true
        }
        if elapsed >= Self.yawnAfter, state == .sitting, !yawnedThisIdle {
            yawnedThisIdle = true       // 一次空闲只打一个哈欠
            enter(.yawning, now: now)   // 醒→醒，enter 不会动 idle 锚点，睡觉时刻不受影响
            return true
        }
        return false
    }

    private mutating func refreshIdleAnchor(now: Double) {
        idleSince = (busy || state.isAsleep) ? nil : now
        yawnedThisIdle = false          // 新一轮空闲，哈欠额度重置
    }

    /// 气泡开着、或 AI 正在回复，都算「有事」，此时猫不该犯困。
    public mutating func setBusy(_ value: Bool, now: Double) {
        guard value != busy else { return }
        busy = value
        refreshIdleAnchor(now: now)
    }

    /// 字幕之类也能自己把气泡顶起来，这时猫也该醒着。
    public mutating func bubbleOpened(now: Double) {
        if state.isAsleep { enter(.waking, now: now) }
    }

    public mutating func click(now: Double) -> ClickOutcome {
        // 起身 + 眨眼致意是**一条完整的迎接动作**（waking → winking → sitting），
        // 全程不响应点击。只挡 waking 不够：用户在 winking 期间再点一下，
        // 就会把唤醒那一下刚开的气泡关掉，表现为"连续点击会乱"。
        if state == .waking || state == .winking { return .ignored }
        if state.isAsleep {
            enter(.waking, now: now)
            return .wakeAndOpenBubble
        }
        return .toggleBubble
    }
}
