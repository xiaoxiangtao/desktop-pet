import Foundation
import PetCore
import Providers

/// 字幕结束后的收尾：把整场字幕整理成一份中文笔记，落在会话目录里。
///
/// 走**用户自己配的那个对话 API**，不引入第二套凭据、第二个 CLI、第二个模型下载。
/// 没配 API 就跳过这一步并说明原因——笔记是锦上添花，不能让它挡住"字幕能存下来"。
///
/// **不是每次都跑**：随手开两分钟试一下也去跑一遍全文笔记纯属浪费，所以有时长门槛
/// （菜单栏「字幕设置」里可调）。默认这个功能是关的——它要花用户自己的钱。
public struct NotesWriter: Sendable {
    /// 一次喂给模型多少字符。一节两小时的课约 16k 词，整份塞进去会超大多数模型的
    /// 上下文；切成块各自成段、最后再合并一次，是这类长文唯一稳妥的做法。
    static let chunkCharacters = 12_000
    /// 合并阶段最多带多少字符的分段笔记。超了就只合并前面这些，剩下的原样附在后面——
    /// **宁可笔记结构差一点，也不能整份失败**。
    static let mergeCharacters = 20_000

    public init() {}

    /// 后台整理，**不等它**：这一步要几分钟，而调用点是用户按「停止字幕」的路径，
    /// 卡在这里等于界面假死。
    public static func launch(directory: URL, settings: Settings = .load()) {
        guard settings.chatConfigured else {
            Log.info("没配对话 API，这场字幕只存档不做笔记")
            return
        }
        let srt = directory.appendingPathComponent("subtitle.srt")
        guard let text = try? String(contentsOf: srt, encoding: .utf8), !text.isEmpty else {
            Log.warn("找不到 subtitle.srt 或它是空的，不做笔记：\(directory.lastPathComponent)")
            return
        }
        Task.detached(priority: .background) {
            do {
                let notes = try await NotesWriter().summarize(srt: text, settings: settings)
                let out = directory.appendingPathComponent("notes.md")
                try notes.write(to: out, atomically: true, encoding: .utf8)
                Log.info("笔记已生成：\(out.path)")
            } catch {
                // 失败只记日志，不弹窗：此时用户多半已经在做别的事，模态框是打断。
                Log.warn("笔记生成失败（\(directory.lastPathComponent)）：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 整理

    func summarize(srt: String, settings: Settings) async throws -> String {
        let plain = Self.stripSRT(srt)
        guard !plain.isEmpty else { return "" }
        let chunks = Self.split(plain, limit: Self.chunkCharacters)
        let provider = OpenAIProvider(config: OpenAIProvider.Config(
            baseURL: settings.openAIBaseURL,
            model: settings.openAIModel,
            apiKey: Keychain.chatAPIKey,
            systemPrompt: Self.systemPrompt,
            timeout: 300,
            historyTurns: 0))   // 每一块都是独立任务，不要上下文污染

        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let prompt = """
                这是一场英文录音的第 \(index + 1)/\(chunks.count) 段转写文本。\
                用中文提炼这一段讲了什么，保留关键术语的英文原文。只输出要点，不要开场白。

                \(chunk)
                """
            partials.append(try await ask(provider, prompt))
            Log.info("笔记：第 \(index + 1)/\(chunks.count) 段完成")
        }

        guard chunks.count > 1 else { return Self.wrap(partials.joined()) }

        var merged = partials.joined(separator: "\n\n---\n\n")
        if merged.count > Self.mergeCharacters { merged = String(merged.prefix(Self.mergeCharacters)) }
        let final = try await ask(provider, """
            下面是同一场录音分段整理出的要点。把它们合并成一份结构清晰的中文笔记：\
            按主题分节、每节有小标题、去掉重复内容、保留关键术语的英文原文。只输出笔记正文。

            \(merged)
            """)
        return Self.wrap(final)
    }

    private func ask(_ provider: OpenAIProvider, _ prompt: String) async throws -> String {
        var reply = ""
        for try await event in provider.respond(to: ChatTurn(text: prompt, historyUID: UUID().uuidString)) {
            if case .message(let m) = event { reply = m }
        }
        return reply
    }

    static let systemPrompt = """
        你是一个把英文录音转写整理成中文笔记的助手。
        要求：忠于原文，不补充原文没有的内容；关键术语保留英文原文；
        转写里明显的识别错误按上下文判断修正，不加说明；只输出笔记本身，不写任何开场白或结语。
        """

    static func wrap(_ body: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return """
            # 字幕笔记

            > 由桌宠根据 subtitle.srt 自动整理，生成于 \(stamp)。
            > 内容来自语音识别的转写，可能有错，重要信息请回听原音频核对。

            \(body.trimmingCharacters(in: .whitespacesAndNewlines))
            """
    }

    // MARK: - SRT

    /// 把 SRT 剥成纯文本：去掉序号行和时间戳行，合并连续重复的句子。
    ///
    /// **去重是必需的**：实时字幕的定稿行之间常有重叠（同一句被修正后再发一次），
    /// 不去重的话喂给模型的文本里会有大量重复，既烧 token 又让笔记出现重复要点。
    static func stripSRT(_ srt: String) -> String {
        var lines: [String] = []
        for raw in srt.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.contains("-->") { continue }
            if Int(line) != nil { continue }        // 序号行
            if line == lines.last { continue }      // 相邻重复
            lines.append(line)
        }
        return lines.joined(separator: " ")
    }

    /// 按句子边界切块，不在词中间断开。
    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var current = ""
        // 先按句号切成句子，再往块里攒；单个句子超长时（识别没断句）直接成块。
        for sentence in text.split(separator: ".", omittingEmptySubsequences: true) {
            // 末尾那个 ". " 切出来是一段纯空白，拼上句号就成了一个凭空多出来的 "."。
            let body = sentence.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let piece = body + "."
            if current.count + piece.count > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
