import Foundation

/// 跑外部进程。抽成协议是为了让 `HermesCLIProvider` 能用一个**假的 hermes** 跑测试——
/// 方案 §5.3 要求的那件事：用 shell 脚本按环境变量回放 fixture（正常回复、
/// `No session found`、超时不退出、写 stderr、返回非零），这样在没有 Hermes 订阅的
/// 机器上也能测完整逻辑，顺带也验证了"可分发"这件事。
public protocol ProcessRunning: Sendable {
    func start(_ spec: ProcessSpec) throws -> RunningProcess
}

public struct ProcessSpec: Sendable {
    public let argv: [String]
    public let cwd: URL
    public let timeout: TimeInterval
    /// 额外环境变量，**显式传而不是 setenv**。进程级全局状态在并行测试里会互相污染——
    /// 本项目已经为此栽过两次（测试把夹具词写进真实 Anki / 欧路账号）。
    public let env: [String: String]

    public init(argv: [String], cwd: URL, timeout: TimeInterval, env: [String: String] = [:]) {
        self.argv = argv
        self.cwd = cwd
        self.timeout = timeout
        self.env = env
    }
}

public struct ProcessResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum ProcessError: Error, Equatable {
    case launchFailed
    case timedOut
}

public protocol RunningProcess: Sendable {
    func wait(timeout: TimeInterval) async throws -> ProcessResult
    /// 先 terminate，等不到就 kill。取消一次对话必须真正终止子进程，
    /// 否则 token 照烧而答案被丢弃（旧实现的老问题）。
    func stop(grace: TimeInterval) async
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func start(_ spec: ProcessSpec) throws -> RunningProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.argv[0])
        process.arguments = Array(spec.argv.dropFirst())
        process.currentDirectoryURL = spec.cwd
        if !spec.env.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(spec.env) { _, new in new }
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed
        }
        return SystemRunningProcess(process: process, out: out, err: err)
    }
}

private final class SystemRunningProcess: RunningProcess, @unchecked Sendable {
    private let process: Process
    /// 两个管道**从一开始就在后台读**，不是等进程退出再读：子进程输出超过管道缓冲
    /// （64KB）时，它写不进去就不会退出，而我们不读就一直等，双向死锁。
    ///
    /// 而且必须是独立的 Task 而不是 `async let`——`async let` 在作用域退出时会隐式
    /// await，于是**超时路径上抛错也要先等读完**，而读要等子进程死才 EOF。
    /// 实测因此干等了 300 秒（测试里那个 `sleep 300` 的假 hermes）。
    private let stdoutTask: Task<Data, Never>
    private let stderrTask: Task<Data, Never>

    init(process: Process, out: Pipe, err: Pipe) {
        self.process = process
        self.stdoutTask = Self.reader(out)
        self.stderrTask = Self.reader(err)
    }

    private static func reader(_ pipe: Pipe) -> Task<Data, Never> {
        Task.detached {
            await withCheckedContinuation { c in
                DispatchQueue.global().async {
                    c.resume(returning: (try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                }
            }
        }
    }

    func wait(timeout: TimeInterval) async throws -> ProcessResult {
        let exited: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [process] in
                await Self.waitForExit(process)
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        guard exited else {
            // 先把进程弄死，管道才会 EOF，读任务才收得了尾。
            await stop(grace: 0.5)
            throw ProcessError.timedOut
        }
        try Task.checkCancellation()
        return ProcessResult(stdout: String(decoding: await stdoutTask.value, as: UTF8.self),
                             stderr: String(decoding: await stderrTask.value, as: UTF8.self),
                             exitCode: process.terminationStatus)
    }

    /// 等进程退出。**必须保证 continuation 只被 resume 一次**：
    /// 进程可能正好在"装 terminationHandler"和"检查 isRunning"这两行之间退出，
    /// 于是两条路都触发，直接 `SWIFT TASK CONTINUATION MISUSE` 崩掉整个测试进程
    /// （2026-09-14 实测，signal 5）。
    private static func waitForExit(_ process: Process) async {
        let gate = ResumeGate()
        // **必须响应取消**：`withTaskGroup` 要等所有子任务结束才返回，而
        // `withCheckedContinuation` 本身不理会 `cancelAll()`。少了这层包装，
        // 超时后 group 会一直卡到进程真的退出为止——实测那个 `sleep 300` 的假 hermes
        // 让"1 秒超时"变成了干等 300 秒。真机上这等于"取消对话"会永久挂住。
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                gate.store(c)
                process.terminationHandler = { _ in gate.resume() }
                if !process.isRunning { gate.resume() }
            }
        } onCancel: {
            gate.resume()
        }
    }

    func stop(grace: TimeInterval) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            Log.warn("hermes 子进程在宽限期后被强杀")
        }
    }
}


/// 保证 continuation **恰好** resume 一次，无论是被进程退出、还是被取消触发。
/// 进程可能正好在"装 terminationHandler"和"检查 isRunning"之间退出，两条路都会触发；
/// 取消又是第三条路。resume 两次会直接 `SWIFT TASK CONTINUATION MISUSE` 崩进程。
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func store(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if done { lock.unlock(); c.resume(); return }   // 取消先到了
        continuation = c
        lock.unlock()
    }

    func resume() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
