// swift-tools-version: 6.0
import PackageDescription

// 桌宠。全部在本机：AppKit 画窗口和动画、macOS 的 SpeechAnalyzer 做实时字幕、
// SQLite 存词典和生词本，只有对话走用户自己配的 OpenAI 兼容端点。
//
// 硬规则：PetKit 的所有 target 都不 import AppKit。这是「能不能在 swift test 里
// 跑单元测试」的分界线；UI 依赖一旦渗进来，这一层就只能靠肉眼验收了。
let package = Package(
    name: "DesktopPet",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "DesktopPet", targets: ["PetApp"]),
        .library(name: "PetKit", targets: ["PetCore", "Providers", "VocabKit", "ChatKit", "PetAnimation", "SubtitleKit", "SelectionKit"]),
    ],
    targets: [
        .target(name: "PetCore"),
        // 动画时序与雪碧图清单。素材（webp + cat-anim.json）作为资源打进来，
        // 这样 swift test 也能加载清单做逐帧断言，不必依赖 app bundle。
        .target(name: "PetAnimation", dependencies: ["PetCore"], resources: [.process("Resources")]),
        .target(name: "Providers", dependencies: ["PetCore"]),
        // 依赖 Providers 是因为字幕笔记走的就是用户配的那个对话 API——
        // 不为笔记单开一套凭据和一个模型。
        .target(name: "SubtitleKit", dependencies: ["PetCore", "Providers"]),
        .target(name: "SelectionKit", dependencies: ["PetCore"]),
        // CEFR A1 词表作为资源：判定"这个词值不值得记生词本"要用。
        .target(name: "VocabKit", dependencies: ["PetCore"], resources: [.process("Resources")]),
        .target(name: "ChatKit", dependencies: ["PetCore", "Providers", "VocabKit"]),
        // 唯一允许 import AppKit 的 target。业务逻辑一律不放这里，
        // 放进来就等于退出了 swift test 的覆盖范围。
        .executableTarget(name: "PetApp",
                          dependencies: ["PetCore", "PetAnimation", "ChatKit", "SubtitleKit", "SelectionKit", "VocabKit", "Providers"]),
        // fake-hermes 是给测试当假二进制用的 shell 脚本，不是资源，显式排除
        .testTarget(name: "PetKitTests",
                    dependencies: ["PetCore", "Providers", "VocabKit", "ChatKit", "PetAnimation", "SubtitleKit", "SelectionKit"],
                    exclude: ["Fixtures/fake-hermes"]),
    ]
)
