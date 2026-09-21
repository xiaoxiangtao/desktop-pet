import Foundation
import PetCore

/// 下载 ECDICT 并在本机建成查词用的 SQLite。
///
/// **为什么不把词典打进安装包**：ECDICT 建好是 100 MB 出头，压进 DMG 会让下载从
/// 几 MB 变成上百 MB，而大部分人可能根本不用查词。所以做成向导里的一次性下载。
///
/// **为什么下 CSV 而不是官方的 sqlite release**：官方 `ecdict-sqlite-28.zip` 是 217 MB，
/// 解开约 700 MB，里头 13 个字段我们只用 6 个。CSV 是 66 MB，自己建库还能顺手
/// 只留用得上的列、建好 NOCASE 索引。代价是要在本地跑一遍导入（约 770k 行）。
///
/// ECDICT 是 MIT 协议且**要求署名**——见「关于桌宠」和 THIRD_PARTY.md，那是法律义务。
public actor DictionaryInstaller {
    public struct Progress: Sendable {
        public let stage: String
        /// 0…1；无法估算时为 nil（导入阶段行数未知前就是这样）。
        public let fraction: Double?
    }

    public enum InstallError: LocalizedError {
        case download(String)
        case badCSV(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .download(let m): "下载词典失败：\(m)"
            case .badCSV(let m):   "词典文件不对劲：\(m)"
            case .cancelled:       "已取消"
            }
        }
    }

    /// 固定在 master 分支的 CSV。ECDICT 更新不频繁，而"钉住一个已知能用的地址"
    /// 比"自动追最新"更适合一个用户点一次就不再管的下载。
    public static let csvURL = URL(string: "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv")!
    /// 上面那份 CSV 的大致大小，只用来算下载进度条；服务器给了 Content-Length 就用真的。
    static let approximateCSVBytes: Int64 = 66_000_000

    public init() {}

    public func install(destination: URL = Paths.dictionary,
                        onProgress: @escaping @Sendable (Progress) -> Void) async throws {
        onProgress(Progress(stage: "正在下载词典…", fraction: 0))
        let csv = try await download(onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: csv) }

        onProgress(Progress(stage: "正在建立本地词典…", fraction: nil))
        // **先建到临时文件再原子替换**：导入要跑几十秒，中途退出留下半张表的话，
        // 下次启动查词会静默地查不到东西——那比"词典没装"难排查得多。
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("ecdict.building.sqlite3")
        try? FileManager.default.removeItem(at: staging)
        try buildDatabase(from: csv, to: staging, onProgress: onProgress)

        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        onProgress(Progress(stage: "词典已就绪", fraction: 1))
        Log.info("词典安装完成：\(destination.path)")
    }

    // MARK: - 下载

    private func download(onProgress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: Self.csvURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InstallError.download("服务器返回 \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let total = http.expectedContentLength > 0 ? http.expectedContentLength : Self.approximateCSVBytes
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ecdict-\(UUID().uuidString).csv")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else {
            throw InstallError.download("写不了临时文件")
        }
        defer { try? handle.close() }

        // 逐块写盘而不是整份读进内存：66 MB 全驻留没必要，且进度条要的就是这个循环。
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let fraction = min(Double(written) / Double(total), 0.999)
                // 每挪动 1% 才回报一次，不然进度回调本身成了瓶颈。
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    onProgress(Progress(stage: "正在下载词典…", fraction: fraction))
                }
            }
            try Task.checkCancellation()
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        return temp
    }

    // MARK: - 建库

    func buildDatabase(from csv: URL, to destination: URL,
                       onProgress: @escaping @Sendable (Progress) -> Void) throws {
        let db = try SQLiteDB(path: destination.path, createDirectories: true)
        // 导入期关掉同步写、把日志放内存：这是一次性的批量写，中途崩了重来就是，
        // 不值得为每一行付一次 fsync（实测能把 770k 行从几分钟压到几十秒）。
        try db.executeScript("""
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE ecdict (
                word        TEXT PRIMARY KEY COLLATE NOCASE,
                phonetic    TEXT,
                definition  TEXT,
                translation TEXT,
                pos         TEXT,
                exchange    TEXT,
                frq         INTEGER
            );
            BEGIN;
            """)

        let text = try String(contentsOf: csv, encoding: .utf8)
        var parser = CSVParser(text: text)
        guard let header = parser.nextRow() else { throw InstallError.badCSV("文件是空的") }
        // 按**列名**取下标，不写死位置：ECDICT 加过列，写死下标会静默错位。
        let index = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        guard let wordAt = index["word"] else { throw InstallError.badCSV("没有 word 列") }
        func field(_ row: [String], _ name: String) -> String? {
            guard let i = index[name], i < row.count else { return nil }
            return row[i].isEmpty ? nil : row[i]
        }

        var rows = 0
        while let row = parser.nextRow() {
            guard wordAt < row.count, !row[wordAt].isEmpty else { continue }
            try db.execute(
                "INSERT OR REPLACE INTO ecdict (word, phonetic, definition, translation, pos, exchange, frq) VALUES (?,?,?,?,?,?,?)",
                [row[wordAt], field(row, "phonetic"), field(row, "definition"),
                 field(row, "translation"), field(row, "pos"), field(row, "exchange"),
                 field(row, "frq")])
            rows += 1
            if rows % 20_000 == 0 {
                onProgress(Progress(stage: "正在建立本地词典…已导入 \(rows / 1000)k 词", fraction: nil))
            }
        }
        guard rows > 10_000 else { throw InstallError.badCSV("只解析出 \(rows) 行，像是下载不完整") }

        try db.executeScript("""
            COMMIT;
            CREATE INDEX IF NOT EXISTS idx_ecdict_word ON ecdict(word COLLATE NOCASE);
            PRAGMA journal_mode = DELETE;
            """)
        Log.info("词典导入 \(rows) 条")
    }
}

/// 只够读 ECDICT 的 CSV 解析器：双引号包裹、`""` 表示一个字面引号、字段里可以有逗号。
///
/// **不能按行 split 再按逗号 split**——ECDICT 的释义里既有逗号也有引号，
/// 那样做出来的库会有几万条错位的词条，而且完全不报错。
struct CSVParser {
    private let scalars: [Character]
    private var position: Int

    init(text: String) {
        // 统一换行，省掉后面每处都判 \r\n。
        scalars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        position = 0
    }

    mutating func nextRow() -> [String]? {
        guard position < scalars.count else { return nil }
        var row: [String] = []
        var field = ""
        var quoted = false

        while position < scalars.count {
            let c = scalars[position]
            position += 1
            if quoted {
                if c == "\"" {
                    // 引号内的 `""` 是一个字面引号，不是结束。
                    if position < scalars.count, scalars[position] == "\"" {
                        field.append("\"")
                        position += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"": quoted = true
            case ",":  row.append(field); field = ""
            case "\n": row.append(field); return row
            default:   field.append(c)
            }
        }
        row.append(field)
        return row
    }
}
