# 开发笔记

写给想改这个项目的人。下面每一条都对应一个真实踩过的坑——删掉任何一条，
对应的 bug 都可能原样复活。

## 构建

**一律用 `scripts/build.sh`，不要直接 `swift build`。**

SwiftPM 的构建数据库（llbuild 的 SQLite）放在 `~/Documents`、`~/Desktop`、
`~/Downloads` 这类 TCC 保护目录里会报 `accessing build database ...: disk I/O error`。
这**不是噪音**——构建状态记不住，于是改了源码也不重新编译。表现是二进制时间戳
停在二十分钟前，而你在反复测试旧代码。脚本把 scratch path 挪到了 `/tmp`。

产物目录**一律问 SwiftPM 要**（`swift build --show-bin-path`），不要写死。
工具链换个版本产物就换个位置，写死的话脚本会一直拿上一个工具链留下的旧二进制
去组装 `.app`，直到某次 clean 之后才暴露成「Build complete 但文件不存在」。

## 为什么必须打成 .app

TCC（麦克风 / 语音识别 / 屏幕录制 / 辅助功能）认的是 **bundle 和它 Info.plist
里的用途说明**。裸二进制没有 plist，macOS 会**直接拒绝而不弹授权框**——表现是
字幕一个字都不出，且没有任何报错。所以要测这些功能必须走 `scripts/make_app.sh`。

ad-hoc 签名（`codesign --sign -`）**是必需的不是可选项**：在 Apple Silicon 上
完全没签名的 bundle 根本起不来。代价是 TCC 权限跟着 cdhash 走，每次重建后
都要重新授权一次。开发期嫌烦的话可以自建一个签名证书，把 designated requirement
锚在证书上，重建就不掉权限：

```bash
# 钥匙串访问 → 证书助理 → 创建证书 → 代码签名 → 名字随便取
PET_SIGN_IDENTITY="你的证书名" scripts/make_app.sh --install
```

## 分层：谁能 import AppKit

**只有 `PetApp` 可以。** 这是"能不能在 `swift test` 里跑单元测试"的分界线。
业务逻辑放进 `PetApp` 就等于退出了测试覆盖范围，只能靠肉眼验收——而这个项目
之前恰恰在肉眼验收上连错过三轮。

```
PetCore ← Providers ← SubtitleKit
   ↑          ↑
VocabKit    ChatKit          PetApp（唯一的 AppKit 层）
PetAnimation
SelectionKit
```

## 工作方式：先让程序自己产出可看的证据

不要改完让用户去看。这个项目里已经有几个这样的钩子，加新界面时照着做：

| 环境变量 | 作用 |
|---|---|
| `PET_DUMP_SETUP=<路径>` | 把设置页渲染成 PNG |
| `PET_DUMP_BUBBLE=<路径>` | 把气泡渲染成 PNG |
| `PET_DUMP_NOTEBOOK=<路径>` | 把生词本渲染成 PNG |
| `PET_TRACE_FRAMES=1` | 逐帧打印实际停留时长 vs 表定值 |
| `PET_HEARTBEAT=1` | 每秒打一条心跳，用来判断主线程是不是被卡住了 |
| `PET_DEBUG_FAKE_SUBTITLE=1` | 不开麦克风，灌几条假字幕进去自查样式 |
| `PET_DEBUG_CARD=<n>` | 灌一张多段的假查词卡片，自查消息区高度 |

`PET_HEARTBEAT` 留着不要删——当初正是靠它定位到生词本用 `NSStackView` 堆 76 行
把 Auto Layout 打爆、主线程死锁（现象极隐蔽：日志显示数据已取回，但界面再没返回）。

## 几个反复踩到的具体坑

**`CALayer.contentsRect` 的 y 轴是下原点**，而雪碧图的行从上往下数。不翻行的话
第 0 行会被画成最后一行。隐蔽在于**状态机日志完全正常**，帧名、时序、转移全对，
只有对照素材裁图才看得出来。`SpriteManifest.Sheet.unitRect` 里有两条测试钉住。

**`withTaskGroup` 等不可取消的子任务**：超时后 `cancelAll()` 对
`withCheckedContinuation` 无效，整个 group 会卡到进程退出。真机上表现为
"取消对话"永久挂住。用 `withTaskCancellationHandler` + 一次性 resume 闸门。

**`NSScreen.main` 跟随光标**，不是主显示器。用它给桌宠定位的话，启动时光标在
外接屏猫就生在外接屏。要用 `NSScreen.screens.first`。

**滚动视图的文档视图必须是翻转的**（`isFlipped = true`）。AppKit 原点在左下，
内容比视口矮时 `NSStackView` 会贴着底边排，顶上空出一大块。

**SRT 时间戳要用整毫秒运算**：`1.2 - 1.0 = 0.19999999999999996`，× 1000 截断
成 199ms，时间戳会零星差 1 毫秒。

**ECDICT 用字面两个字符 `\n` 分隔义项**，不是真换行。这个坑在原项目里出现过
三次，所以现在只在 `VocabStore.unescape` 一处解。

**ECDICT 的 CSV 不能按行 split 再按逗号 split**：释义里既有逗号也有引号，
那样做出来的库会有几万条错位词条，而且完全不报错。`CSVParser` 有测试钉住。

**`Settings` 解码必须容忍缺字段**：合成的 `Decodable` 遇到缺失的键直接抛错，
而 `load()` 会因此退回默认值——每加一个新设置项，老用户选过的存放目录、
笔记门槛就被静默清掉。`decodeTolerant` 先拿默认值垫底再盖上已存的值。

**用 `URLProtocol` 桩测对话路径的那组测试必须串行**（`@Suite(.serialized)`）：
它们共用静态状态，并行跑会互相覆盖，表现为随机几条失败。

## 发版

```bash
echo 0.2.0 > VERSION
git commit -am "0.2.0"
git tag v0.2.0 && git push --tags
```

CI（`.github/workflows/release.yml`）会校验标签和 `VERSION` 一致、跑测试、出 DMG、
建 Release。版本号不一致会卡住——用户装上看到的版本号和 Release 页对不上，
发出去就改不了了。
