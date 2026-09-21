import AppKit
import PetAnimation
import PetCore
import VocabKit

// `--self-check`：只验证"装好的这个 .app 自身是完整的"，然后退出。
//
// **这条存在是因为 0.1.0 就是这么发坏的**：CI 全绿、DMG 照出，用户双击闪退——
// 资源 bundle 在那套工具链下找不到，而单元测试是在测试 bundle 里跑的，
// 根本走不到 `.app` 的资源查找路径，所以一条都没红。
//
// 必须跑在 NSApplication 之前：CI 的 runner 没有窗口服务器，碰 NSApp 会直接失败，
// 而这些检查跟界面无关。
if CommandLine.arguments.contains("--self-check") {
    var failures: [String] = []

    do {
        let manifest = try SpriteManifest.load()
        // `image` 是 "sprites/cat-poses.webp" 这样的相对路径，bundle 里是扁平的，
        // 所以只取文件名去找。
        for sheet in [manifest.sheets.poses, manifest.sheets.sleepBreath] {
            let file = (sheet.image as NSString).lastPathComponent as NSString
            if SpriteManifest.resourceBundle.url(forResource: file.deletingPathExtension,
                                                 withExtension: file.pathExtension) == nil {
                failures.append("雪碧图 \(file) 不在 bundle 里")
            }
        }
        print("✓ 精灵清单与雪碧图素材（画布 \(Int(manifest.petBox.width))×\(Int(manifest.petBox.height))）")
    } catch {
        failures.append("精灵清单加载失败：\(error)")
    }

    if SpriteManifest.resourceBundle.url(forResource: "tray-icon", withExtension: "png") == nil {
        failures.append("菜单栏图标 tray-icon.png 不在 bundle 里")
    } else {
        print("✓ 菜单栏图标")
    }

    // 词表缺失只是判定退化、不致命，但装好的包里没理由缺。
    if VocabEligibility.a1WordCount == 0 {
        failures.append("CEFR A1 词表是空的，查词判定会退化")
    } else {
        print("✓ CEFR A1 词表：\(VocabEligibility.a1WordCount) 条")
    }

    guard failures.isEmpty else {
        for f in failures { print("✗ \(f)") }
        exit(1)
    }
    print("自检通过")
    exit(0)
}

// 单实例由 macOS 保证，不需要旧版 Electron 那套 requestSingleInstanceLock。
let app = NSApplication.shared
let coordinator = AppCoordinator()
app.delegate = coordinator
app.run()
