import Foundation
import SQLite3

/// 够用就好的 sqlite3 封装。
///
/// **为什么不引第三方库**：这个 app 只做三件事——按主键查 ECDICT、读写自己的生词本、
/// 建表。引 GRDB/SQLite.swift 会给分发包加一个需要联网解析的依赖，而 macOS 自带
/// libsqlite3，`import SQLite3` 就能用。整层不到 120 行。
///
/// SQLITE_TRANSIENT 是必须的：传 nil 等价于 SQLITE_STATIC，意思是"这块内存我不动，
/// 你自己留着引用"。Swift 的 String 转出来的缓冲区在语句执行前就可能已经释放，
/// 于是绑定的参数变成随机字节——表现为查什么都查不到，且不报错。
public final class SQLiteDB: @unchecked Sendable {
    public enum Error: Swift.Error, LocalizedError {
        case open(String)
        case step(String)

        public var errorDescription: String? {
            switch self {
            case .open(let m):  "打开数据库失败：\(m)"
            case .step(let m):  "执行 SQL 失败：\(m)"
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private let lock = NSLock()

    public init(path: String, readOnly: Bool = false, createDirectories: Bool = false) throws {
        if createDirectories {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY
                             : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开 \(path)"
            if handle != nil { sqlite3_close_v2(handle) }
            handle = nil
            throw Error.open(message)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { if handle != nil { sqlite3_close_v2(handle) } }

    /// 一行的取值口。列名 → 值，全部当字符串取（ECDICT 的字段本来就都是文本，
    /// 生词本里唯一的数字是 id，用不到）。
    public struct Row {
        fileprivate let values: [String: String]
        public subscript(_ column: String) -> String? { values[column] }
        public func text(_ column: String) -> String { values[column] ?? "" }
    }

    @discardableResult
    public func execute(_ sql: String, _ bindings: [String?] = []) throws -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Error.step(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            if let value {
                sqlite3_bind_text(statement, position, value, -1, Self.transient)
            } else {
                sqlite3_bind_null(statement, position)
            }
        }

        var rows: [Row] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw Error.step(String(cString: sqlite3_errmsg(handle)))
            }
            var values: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, column) else { continue }
                guard let raw = sqlite3_column_text(statement, column) else { continue }
                values[String(cString: name)] = String(cString: raw)
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// 分号分隔的建表脚本。
    public func executeScript(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(error)
            throw Error.step(message)
        }
    }

    public var lastInsertRowID: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_changes(handle)
    }
}
