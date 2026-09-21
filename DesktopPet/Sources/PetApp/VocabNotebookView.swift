import AppKit
import VocabKit

/// 生词本面板：列出本子里的词，每行可删。开在气泡的消息区里，不另开窗口。
///
/// **用 NSTableView 而不是 NSStackView 堆视图**。第一版用竖直 NSStackView 加 76 行，
/// 每行再约束 `row.width == stack.width`，而 stack 本身又被约束到 clipView——
/// 循环依赖把 Auto Layout 引擎打爆，**主线程直接卡死**（实测：76 条数据已取回，
/// 但 `MainActor.run` 里的 `show()` 再没返回，心跳定时器 3 秒后就停了）。
/// 列表在 AppKit 里就该用 table view：它是虚拟化的，行数再多也只建可见的那几行。
///
/// **删除是两步确认**：第一下只把按钮变成红色的「确认删除」，第二下才真删。
/// 不用弹窗是因为气泡只有 400px 宽，模态会盖住它正在询问的那个列表。
///
/// **`pendingDelete` 放在面板上而不是行内**：点第二个词会自动取消第一个的预备态。
/// 同时有两个 armed 按钮正是误删的来源。
///
/// 删词会**连 Anki 卡片一起删**（用户 2026-09-08 拍板），复习进度一并消失且不可恢复，
/// 所以两步确认不是多余的谨慎。Anki 的结果要单独报告——本地删成功但 Anki 没开是
/// 常见组合，`success` 只反映本地。
final class VocabNotebookView: NSView {
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")

    private var entries: [VocabStore.Entry] = []
    private var pendingDelete: String?

    /// 请求删除某个词；回调回报结果。
    var onDelete: ((String, @escaping (VocabStore.DeleteResult) -> Void) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        status.font = .systemFont(ofSize: 12)
        status.textColor = NSColor(white: 0.42, alpha: 1)
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: leadingAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// `nil` = 工具够不着，要说出来；空数组 = 本子真的是空的。这两者必须区分。
    func show(_ list: [VocabStore.Entry]?) {
        pendingDelete = nil
        entries = list ?? []
        table.reloadData()
        status.stringValue = list == nil ? "生词本读不到（查词工具不可用）"
            : (entries.isEmpty ? "还没有记过词" : "共 \(entries.count) 个词")
        dumpIfAsked()
    }

    /// PET_DUMP_NOTEBOOK=<路径>：数据落地那一刻把面板导出成 PNG 自查布局。
    private func dumpIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["PET_DUMP_NOTEBOOK"] else { return }
        layoutSubtreeIfNeeded()
        guard bounds.width > 1, let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            NSLog("[pet] 生词本导出失败：bounds=%@", NSStringFromRect(bounds)); return
        }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let b = NSBitmapImageRep(data: tiff),
           let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            NSLog("[pet] 生词本已导出 %@（%.0fx%.0f，%d 行）", path, bounds.width, bounds.height, entries.count)
        }
    }
}

extension VocabNotebookView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        return RowView(entry: entry,
                       armed: pendingDelete == entry.word,
                       onTap: { [weak self] word in self?.deleteTapped(word) })
    }

    private func deleteTapped(_ word: String) {
        guard pendingDelete == word else {
            pendingDelete = word        // 第一下：只进入预备态，并取消别的词的预备态
            table.reloadData()
            return
        }
        pendingDelete = nil
        status.stringValue = "正在删除 \(word)…"
        table.reloadData()
        onDelete?(word) { [weak self] result in
            guard let self else { return }
            guard result.success else {
                self.status.stringValue = "删除 \(word) 失败"
                return
            }
            // Anki 的结果单独报告：本地删成功但 Anki 没开是常见组合，
            // 那种情况必须让用户知道卡片还在。
            let ankiNote = (result.anki == "deleted" || result.anki == "absent")
                ? "" : "（Anki 未连接，卡片仍在）"
            self.status.stringValue = "已删除 \(word)\(ankiNote)"
            self.entries.removeAll { $0.word == word }
            self.table.reloadData()
        }
    }
}

/// 一行：词 + 音标 | 中文释义（可压缩） | 删除按钮。
///
/// **手工布局，不用 Auto Layout**——table view 的行是频繁重建的，
/// 而上一版正是在这里用约束把主线程搞死的。
private final class RowView: NSView {
    private let word = NSTextField(labelWithString: "")
    private let zh = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let onTap: (String) -> Void
    private let key: String

    init(entry: VocabStore.Entry, armed: Bool, onTap: @escaping (String) -> Void) {
        self.onTap = onTap
        self.key = entry.word
        super.init(frame: .zero)

        word.stringValue = entry.ipa.isEmpty ? entry.word : "\(entry.word) /\(entry.ipa)/"
        word.font = .systemFont(ofSize: 13, weight: .medium)
        word.textColor = NSColor(red: 24/255, green: 24/255, blue: 27/255, alpha: 1)
        word.lineBreakMode = .byTruncatingTail

        zh.stringValue = entry.zh.replacingOccurrences(of: "\n", with: " ")
        zh.font = .systemFont(ofSize: 12)
        zh.textColor = NSColor(white: 0.42, alpha: 1)
        zh.lineBreakMode = .byTruncatingTail

        button.title = armed ? "确认删除" : "删除"
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.target = self
        button.action = #selector(tapped)
        button.contentTintColor = armed
            ? NSColor(red: 220/255, green: 38/255, blue: 38/255, alpha: 1)   // 唯一的红，就是这个预备态
            : NSColor(white: 0.42, alpha: 1)

        for v in [word, zh, button] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let h = bounds.height
        let buttonWidth: CGFloat = 56
        let wordWidth = min(160, max(60, ceil(word.intrinsicContentSize.width)))
        word.frame = NSRect(x: 0, y: 0, width: wordWidth, height: h)
        button.frame = NSRect(x: bounds.width - buttonWidth, y: 0, width: buttonWidth, height: h)
        let zhX = wordWidth + 8
        zh.frame = NSRect(x: zhX, y: 0, width: max(0, button.frame.minX - 8 - zhX), height: h)
    }

    @objc private func tapped() { onTap(key) }
}
