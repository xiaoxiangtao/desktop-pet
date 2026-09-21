# 桌宠 DesktopPet

一只住在 macOS 桌面上的猫。可以跟它聊天、划词查英文、开实时字幕。

原生 Swift + AppKit，没有 Electron、没有后台服务、没有账号体系。除了你自己配置的
对话 API，没有任何数据离开这台电脑。

> English summary at the bottom.

---

## 它能做什么

| 功能 | 说明 | 需要什么 |
|---|---|---|
| **桌面宠物** | 手绘猫精灵，六态动画（坐、眨眼、打哈欠、趴下、睡觉、呼吸），点一下醒来，可拖动、可跨屏 | 无 |
| **对话** | 点猫弹出气泡跟它聊天，流式输出 | 一个 OpenAI 兼容的 API |
| **查词记生词** | 聊天里发一个英文单词，或在**任意 app 里划选**一个词，直接出释义卡片并记进生词本 | 下载 ECDICT 词典（向导里一键） |
| **实时字幕** | 把麦克风或"电脑正在放的声音"实时转成字幕，显示在气泡里并存成 SRT | macOS 26+、麦克风或屏幕录制权限 |
| **字幕笔记** | 字幕结束后自动整理成一份中文 Markdown 笔记 | 同「对话」；默认关闭 |

**每个功能都可以单独不用。** 不配 API 就是一只不会说话的猫，不下词典就没有查词，
一项系统权限都不给也照样能跑——设置页里会逐条写清楚"缺这个会怎样"。

## 系统要求

- **macOS 26 或更高版本**（实时字幕用的 `SpeechAnalyzer` 是 26 才有的 API）
- Apple Silicon（当前只提供 arm64 构建；Intel 需自行编译）

## 安装

### 方式一：下载安装包

1. 从 [Releases](../../releases) 下载 `DesktopPet-<版本>-arm64.dmg`
2. 打开 DMG，把「DesktopPet」拖进「Applications」
3. **第一次打开会被 Gatekeeper 拦住**——这个包没有 Apple 开发者签名，属于正常现象。
   在「应用程序」里**右键点击 DesktopPet → 打开 → 再点「打开」**即可。

   如果提示「已损坏，无法打开」，在终端里跑一次：

   ```bash
   xattr -dr com.apple.quarantine /Applications/DesktopPet.app
   ```

   （这一步是在去掉 macOS 给"从网上下载的文件"加的隔离标记。要彻底免掉它需要
   Apple Developer Program 的 Developer ID 证书和公证流程，本项目没有。）

### 方式二：自己编译

需要 Xcode 26 的命令行工具。

```bash
git clone <仓库地址>
cd desktop-pet
scripts/make_app.sh --install     # 编译 + 组装 .app + 装进 /Applications + 启动
```

其他命令：

```bash
scripts/build.sh          # 只编译
scripts/build.sh test     # 跑单元测试（90 条）
scripts/make_app.sh       # 只组装到 /tmp/desktop-pet-stage
scripts/make_dmg.sh       # 出 dist/DesktopPet-<版本>-arm64.dmg
```

> **别直接 `swift build`。** SwiftPM 的构建数据库是 SQLite，放在 `~/Documents`
> 这类 TCC 保护目录里会报 `disk I/O error`，后果是**改了源码也不重新编译**，
> 你会拿着旧二进制反复测试而毫无察觉。`scripts/build.sh` 把构建产物挪到了 `/tmp`。

## 首次运行

第一次启动会自动弹出设置向导，三节：

### 1　对话

填一个 **OpenAI 兼容**的服务地址。常见几种：

| 用什么 | 服务地址 | 模型名 | 密钥 |
|---|---|---|---|
| OpenAI 官方 | `https://api.openai.com/v1` | `gpt-4o-mini` | 必填 |
| 各家中转 / 兼容服务 | 对方给的地址 | 对方给的模型名 | 必填 |
| Ollama（本机） | `http://localhost:11434/v1` | `qwen3:8b` 等 | 留空 |
| LM Studio（本机） | `http://localhost:1234/v1` | 已加载的模型名 | 留空 |

地址写 `https://x.com`、`https://x.com/v1`、`https://x.com/v1/chat/completions`
都可以，程序会自己补齐。填完点**「测试连接」**——它会真的发一轮请求，不是只检查格式。

**API 密钥存在系统钥匙串里**，不会写进配置文件。

### 2　系统权限

| 权限 | 用来做什么 | 不给会怎样 |
|---|---|---|
| 麦克风 | 录音做实时字幕 | 字幕不可用，其余正常 |
| 语音识别 | macOS 在本机把语音转文字 | 字幕不可用 |
| 屏幕与系统录音 | 采集"电脑正在放的声音"（只取声音，不截画面） | 字幕只能用麦克风 |
| 辅助功能 | 读取你在别的 app 里划选的文字 | 划词查词不可用，气泡里手动输入照样能查 |

macOS 不允许程序代勾这些开关，点「去授权」会把你送到系统设置对应的那一页。
**屏幕录制授权后需要重开桌宠才生效**（ScreenCaptureKit 在进程启动时就把权限快照了）。

### 3　词典（可选）

点「下载词典」会从 ECDICT 仓库下 66 MB 的 CSV，在本机建成 100 MB 的 SQLite。
实测下载+导入约 30 秒，770k 词条，全程离线可用，之后查词是本地的（约 2–8 ms）。

设置随时可以从**菜单栏的猫 →「设置…」**再打开。菜单栏还有一项「检查环境…」，
会列出这台机器上什么齐了、缺的那些影响什么。

## 数据都放在哪

```
~/Library/Application Support/app.desktoppet.DesktopPet/
├── settings.json          设置（不含密钥）
├── ecdict.sqlite3         词典（你自己下载的）
├── vocabulary.sqlite3     生词本
└── subtitles/<时间戳>/    字幕会话：audio.wav、subtitle.srt、subtitle.jsonl、notes.md

~/Library/Logs/app.desktoppet.DesktopPet/    日志
```

API 密钥在**系统钥匙串**（服务名 `app.desktoppet.DesktopPet`）。

卸载：删掉 `/Applications/DesktopPet.app` 和上面这个目录即可。

## 隐私

- **语音识别在本机完成**（macOS 的 `SpeechAnalyzer`），音频和转写结果不上传。
- **查词在本机完成**（本地 SQLite），不联网。
- **只有对话内容和字幕笔记**会发送到**你自己填的那个 API 服务**。用本机的 Ollama /
  LM Studio 的话，连这部分也不出这台电脑。
- 项目本身不做任何遥测、崩溃上报或使用统计。

## 架构

```
DesktopPet/Sources/
├── PetCore/        设置、路径、权限探测、钥匙串、日志、子进程、几何计算
├── PetAnimation/   雪碧图清单、六态动画状态机、逐像素 alpha 命中
├── Providers/      对话后端：OpenAI 兼容端点（默认）、Hermes CLI（可选）
├── VocabKit/       SQLite 封装、ECDICT 查词、生词本、词典下载安装
├── SubtitleKit/    SpeechAnalyzer 实时轨、麦克风 / 系统音频源、SRT 落盘、笔记整理
├── SelectionKit/   划词：辅助功能 API + ⌘C 兜底
└── PetApp/         唯一允许 import AppKit 的一层：面板、气泡、设置页、菜单栏
```

**硬规则：`PetApp` 之外的任何 target 都不 import AppKit。** 这是"能不能在
`swift test` 里跑单元测试"的分界线——UI 依赖一旦渗进来，那一层就只能靠肉眼验收了。
目前 90 条单元测试。

接一个新的对话后端 = 实现 `ChatProvider` 协议 + 在 `ProviderRegistry` 加一个
case，共两个文件。

## 已知限制

- **未签名、未公证**，首次打开需要绕一次 Gatekeeper（见上面的安装一节）。
- 只提供 arm64 构建。
- 实时字幕的长会话稳定性（两小时以上）未经充分测试。
- 对话历史只保留在内存里，重开 app 就是新会话。
- 系统音频采集走 ScreenCaptureKit，因此菜单栏会出现"正在录制"指示器。

## 许可

代码与美术素材：[MIT](LICENSE)。
词典数据来自 [ECDICT](https://github.com/skywind3000/ECDICT)（MIT，要求署名），
详见 [THIRD_PARTY.md](THIRD_PARTY.md)。

---

## English

A desktop cat for macOS. Chat with it, look up English words by selecting them in
any app, and turn what you're listening to into live subtitles.

Native Swift + AppKit. No Electron, no background service, no account. Speech
recognition and dictionary lookup run entirely on-device; the only thing that
leaves your Mac is chat content sent to **an API endpoint you configure yourself**
(point it at a local Ollama / LM Studio instance and nothing leaves at all).

**Requires macOS 26+ on Apple Silicon.** Download the DMG from
[Releases](../../releases), drag it to Applications, then right-click → Open to
get past Gatekeeper (the build is unsigned). A setup wizard walks you through the
three optional pieces: chat API, system permissions, and the ECDICT dictionary
download. Every feature degrades independently — skip any of them and the rest
still works.

Build from source with `scripts/make_app.sh --install`. Tests: `scripts/build.sh test`.

MIT licensed. Dictionary data from [ECDICT](https://github.com/skywind3000/ECDICT)
(MIT, attribution required).
